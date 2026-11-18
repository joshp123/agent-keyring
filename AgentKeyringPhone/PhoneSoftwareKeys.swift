// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The simulator has no Secure Enclave and no Face ID unlock to reuse, so a
// simulator build keeps software keys in its keychain. Device builds never
// compile this.

#if targetEnvironment(simulator)
import AgentKeyringPhoneApprover
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

struct PhoneSoftwareKeys: PhoneDeviceKeys {
    private let defaults = UserDefaults.standard

    private func raw(_ name: String) -> Data {
        let key = "SimulatorKey.\(name)"
        if let saved = defaults.data(forKey: key) { return saved }
        let fresh = P256.Signing.PrivateKey().rawRepresentation
        defaults.set(fresh, forKey: key)
        return fresh
    }

    private func signing(_ name: String) -> P256.Signing.PrivateKey { try! .init(rawRepresentation: raw(name)) }
    private func agreement(_ name: String) -> P256.KeyAgreement.PrivateKey { try! .init(rawRepresentation: raw(name)) }

    func signingPublicKey() throws -> Data { signing("signing").publicKey.x963Representation }
    func openingPublicKey() throws -> Data { agreement("opening").publicKey.x963Representation }
    func replyPublicKey() throws -> Data { signing("reply").publicKey.x963Representation }
    func noticePublicKey() throws -> Data { agreement("notice").publicKey.x963Representation }
    func authorize(_ context: LAContext, reason: String) async throws {}
    func sign(_ bytes: Data, context: LAContext) throws -> Data { try signing("signing").signature(for: bytes).derRepresentation }
    func open(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret { try Sealing.open(sealed, with: agreement("opening")) }
    func signReply(_ bytes: Data) throws -> Data { try signing("reply").signature(for: bytes).derRepresentation }
}
#endif
