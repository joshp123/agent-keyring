import Foundation
import LocalAuthentication
import Testing
@testable import AgentKeyringEngine

@Suite("Native credential approval failures")
struct CredentialAuthorizationFailureTests {
    @Test("Each native failure maps to what it means, and a passed deadline always reads as expired")
    func nativeFailureMapping() {
        let now = Date(timeIntervalSince1970: 1_000)
        let la = LAError.errorDomain
        let cases: [(domain: String, code: Int, deadlinePassed: Bool, expected: CredentialReleaseAuthorizationError)] = [
            (la, -2, false, .denied),
            (la, -1, false, .notVerified),
            (la, -8, false, .notVerified),
            (la, -4, false, .interrupted),
            (la, -6, false, .unavailable),
            (la, -11, false, .unavailable),
            (la, -1004, false, .unavailable),
            (la, -9, false, .systemFailure(domain: la, code: -9)),
            (la, -10, false, .systemFailure(domain: la, code: -10)),
            (la, -999, false, .systemFailure(domain: la, code: -999)),
            (la, -4, true, .expired),
            ("example.failure", -2, false, .systemFailure(domain: "example.failure", code: -2)),
        ]
        for item in cases {
            let deadline = item.deadlinePassed ? now : now.addingTimeInterval(120)
            let result = CredentialReleaseAuthorizationError.classifyNativeFailure(
                NSError(domain: item.domain, code: item.code), authorizationDeadline: deadline, now: now)
            #expect(result == item.expected, "\(item.domain) \(item.code), deadline passed: \(item.deadlinePassed)")
        }
    }
}
