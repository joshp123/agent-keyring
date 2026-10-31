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
    let signer: P256.Signing.PrivateKey
    init(_ directory: URL) throws {
        self.directory = directory
        signer = try P256.Signing.PrivateKey(rawRepresentation: Data(contentsOf: directory.appending(path: "signing.raw")))
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
        let approver = PhoneRelayApprover(directory: directory.appending(path: "approver"), keys: keys, identity: { identity })
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
