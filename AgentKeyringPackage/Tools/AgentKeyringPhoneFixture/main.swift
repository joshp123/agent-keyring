// Written by AI on 2026.10.31 by model gpt-6.1-sol.
// Process fixture only. Software keys and dummy credentials never enter the iOS app.
import AgentKeyringPhoneApprover
import AgentKeyringRelaySupport
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
final class FixtureKeys: PhoneApproverKeys {
    let directory: URL
    var signer: P256.Signing.PrivateKey
    var sealer: P256.KeyAgreement.PrivateKey
    var authorizedContext: LAContext?
    init(_ directory: URL) throws {
        self.directory = directory
        let url = directory.appending(path: "sealing.raw")
        if FileManager.default.fileExists(atPath: url.path) {
            sealer = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(contentsOf: url))
        } else {
            sealer = P256.KeyAgreement.PrivateKey()
            try sealer.rawRepresentation.write(to: url, options: .atomic)
        }
        signer = try P256.Signing.PrivateKey(rawRepresentation: Data(contentsOf: directory.appending(path: "signing.raw")))
    }
    func signingPublicKey() throws -> Data { signer.publicKey.x963Representation }
    func encryptionPublicKey() throws -> Data { sealer.publicKey.x963Representation }
    func replace() throws {
        signer = P256.Signing.PrivateKey(); sealer = P256.KeyAgreement.PrivateKey()
        try signer.rawRepresentation.write(to: directory.appending(path: "signing.raw"), options: .atomic)
        try sealer.rawRepresentation.write(to: directory.appending(path: "sealing.raw"), options: .atomic)
        authorizedContext = nil
    }
    func openCopy(encapsulatedKey: Data, ciphertext: Data, associatedData: Data, context: LAContext) throws -> Data {
        precondition(authorizedContext === context)
        var recipient = try HPKE.Recipient(privateKey: sealer, ciphersuite: .P256_SHA256_AES_GCM_256,
                                           info: Data("agentkeyring.login-copy.v1".utf8), encapsulatedKey: encapsulatedKey)
        return try recipient.open(ciphertext, authenticating: associatedData)
    }
    func authorize(_ context: LAContext, reason: String) async throws {
        authorizedContext = context
        let url = directory.appending(path: "authorization-count")
        let count = (try? String(contentsOf: url, encoding: .utf8)).flatMap(Int.init) ?? 0
        try Data(String(count + 1).utf8).write(to: url, options: .atomic)
        while FileManager.default.fileExists(atPath: directory.appending(path: "hold-authorization").path) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func sign(_ bytes: Data, context: LAContext) throws -> Data {
        precondition(authorizedContext === context)
        return try signer.signature(for: bytes).derRepresentation
    }
}

func output(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

@main
struct PhoneFixture {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, arguments[1] == "--dummy-state" else { fatalError("Use --dummy-state DIRECTORY") }
        let directory = URL(filePath: arguments[2], directoryHint: .isDirectory)
        let keys = try FixtureKeys(directory)
        var identity = try RelayTLSIdentity(privateKey: Data(contentsOf: directory.appending(path: "tls-private.x963")),
                                            certificate: Data(contentsOf: directory.appending(path: "tls-cert.der")))
        let approver = PhoneRelayApprover(directory: directory.appending(path: "approver"), keys: keys, identity: { identity }, replaceIdentity: {
            try keys.replace()
            let privateKey = try Data(contentsOf: directory.appending(path: "replacement-tls-private.x963"))
            let certificate = try Data(contentsOf: directory.appending(path: "replacement-tls-cert.der"))
            identity = try RelayTLSIdentity(privateKey: privateKey, certificate: certificate)
            try privateKey.write(to: directory.appending(path: "tls-private.x963"), options: .atomic)
            try certificate.write(to: directory.appending(path: "tls-cert.der"), options: .atomic)
        })
        try approver.load(); approver.start()
        output("READY")
        while let line = await Task.detached(operation: { readLine() }).value {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            do {
                switch parts[0] {
                case "pair":
                    try await approver.beginPairing(endpoint: RelayEndpoint(host: "localhost", port: UInt16(parts[1])!, allowsLoopbackForProof: true))
                    if case let .comparing(fingerprint, _) = approver.pairing { output("PAIR\t" + fingerprint) }
                    else { output("PAIRED") }
                case "probe-non-tailnet":
                    let connection = RelayConnection(endpoint: try RelayEndpoint(host: "localhost", port: UInt16(parts[1])!), identity: identity, pin: nil)
                    defer { connection.cancel() }
                    do {
                        try await connection.open()
                        output("ERROR\tNon-tailnet connection was permitted")
                    } catch let error as RelayFailure where error.code == .permissionDenied {
                        output("REFUSED\tNon-tailnet peer rejected before sending a request")
                    }
                case "status":
                    output("STATUS\t\(approver.pairing)\t\(try approver.requests().count)")
                case "replace-pairing":
                    try await approver.beginReplacementPairing()
                    if case let .comparing(fingerprint, _) = approver.pairing { output("PAIR\t" + fingerprint) }
                    else { output("PAIRED") }
                case "cancel-pairing": approver.cancelPairing(); output("CANCELLED")
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
