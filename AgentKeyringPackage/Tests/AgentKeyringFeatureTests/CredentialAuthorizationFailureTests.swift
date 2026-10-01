import Foundation
import LocalAuthentication
import Testing
@testable import AgentKeyringFeature

@Suite("Native credential approval failures")
struct CredentialAuthorizationFailureTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test("System and app cancellations preserve the native failure", arguments: [-4, -9, -10, -999])
    func systemFailure(code: Int) {
        let error = NSError(domain: LAError.errorDomain, code: code)
        #expect(classify(error) == .systemFailure(domain: LAError.errorDomain, code: code))
    }

    @Test("User cancellation and failed authentication stay unapproved", arguments: [-2, -1])
    func denied(code: Int) {
        #expect(classify(NSError(domain: LAError.errorDomain, code: code)) == .denied)
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
