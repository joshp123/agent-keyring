// Written by AI on 2026.11.27 by model gpt-6.2-sol.

#if os(macOS) && DEBUG
import AgentKeyringSealing
import Foundation
import Security

/// Delivers the payloads the loopback APNs server accepted, in the order it received them.
@MainActor
final class RecordedPushes {
    static let macToken = Data(repeating: 1, count: 32)
    static let phoneToken = Data(repeating: 2, count: 32)
    static let topic = "test.agentkeyring"
    private let directory: URL
    private var delivered: Set<URL> = []

    init(directory: URL) { self.directory = directory }

    func gateway() throws -> ApplePushGateway {
        let endpoint = try String(contentsOf: directory.appending(path: "gateway"), encoding: .utf8)
        let pem = try String(contentsOf: directory.appending(path: "apple-ca.pem"), encoding: .utf8)
        let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let address = URL(string: endpoint), address.scheme == "https",
              address.host == "127.0.0.1", address.port != nil,
              let der = Data(base64Encoded: base64), let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw PeerError("Invalid loopback APNs gateway or certificate")
        }
        return ApplePushGateway(production: address, sandbox: address, pin: try DeviceTLSIdentity.spki(certificate: cert))
    }

    func deliver(to token: Data, receive: ([AnyHashable: Any]) async -> Void) async throws {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let folder = directory.appending(path: "pushes/\(hex)")
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") && !delivered.contains(file) {
            let data = try Data(contentsOf: file)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] else {
                throw PeerError("APNs payload is not a JSON object")
            }
            delivered.insert(file)
            await receive(payload)
        }
    }
}
#endif
