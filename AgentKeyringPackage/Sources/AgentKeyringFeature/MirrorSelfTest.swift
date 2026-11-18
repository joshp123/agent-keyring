// Written by AI on 2026.11.18 by model claude opus 5.5.
//
// First run's test request, from the Paper board "First run": it appears by
// itself when the logins arrive, and one click and one touch prove that
// Touch ID, this Mac's chip keys and its sealing all work. No login is used.

import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication
import OSLog

private let selfTestLogger = Logger(subsystem: "com.agentkeyring.app", category: "SelfTest")

public enum MacSelfTest: Equatable, Sendable {
    case notRun
    /// The test request is beside the pointer.
    case waiting
    case passed(Date)
    case failed(String)
    /// He denied the test request: nothing is wrong, it is simply not tested.
    case declined
}

@available(macOS 26.0, *)
extension MirrorAppModel {
    static let testedAtKey = "macTestedAt"

    /// Offers the test once there are logins and this Mac has not passed it.
    func offerSelfTestIfNeeded() {
        guard status != nil else { return }
        if case .passed = selfTest { return }
        selfTest = .waiting
    }

    /// Josh clicked Approve on the test request.
    public func runSelfTest(context: LAContext, onAuthenticated: @MainActor () -> Void) async throws {
        do {
            let keys = try macKeys()
            try await OwnerConfirmation.confirm(context, reason: "run a test that uses no login", until: .now.addingTimeInterval(600))
            var probe = Agentkeyring_V2_LoginSecret()
            probe.loginID = "self-test"
            probe.password = UUID().uuidString
            let opened = try keys.open(try Sealing.seal(probe, to: keys.openingPublicKey, openerID: keys.deviceKeyID), context: context)
            let signature = try keys.sign(Data("agentkeyring.selftest.v2".utf8), context: context)
            guard opened.password == probe.password,
                keys.signingPublicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature),
                    for: Data("agentkeyring.selftest.v2".utf8))
            else { throw LeaseFailure(.unavailable, "This Mac's chip keys did not open or sign correctly.") }
            onAuthenticated()
            let now = Date()
            settings.set(now, forKey: Self.testedAtKey)
            selfTest = .passed(now)
            selfTestLogger.notice("Self-test passed: Touch ID, the opening key and the signing key all work.")
            await device?.reportSelfTest(passed: true, error: "")
        } catch let error as CredentialReleaseAuthorizationError where error.isCancel {
            throw error
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            selfTest = .failed(message)
            selfTestLogger.error("Self-test failed: \(message, privacy: .public)")
            await device?.reportSelfTest(passed: false, error: message)
            throw error
        }
    }

    /// The relay keeps each device's last test; a Mac that joins later sends the one it has.
    public func reportLastSelfTest() async {
        if case .passed = selfTest { await device?.reportSelfTest(passed: true, error: "") }
    }

    public func declineSelfTest() {
        selfTest = .declined
    }

    /// "Send It Again".
    public func sendSelfTestAgain() {
        selfTest = .waiting
    }
}
