// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Process fixture only. Software keys and dummy credentials never enter the iOS app.
import AgentKeyringCredentialImport
import AgentKeyringPhoneApprover
import AgentKeyringPhoneVault
import AgentKeyringRelaySupport
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
final class FixtureKeys: PhoneApproverKeys {
    let directory: URL
    let signer: P256.Signing.PrivateKey
    let agreement: P256.KeyAgreement.PrivateKey
    init(_ directory: URL) throws {
        self.directory = directory
        signer = try P256.Signing.PrivateKey(rawRepresentation: Data(contentsOf: directory.appending(path: "signing.raw")))
        agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(contentsOf: directory.appending(path: "agreement.raw")))
    }
    func signingPublicKey() throws -> Data { signer.publicKey.x963Representation }
    func authorize(_ context: LAContext, reason: String) async throws {
        let url = directory.appending(path: "authorization-count")
        let count = (try? String(contentsOf: url, encoding: .utf8)).flatMap(Int.init) ?? 0
        try Data(String(count + 1).utf8).write(to: url, options: .atomic)
        while FileManager.default.fileExists(atPath: directory.appending(path: "hold-authorization").path) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func sharedSecret(with publicKey: P256.KeyAgreement.PublicKey, context: LAContext) throws -> SharedSecret {
        try agreement.sharedSecretFromKeyAgreement(with: publicKey)
    }
    func sign(_ bytes: Data, context: LAContext) throws -> Data { try signer.signature(for: bytes).derRepresentation }
}

func output(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

@main
struct PhoneFixture {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "--dummy-state" else { fatalError("Use --dummy-state DIRECTORY") }
        let directory = URL(filePath: arguments[2], directoryHint: .isDirectory)
        let keys = try FixtureKeys(directory)
        let identity = try RelayTLSIdentity(privateKey: Data(contentsOf: directory.appending(path: "tls-private.x963")),
                                            certificate: Data(contentsOf: directory.appending(path: "tls-cert.der")))
        let vault = PhoneVault(directory: directory.appending(path: "vault"))
        if try vault.status() == nil {
            let item = MirrorItem(id: UUID(), sourceIdentity: MirrorSourceIdentity(exporterIdentifier: "phone-fixture", accountID: Data([1]), itemID: Data([2])),
                                  title: "example.com", origins: ["https://example.com"],
                                  credentials: [.password(userName: "fixture", password: "phone-fixture-password"),
                                                .totp(secret: Data("12345678901234567890".utf8), period: 30, digits: 6, userName: "fixture", algorithm: .sha1, issuer: "Fixture")])
            _ = try vault.importCredentials(MirrorImportBatch(scope: .selected, exportedAt: Date(), exporterIdentifier: "phone-fixture",
                                                              exporterDisplayName: "Dummy", items: [item], skippedCredentialCount: 0), publicKey: keys.agreement.publicKey)
        }
        let approver = PhoneRelayApprover(directory: directory.appending(path: "approver"), vault: vault, keys: keys, identity: { identity })
        try approver.load(); approver.start()
        output("READY")
        while let line = await Task.detached(operation: { readLine() }).value {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            do {
                switch parts[0] {
                case "pair":
                    try await approver.beginPairing(endpoint: RelayEndpoint(host: "127.0.0.1", port: UInt16(parts[1])!, allowsLoopbackForProof: true))
                    if case let .comparing(fingerprint, _) = approver.pairing { output("PAIR\t" + fingerprint) }
                    else { output("PAIRED") }
                case "status":
                    output("STATUS\t\(approver.pairing)\t\(try approver.requests().count)")
                case "requests":
                    let requests = try approver.requests()
                    output("REQUESTS\t" + requests.map { "\($0.id)=\($0.state)" }.joined(separator: "\t"))
                case "approve": output("ANSWER\t\(try await approver.approve(parts[1]))")
                case "deny": output("ANSWER\t\(try await approver.deny(parts[1], reply: parts.count > 2 ? parts[2] : nil))")
                case "clear": output("CLEARED\t\(try await approver.clearDenial(parts[1]))")
                case "end": output("ENDED\t\(try await approver.endAccess(parts[1]))")
                case "stop": approver.stop(); output("STOPPED")
                case "start": approver.reconnect(); output("STARTED")
                case "quit": approver.stop(); return
                default: output("ERROR\tUnknown command")
                }
            } catch { output("ERROR\t\(error)") }
        }
        approver.stop()
    }
}
