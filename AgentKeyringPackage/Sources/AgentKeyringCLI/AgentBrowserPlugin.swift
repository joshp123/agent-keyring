import AgentKeyringFeature
import ArgumentParser
import Darwin
import Foundation

struct AgentBrowserPlugin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent-browser-plugin", shouldDisplay: false
    )

    @MainActor
    mutating func run() async throws {
        await AgentBrowserPluginProtocol.run()
    }
}

enum AgentBrowserPluginProtocol {
    static let protocolVersion = "agent-browser.plugin.v1"

    private struct Envelope: Decodable {
        let `protocol`: String
        let type: String
        let capability: String
        let request: Request
    }

    private struct Request: Decodable {
        let itemRef: String?
        let url: String?
    }

    private struct Response: Encodable {
        let `protocol` = protocolVersion
        let success: Bool
        var manifest: Manifest?
        var credential: Credential?
        var error: String?
    }

    private struct Manifest: Encodable {
        let name = "agent-keyring"
        let capabilities = ["credential.read"]
    }

    private struct Credential: Encodable {
        let username: String
        let password: String
        let url: String
    }

    private struct Failure: Error {
        let message: String
    }

    @MainActor
    static func run(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        sendRequest: (AgentBridgeRequest) async throws -> AgentBridgeResponse = CLIClient.send
    ) async {
        let response: Response
        do {
            let envelope: Envelope
            do {
                envelope = try JSONDecoder().decode(Envelope.self, from: input.readDataToEndOfFile())
            } catch {
                throw Failure(message: "invalid request")
            }
            guard envelope.protocol == protocolVersion else {
                throw Failure(message: "unsupported protocol")
            }
            switch (envelope.type, envelope.capability) {
            case ("plugin.manifest", "plugin.manifest"):
                response = Response(success: true, manifest: Manifest())
            case ("credential.resolve", "credential.read"):
                response = try await resolve(envelope.request, sendRequest: sendRequest)
            default:
                throw Failure(message: "unsupported request")
            }
        } catch let failure as Failure {
            response = Response(success: false, error: failure.message)
        } catch let failure as AgentBridgeFailure {
            response = Response(success: false, error: errorMessage(for: failure.code))
        } catch {
            response = Response(success: false, error: "approval unavailable")
        }

        if var bytes = try? JSONEncoder().encode(response) {
            defer { bytes.resetBytes(in: bytes.startIndex..<bytes.endIndex) }
            try? output.write(contentsOf: bytes)
        }
    }

    @MainActor
    private static func resolve(
        _ request: Request,
        sendRequest: (AgentBridgeRequest) async throws -> AgentBridgeResponse
    ) async throws -> Response {
        guard let itemRef = request.itemRef else {
            throw Failure(message: "invalid request")
        }
        let parts = itemRef.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let site: String
        let destination: String
        do {
            site = try normaliseSecureWebTarget(String(parts[0]))
            destination = try normaliseSecureWebTarget(request.url ?? site)
        } catch {
            throw Failure(message: "invalid request")
        }
        let account = parts.count == 2 ? String(parts[1]) : nil
        if let account, account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure(message: "invalid request")
        }
        let selection = try await sendRequest(CLICommand.find(targetURL: site, account: account).request)
        try check(selection)
        guard let candidates = selection.candidates, !candidates.isEmpty else {
            throw Failure(message: "no matching login")
        }
        guard candidates.count == 1 else { throw Failure(message: "ambiguous") }

        let usernameRequest = AgentBridgeRequest(
            callerPID: getpid(), action: .acquire, targetURL: destination,
            candidateID: candidates[0].id, field: .username
        )
        let passwordRequest = AgentBridgeRequest(
            callerPID: getpid(), action: .acquire, targetURL: destination,
            candidateID: candidates[0].id, field: .password
        )
        defer {
            CredentialTransfer.clear(requestID: usernameRequest.id)
            CredentialTransfer.clear(requestID: passwordRequest.id)
        }
        try check(try await sendRequest(usernameRequest))
        var username = try CredentialTransfer.read(requestID: usernameRequest.id)
        defer { username.resetBytes(in: username.startIndex..<username.endIndex) }
        try check(try await sendRequest(passwordRequest))
        var password = try CredentialTransfer.read(requestID: passwordRequest.id)
        defer { password.resetBytes(in: password.startIndex..<password.endIndex) }
        guard let usernameValue = String(data: username, encoding: .utf8),
            let passwordValue = String(data: password, encoding: .utf8)
        else { throw Failure(message: "no matching login") }
        let clearedUsername = CredentialTransfer.clear(requestID: usernameRequest.id)
        let clearedPassword = CredentialTransfer.clear(requestID: passwordRequest.id)
        guard clearedUsername && clearedPassword else { throw Failure(message: "approval unavailable") }
        return Response(success: true, credential: Credential(
            username: usernameValue, password: passwordValue, url: request.url ?? site
        ))
    }

    private static func check(_ response: AgentBridgeResponse) throws {
        guard response.ok else { throw Failure(message: errorMessage(for: response.error)) }
    }

    private static func errorMessage(for code: AgentBridgeErrorCode?) -> String {
        switch code {
        case .authorizationDenied, .policyDenied: "declined"
        case .notFound, .fieldUnavailable, .mirrorUnavailable: "no matching login"
        case .ambiguous: "ambiguous"
        default: "approval unavailable"
        }
    }
}
