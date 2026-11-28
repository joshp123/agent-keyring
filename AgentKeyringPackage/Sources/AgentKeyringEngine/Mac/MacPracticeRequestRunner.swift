// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// First run's practice request, from the Paper board "First run": it appears
// after Get Started, and one click and one touch prove that Touch ID, this
// Mac's Secure Enclave keys and its sealing all work. Josh sees only the practice
// request. No real password is used.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import OSLog

private let selfTestLogger = Logger(subsystem: "com.agentkeyring.app", category: "SelfTest")

@available(macOS 26.0, *)
extension MacKeyringEngine {
    static let testedAtKey = "macTestedAt"

    /// Josh clicked the green button on the practice request. `reason` follows
    /// "Agent Keyring is trying to" in macOS's dialog.
    public func runSelfTest(reason: String, context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        do {
            let keys = try macKeys()
            try await confirmOwner(context, reason: reason)
            var probe = Agentkeyring_V2_LoginSecret()
            probe.loginID = "self-test"
            probe.password = UUID().uuidString
            let opened = try keys.openSealedLogin(try CredentialSealing.sealLogin(probe, version: 0, to: keys.openingPublicKey, openerID: keys.deviceKeyID, signer: keys.signer), context: context)
            let signature = try keys.signWithDeviceKey(Data("agentkeyring.selftest.v2".utf8), context: context)
            guard opened.password == probe.password,
                keys.signingPublicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature),
                    for: Data("agentkeyring.selftest.v2".utf8))
            else { throw AgentRPCError(.unavailable, MessageCopy.practiceKeysFailed) }
            onAuthenticated()
            let now = Date()
            settings.set(now, forKey: Self.testedAtKey)
            testedAt = now
            selfTestLogger.notice("Self-test passed: Touch ID, the opening key and the signing key all work.")
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw error
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            // The request stays up with the error under it, so he can try again there.
            selfTestLogger.error("Self-test failed: \(message, privacy: .public)")
            throw error
        }
    }
}
#endif
