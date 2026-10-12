import Foundation
import LocalAuthentication
import Testing
@testable import AgentKeyringFeature

@Suite("Native credential approval failures")
struct CredentialAuthorizationFailureTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("System and app cancellations preserve the native failure", arguments: [-9, -10, -999])
    func systemFailure(code: Int) {
        let error = NSError(domain: LAError.errorDomain, code: code)
        #expect(classify(error) == .systemFailure(domain: LAError.errorDomain, code: code))
    }

    @Test("Failed authentication and biometry lockout have an explicit retry result", arguments: [-1, -8])
    func notVerified(code: Int) {
        #expect(classify(NSError(domain: LAError.errorDomain, code: code)) == .notVerified)
        #expect(CredentialReleaseAuthorizationError.notVerified.errorDescription ==
            "Touch ID or Apple Watch did not verify; retry the request.")
    }

    @Test("Only user cancellation is a decline", arguments: [-2])
    func denied(code: Int) {
        #expect(classify(NSError(domain: LAError.errorDomain, code: code)) == .denied)
    }

    @Test("System cancellation is an interruption, never a decline")
    func systemCancel() {
        #expect(classify(NSError(domain: LAError.errorDomain, code: -4)) == .interrupted)
    }

    @Test("Unavailable mechanisms and noninteractive requests stay unavailable", arguments: [-6, -11, -1004])
    func unavailable(code: Int) {
        #expect(classify(NSError(domain: LAError.errorDomain, code: code)) == .unavailable)
    }

    @Test("An expired request remains expired even after native cancellation")
    func expired() {
        #expect(CredentialReleaseAuthorizationError.classifyNativeFailure(
            NSError(domain: LAError.errorDomain, code: -4),
            authorizationDeadline: now, now: now
        ) == .expired)
    }

    @Test("A numeric error outside LocalAuthentication is not interpreted as user refusal")
    func otherDomain() {
        #expect(classify(NSError(domain: "example.failure", code: -2)) ==
            .systemFailure(domain: "example.failure", code: -2))
    }

    private func classify(_ error: NSError) -> CredentialReleaseAuthorizationError {
        .classifyNativeFailure(error, authorizationDeadline: now.addingTimeInterval(120), now: now)
    }
}
