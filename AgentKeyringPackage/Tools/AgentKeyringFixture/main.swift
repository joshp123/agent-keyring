import AgentKeyringTestSupport
import AgentKeyringFeature
import Darwin
import Foundation

// Synthetic process fixture. It is never bundled in AgentKeyring.app.
@main
struct AgentKeyringFixture {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--sandbox-probe", arguments.count == 2 {
                let outsideReadAllowed = (try? Data(contentsOf: URL(fileURLWithPath: arguments[1]))) != nil
                let result: [String: Any] = [
                    "home": NSHomeDirectory(),
                    "outside_read_denied": !outsideReadAllowed,
                ]
                var data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
                return
            }
            if arguments.first == "--serve" {
                try await serve(arguments)
                return
            }
            if arguments.count == 2, let reference = UUID(uuidString: arguments[1]) {
                switch arguments[0] {
                case "read":
                    var value = try CredentialTransfer.read(requestID: reference)
                    defer { value.resetBytes(in: value.startIndex..<value.endIndex) }
                    try FileHandle.standardOutput.write(contentsOf: value)
                    return
                case "clear":
                    CredentialTransfer.clear(requestID: reference)
                    return
                default: break
                }
            }
            guard arguments.count >= 3, arguments[0] == "acquire",
                let field = field(arguments[1])
            else { throw AgentBridgeFailure(.invalidRequest, "Invalid fixture command.") }
            var account: String?
            var credentialID: UUID?
            var index = 3
            while index < arguments.count {
                guard index + 1 < arguments.count else {
                    throw AgentBridgeFailure(.invalidRequest, "Missing option value.")
                }
                switch arguments[index] {
                case "--account": account = arguments[index + 1]
                case "--credential": credentialID = UUID(uuidString: arguments[index + 1])
                default: throw AgentBridgeFailure(.invalidRequest, "Unknown option.")
                }
                index += 2
            }
            let request = AgentBridgeRequest(
                action: .acquire, targetURL: arguments[2], usernameHint: account,
                candidateID: credentialID, field: field
            )
            let response = try await send(request)
            guard response.ok else {
                throw AgentBridgeFailure(response.error ?? .internalError, "Credential release failed.")
            }
            FileHandle.standardOutput.write(Data((request.id.uuidString + "\n").utf8))
        } catch {
            FileHandle.standardError.write(Data("agent-keyring: \(errorCode(error).rawValue)\n".utf8))
            exit(1)
        }
    }

    private static func send(_ request: AgentBridgeRequest) async throws -> AgentBridgeResponse {
        let fixtureRoot = ProcessInfo.processInfo.environment["AGENT_KEYRING_FIXTURE_BRIDGE_ROOT"]
            .map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/tmp")
        let root = fixtureRoot.appendingPathComponent("ak-\(UUID().uuidString)")
        let bridge = AgentBridgeDirectory(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = ProcessInfo.processInfo.environment["AGENT_KEYRING_FIXTURE_HOST"]
            ?? CommandLine.arguments[0]
        return try await AgentBridgeClient(bridge: bridge).send(request) { requestID in
            let host = Process()
            host.executableURL = URL(fileURLWithPath: executable)
            host.arguments = ["--serve", requestID.uuidString, root.path]
            host.standardOutput = FileHandle.nullDevice
            host.standardError = FileHandle.nullDevice
            try host.run()
        }
    }

    @MainActor
    private static func serve(_ arguments: [String]) async throws {
        guard arguments.count == 3, let requestID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeFailure(.invalidRequest, "Invalid fixture host invocation.")
        }
        let bridge = AgentBridgeDirectory(rootURL: URL(fileURLWithPath: arguments[2]))
        let (completed, completion) = AsyncStream<Void>.makeStream()
        let server = try AgentBridgeServer(bridge: bridge) { request, _, progress in
        guard request.id == requestID else { throw AgentBridgeFailure(.invalidRequest, "Wrong fixture request.") }
        defer { completion.yield(()); completion.finish() }
        audit(stage: "request", request: request)
        let response: AgentBridgeResponse
        do {
            let configuration = try FixtureConfiguration.load()
            let policyStore = CredentialAccessPolicyStore(
                fileURL: bridge.rootURL.appendingPathComponent("fixture-policies.json"),
                signer: FakeAccessRulesSigner()
            )
            let generation = try configuration.generation()
            try await confirmInitialAccessRules(in: policyStore,
                policies: [FixtureConfiguration.credentialID: configuration.policy ?? .ask])
            let accessControl = CredentialAccessController(store: policyStore)
            response = try await AgentCredentialReleaseProcessor(
                accessControl: accessControl
            ).release(
                request: request,
                requester: syntheticRequester,
                generation: generation,
                onProgress: progress,
                authorize: { _, _ in
                    audit(stage: "authorization", request: request)
                    if let delay = configuration.approvalDelayMs, delay > 0 {
                        try await Task.sleep(for: .milliseconds(delay))
                    }
                    switch configuration.authorization ?? "allow" {
                    case "deny": throw CredentialReleaseAuthorizationError.denied
                    case "expire": throw CredentialReleaseAuthorizationError.expired
                    default: break
                    }
                }
            )
            audit(stage: "release", request: request)
        } catch {
            response = AgentBridgeResponse(id: request.id, ok: false, error: errorCode(error))
            audit(stage: "failure", request: request, code: errorCode(error).rawValue)
        }
        return response
        }
        for await _ in completed { break }
        withExtendedLifetime(server) { }
    }

    private static func field(_ argument: String) -> AgentCredentialField? {
        switch argument {
        case "username": .username
        case "password": .password
        case "code": .totp
        default: nil
        }
    }

    private static func errorCode(_ error: Error) -> AgentBridgeErrorCode {
        switch error {
        case let failure as AgentBridgeFailure: failure.code
        case CredentialReleaseAuthorizationError.denied: .authorizationDenied
        case CredentialReleaseAuthorizationError.expired: .requestExpired
        case CredentialReleaseAuthorizationError.unavailable:
            .authorizationUnavailable
        case CredentialResolverError.invalidURL: .invalidURL
        case CredentialResolverError.insecureOrigin: .insecureOrigin
        case CredentialResolverError.notFound: .notFound
        case CredentialResolverError.ambiguous: .ambiguous
        case CredentialResolverError.fieldUnavailable: .fieldUnavailable
        case CredentialResolverError.invalidTOTP: .invalidTOTP
        default: .internalError
        }
    }

    private static func audit(stage: String, request: AgentBridgeRequest, code: String? = nil) {
        guard let path = ProcessInfo.processInfo.environment["AGENT_KEYRING_FIXTURE_AUDIT"] else { return }
        let descriptor = open(path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let event = FixtureAuditEvent(
            stage: stage, requestID: request.id, field: request.field, code: code
        )
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }


}

private struct FixtureAuditEvent: Encodable {
    let stage: String
    let requestID: UUID
    let field: AgentCredentialField?
    let code: String?
}

private struct FixtureConfiguration: Decodable {
    static let credentialID = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
    let origin: String
    let username: String
    let password: String
    let totpSecret: String?
    let policy: CredentialAccessPolicy?
    let authorization: String?
    let approvalDelayMs: Int?

    enum CodingKeys: String, CodingKey {
        case origin, username, password, policy, authorization, approvalDelayMs
        case totpSecret = "totp_secret"
    }

    static func load() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["AGENT_KEYRING_FIXTURE_CONFIG"] else {
            throw AgentBridgeFailure(.mirrorUnavailable, "A synthetic fixture config is required.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func generation() throws -> MirrorGeneration {
        var credentials = [MirrorCredential.password(userName: username, password: password)]
        if let totpSecret {
            guard let seed = Data(base64Encoded: totpSecret) else {
                throw AgentBridgeFailure(.invalidTOTP, "Invalid synthetic TOTP seed.")
            }
            credentials.append(.totp(
                secret: seed, period: 30, digits: 6, userName: username,
                algorithm: .sha1, issuer: "Synthetic login fixture"
            ))
        }
        let item = MirrorItem(
            id: Self.credentialID,
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: "fixture", accountID: Data([1]), itemID: Data([1])
            ),
            title: "Synthetic login fixture",
            origins: [origin],
            credentials: credentials
        )
        return MirrorGeneration(
            id: UUID(), previousGenerationID: nil, createdAt: Date(), sourceExportedAt: Date(),
            scope: .full, exporterIdentifier: "fixture", exporterDisplayName: "Synthetic fixture",
            items: [item], skippedCredentialCount: 0
        )
    }
}
