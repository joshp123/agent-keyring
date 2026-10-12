import CryptoKit
import Foundation
import AgentKeyringFeature

struct FakeAccessRulesSigner: AccessRulesSigning {
    var key = Data("test rules key".utf8)
    var keyIsMissing = false
    var refusesSigning = false

    func sign(_ bytes: Data) async throws -> Data {
        guard !refusesSigning else { throw CocoaError(.userCancelled) }
        return signature(for: bytes)
    }

    func verify(_ signature: Data, for bytes: Data) throws -> Bool {
        guard !keyIsMissing else { throw CocoaError(.fileNoSuchFile) }
        return signature == self.signature(for: bytes)
    }

    func signature(for bytes: Data) -> Data {
        Data(SHA256.hash(data: key + bytes))
    }
}
