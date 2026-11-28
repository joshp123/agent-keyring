// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The simulator has no Secure Enclave and no Face ID unlock to reuse, so a
// simulator build keeps software keys in its keychain. Device builds never
// compile this.

#if targetEnvironment(simulator)
import AgentKeyringEngine
import AgentKeyringProtocol
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

    private func signing(_ name: String) throws -> P256.Signing.PrivateKey { try .init(rawRepresentation: raw(name)) }
    private func agreement(_ name: String) throws -> P256.KeyAgreement.PrivateKey { try .init(rawRepresentation: raw(name)) }

    func signingPublicKey() throws -> Data { try signing("signing").publicKey.x963Representation }
    func openingPublicKey() throws -> Data { try agreement("opening").publicKey.x963Representation }
    func replyPublicKey() throws -> Data { try signing("reply").publicKey.x963Representation }
    func noticePublicKey() throws -> Data { try agreement("notice").publicKey.x963Representation }
    func authorize(_ context: LAContext, reason: String) async throws {}
    func signWithDeviceKey(_ bytes: Data, context: LAContext) throws -> Data { try signing("signing").signature(for: bytes).derRepresentation }
    func openSealedLogin(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret { try CredentialSealing.openSealedLogin(sealed, with: agreement("opening")) }
    func signReply(_ bytes: Data) throws -> Data { try signing("reply").signature(for: bytes).derRepresentation }
    func replySigner() throws -> @Sendable (Data) throws -> Data {
        let key = try signing("reply")
        return { try key.signature(for: $0).derRepresentation }
    }
    func opener(context: LAContext) throws -> @Sendable (SealedLogin) throws -> LoginSecret {
        let key = try agreement("opening")
        return { try CredentialSealing.openSealedLogin($0, with: key) }
    }
    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        try CredentialSealing.openNotice(notice, deviceKeyID: deviceKeyID, with: agreement("notice"))
    }
    func cloudKeyOpener() throws -> CloudEnvelope.KeyOpener {
        let key = try agreement("notice")
        return { try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: key) }
    }
}
#endif
