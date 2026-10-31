// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Dummy-only owner controls for the production Mac approver and its real TLS,
// HPKE, persisted outbox and Keychain checkpoint. Never bundled with the app.
import AgentKeyringFeature
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
final class FixtureSigner: RelayApproverSigning {
    struct Saved: Codable { var human: Data; var automatic: Data; var authorizations: Int }
    let persistence: LeasePersistence
    var saved: Saved
    var publicKey: Data { try! P256.Signing.PrivateKey(rawRepresentation: saved.human).publicKey.x963Representation }
    var automaticPublicKey: Data { try! P256.Signing.PrivateKey(rawRepresentation: saved.automatic).publicKey.x963Representation }
    init(root: URL) throws {
        persistence = LeasePersistence(directory: root.appendingPathComponent("fixture-signing"),
            checkpointService: "com.agentkeyring.relay-proof.signing." + root.lastPathComponent)
        if let bytes = try persistence.load() { saved = try PropertyListDecoder().decode(Saved.self, from: bytes) }
        else {
            saved = Saved(human: P256.Signing.PrivateKey().rawRepresentation,
                automatic: P256.Signing.PrivateKey().rawRepresentation, authorizations: 0)
            try persistence.save(PropertyListEncoder().encode(saved))
        }
    }
    func authorize(context: LAContext, reason: String) async throws {
        try Task.checkCancellation()
        saved.authorizations += 1
        try persistence.save(PropertyListEncoder().encode(saved))
        print("AUTHORIZED\t\(saved.authorizations)")
        fflush(stdout)
    }
    func sign(_ bytes: Data, context: LAContext?, automatic: Bool) throws -> Data {
        if !automatic && context == nil { throw CredentialReleaseAuthorizationError.notVerified }
        return try P256.Signing.PrivateKey(rawRepresentation: automatic ? saved.automatic : saved.human).signature(for: bytes).derRepresentation
    }
}

@MainActor
final class FixtureVault {
    var rule = CredentialAccessPolicy.ask
    let root: URL
    init(root: URL) {
        self.root = root
        if let bytes = try? String(contentsOf: root.appendingPathComponent("fixture-rule"), encoding: .utf8),
            let saved = CredentialAccessPolicy(rawValue: bytes) { rule = saved }
    }
    func read() -> RelayApproverVault {
        let item = MirrorItem(id: MirrorItem.exampleCredentialID,
            sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "com.agentkeyring.example",
                accountID: Data("example@example.com".utf8), itemID: Data("example.com".utf8)),
            title: "example.com", origins: ["https://example.com", "http://127.0.0.1:8443"],
            credentials: [.password(userName: "example@example.com", password: "example-password"),
                .totp(secret: Data("12345678901234567890".utf8), period: 30, digits: 6,
                    userName: nil, algorithm: .sha1, issuer: "Synthetic proof")])
        return RelayApproverVault(generation: MirrorGeneration(id: MirrorItem.exampleCredentialID,
            previousGenerationID: nil, createdAt: Date(timeIntervalSince1970: 1), sourceExportedAt: Date(timeIntervalSince1970: 1),
            scope: .full, exporterIdentifier: "com.agentkeyring.example", exporterDisplayName: "Synthetic proof",
            items: [item], skippedCredentialCount: 0), policies: [item.id: rule])
    }
}
struct UnlockedFixture: CredentialSessionLockState { var isLocked: Bool { false } }

@main
struct RelayApproverFixture {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--dummy-only" else {
            fatalError("Use --dummy-only ISOLATED_DIRECTORY")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let signer = try FixtureSigner(root: root)
        let vault = FixtureVault(root: root)
        let identity = try RelayTLSIdentity.loadOrCreate(service: "com.agentkeyring.relay-proof.tls." + root.lastPathComponent)
        let persistence = LeasePersistence(directory: root.appendingPathComponent("approver"),
            checkpointService: "com.agentkeyring.relay-proof.authority." + root.lastPathComponent)
        let approver = RelayApprover(persistence: persistence, identity: identity, signer: signer,
            lockState: UnlockedFixture(), credentialSource: { vault.read() })
        try approver.load()
        approver.start()
        func show(_ update: RelayApproverUpdate) {
            if let pairing = update.pairing { print("PAIR\t\(pairing.fingerprint)") }
            for enrolment in update.enrolments { print("ENROL\t\(enrolment.id)\t\(enrolment.fingerprint)") }
            for pairing in update.approverPairings { print("APPROVER\t\(pairing.id)\t\(pairing.fingerprint)") }
            for request in update.requests {
                print("REQUEST\t\(request.id)\t\(request.lease.leaseID)\t\(request.lease.state.rawValue)\t\(request.answerIsQueued)\t\(request.lease.notAfterUnixSeconds)\t\(request.lease.retryNotBeforeUnixSeconds)")
            }
            for lease in update.leases {
                print("LEASE\t\(lease.id)\t\(lease.lease.state.rawValue)\t\(lease.endIsQueued)")
            }
            print("STATUS\t\(update.connection)\t\(update.queuedAnswerCount)\t\(update.needsPublication)\t\(signer.saved.authorizations)")
            fflush(stdout)
        }
        let updates = Task { for await update in approver.changes() { show(update) } }
        defer { updates.cancel(); approver.stop() }
        print("READY"); fflush(stdout)
        let lines = AsyncStream<String> { continuation in
            DispatchQueue.global().async {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
            }
        }
        for await line in lines {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            do {
                switch parts[0] {
                case "pair":
                    try await approver.beginPairing(RelayEndpoint(host: "127.0.0.1", port: UInt16(parts[1])!, allowsLoopbackForProof: true))
                case "confirm": try await approver.confirmPairing(comparedFingerprint: parts[1])
                case "enrol": try await approver.approveEnrolment(parts[1], comparedFingerprint: parts[2], automaticAllowed: parts[3] == "true")
                case "confirm-approver": try await approver.confirmApproverPairing(parts[1], comparedFingerprint: parts[2])
                case "publish": try await approver.publishCurrentRules()
                case "approve": try await approver.approve(parts[1])
                case "deny": try await approver.deny(parts[1], reply: parts.count > 2 ? parts[2] : "")
                case "clear": try await approver.clearDenial(loginID: MirrorItem.exampleCredentialID.uuidString, recipientID: parts[1])
                case "revoke": try await approver.revokeMachine(parts[1])
                case "end": try await approver.revokeLease(parts[1])
                case "rule":
                    vault.rule = parts[1] == "auto" ? .allowAutomatically : parts[1] == "block" ? .block : .ask
                    try vault.rule.rawValue.write(to: root.appendingPathComponent("fixture-rule"), atomically: true, encoding: .utf8)
                    approver.noteRulesChanged()
                case "status": show(approver.update)
                case "saved":
                    let bytes = try persistence.load()!
                    let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as! [String: Any]
                    if let requests = plist["requests"] as? [String: [String: Any]] {
                        for (id, saved) in requests {
                            if let data = saved["decision"] as? Data { print("SAVED\t\(id)\t\(RelayCrypto.hex(RelayCrypto.hash(data)))") }
                        }
                    }
                case "quit": return
                default: throw LeaseFailure(.invalidArgument, "Unknown fixture command")
                }
                print("DONE\t\(parts[0])")
            } catch {
                print("FAILED\t\(parts[0])\t\((error as? LeaseFailure)?.message ?? error.localizedDescription)")
            }
            fflush(stdout)
        }
    }
}
