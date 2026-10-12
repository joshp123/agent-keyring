import CryptoKit
import Foundation
import Synchronization
import AgentKeyringFeature

final class FakeAccessRulesSigner: AccessRulesSigning {
    let key: Data
    let keyIsMissing: Bool
    let refusesSigning: Bool
    private let lastReason = Mutex<String?>(nil)
    var signingReason: String? { lastReason.withLock { $0 } }
    private let latestHash: Mutex<Data?>

    init(key: Data = Data("test rules key".utf8), keyIsMissing: Bool = false,
         refusesSigning: Bool = false, signedBytes: Data? = nil) {
        self.key = key
        self.keyIsMissing = keyIsMissing
        self.refusesSigning = refusesSigning
        latestHash = Mutex(signedBytes.map { Data(SHA256.hash(data: $0)) })
    }

    func sign(_ bytes: Data, reason: String) async throws -> Data {
        guard !refusesSigning else { throw CocoaError(.userCancelled) }
        lastReason.withLock { $0 = reason }
        latestHash.withLock { $0 = Data(SHA256.hash(data: bytes)) }
        return signature(for: bytes)
    }

    func signedBytesHash() throws -> Data? { latestHash.withLock { $0 } }

    func verify(_ signature: Data, for bytes: Data) throws -> Bool {
        guard !keyIsMissing else { throw NSError(domain: NSOSStatusErrorDomain, code: -25300) }
        return signature == self.signature(for: bytes)
    }

    func signature(for bytes: Data) -> Data {
        Data(SHA256.hash(data: key + bytes))
    }
}
