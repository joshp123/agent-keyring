// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// An isolated authority process for full-system socket proofs, never bundled.
// Only example.com exists. Access-rule signing and biometrics are fixtures;
// socket handling, lease state, Keychain checkpointing and mirror are production.
import AgentKeyringFeature
import AgentKeyringTestSupport
import Foundation
import LocalAuthentication
import Security

@MainActor
final class FixtureApproval: CredentialReleaseAuthorizing {
    var ownerApproved = false
    func authorize(_ request: CredentialReleaseAuthorizationRequest, onPromptStarted: @escaping () -> Void) async throws {
        guard ownerApproved else { throw CredentialReleaseAuthorizationError.unavailable }
        ownerApproved = false
        onPromptStarted()
    }
}

@main
struct AuthorityFixture {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Fixture unavailable: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        guard (2...3).contains(CommandLine.arguments.count),
            CommandLine.arguments.count == 2 || CommandLine.arguments[2] == "--with-code" else {
            throw LeaseFailure(.invalidArgument, "Supply an isolated directory and optional --with-code")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let checkpointService = "com.agentkeyring.authority-fixture." + root.lastPathComponent
        let ruleFile = root.appendingPathComponent("rules.json")
        let signer = FakeAccessRulesSigner(signedBytes: try? Data(contentsOf: ruleFile))
        let rules = CredentialAccessPolicyStore(fileURL: ruleFile, signer: signer)
        if !FileManager.default.fileExists(atPath: ruleFile.path) {
            try await confirmInitialAccessRules(in: rules, policies: [MirrorItem.exampleCredentialID: .allowAutomatically])
        }
        let access = CredentialAccessController(store: rules)
        let settings = UserDefaults(suiteName: "AgentKeyringAuthorityFixture")!
        settings.set(true, forKey: "includeExampleCredential")
        let vault = EncryptedSnapshotStore(directoryURL: root.appendingPathComponent("vault"),
            keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x36, count: 32)))
        if CommandLine.arguments.count == 3, try await vault.loadCurrent() == nil {
            let item = MirrorItem(id: MirrorItem.exampleCredentialID,
                sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "com.agentkeyring.example",
                    accountID: Data("example@example.com".utf8), itemID: Data("example.com".utf8)),
                title: "example.com", origins: ["https://example.com", "http://127.0.0.1:8443"],
                credentials: [.password(userName: "example@example.com", password: "example-password"),
                    .totp(secret: Data("12345678901234567890".utf8), period: 30, digits: 6,
                        userName: nil, algorithm: .sha1, issuer: "Synthetic proof")])
            try await vault.save(MirrorGeneration(id: UUID(), previousGenerationID: nil,
                createdAt: Date(), sourceExportedAt: Date(), scope: .full,
                exporterIdentifier: "com.agentkeyring.example", exporterDisplayName: "Synthetic proof",
                items: [item], skippedCredentialCount: 0))
        }
        let approval = FixtureApproval()
        let model = MirrorAppModel(store: vault,
            authorizer: approval, bridge: AgentBridgeDirectory(rootURL: root), accessControl: access,
            leaseStore: CredentialLeaseStore(persistence: LeasePersistence(directory: root.appendingPathComponent("leases"),
                checkpointService: checkpointService)), settings: settings)
        model.automaticallyPromptForLeases = false
        await model.loadStatus()
        try model.startAgentListener()
        print("Ready: \(root.appendingPathComponent("agent.sock").path)")
        fflush(stdout)
        // Control input represents the owner's actions; it proves neither
        // biometrics nor the app's approval panel. This tool is never bundled.
        let lines = AsyncStream<String> { continuation in
            DispatchQueue.global().async {
                while let line = readLine() { continuation.yield(line) }
                continuation.finish()
            }
        }
        for await line in lines {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard let command = parts.first else { continue }
            do {
                switch command {
                case "ask", "auto", "block":
                    let rule: CredentialAccessPolicy = command == "ask" ? .ask : command == "auto" ? .allowAutomatically : .block
                    await access.setPolicy(rule, for: [MirrorItem.exampleCredentialID])
                case "deny" where parts.count >= 2:
                    try model.denyLease(parts[1], reply: parts.count == 3 ? parts[2] : "")
                case "approve" where parts.count == 2:
                    approval.ownerApproved = true
                    defer { approval.ownerApproved = false }
                    try await model.approveLeaseWithTouchID(parts[1])
                case "revoke" where parts.count == 2:
                    try model.leaseStore.revoke(parts[1])
                case "failed-approval" where parts.count == 2:
                    do {
                        try await model.approveLeaseWithTouchID(parts[1])
                        throw LeaseFailure(.unavailable, "Fixture must never approve")
                    } catch CredentialReleaseAuthorizationError.unavailable {}
                case "cancel-approval" where parts.count == 2:
                    let approval = Task { try await model.approveLeaseWithTouchID(parts[1], context: LAContext()) }
                    approval.cancel()
                    do {
                        try await approval.value
                        throw LeaseFailure(.unavailable, "Cancelled fixture must never approve")
                    } catch is CancellationError {}
                case "clear-denial": try model.leaseStore.clearDenial(loginID: MirrorItem.exampleCredentialID.uuidString)
                case "erase-test-checkpoint-and-quit":
                    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: checkpointService, kSecAttrAccount as String: "committed-snapshot",
                        kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
                    let status = SecItemDelete(query as CFDictionary)
                    guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
                    print("Removed this fixture's local checkpoint")
                    return
                case "quit": return
                default: print("Unknown owner action")
                }
                print("Owner action committed")
            } catch { print("Owner action failed: \(error)") }
            fflush(stdout)
        }
    }
}
