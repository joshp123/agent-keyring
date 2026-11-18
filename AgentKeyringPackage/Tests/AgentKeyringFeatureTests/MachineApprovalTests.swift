#if os(macOS)
@testable import AgentKeyringApprovalUI
import Foundation
import LocalAuthentication
import Testing

@MainActor
@Suite("Machine approval")
struct MachineApprovalTests {
    @Test("Changing the machine's Automatic switch cancels the old authorization")
    func machineSwitch() async throws {
        let backend = JoiningBackend()
        let joining = DeviceEnrolment(id: "machine", kind: .machine, name: "Build machine",
            tailnetNode: "", code: "verified", askedAt: .now)
        let model = MacEnrolmentModel(enrolment: joining, backend: backend, contextFactory: { LAContext() })
        let first = try #require(model.authenticationContext)
        model.waitForAuthentication()
        await Task.yield()
        #expect(backend.options == [false])
        model.allowAutomatic = true
        let second = try #require(model.authenticationContext)
        #expect(first !== second)
        model.waitForAuthentication()
        await Task.yield()
        #expect(backend.options == [false, true])
        await model.refuse()
        #expect(model.outcome == .refused)
        #expect(model.authenticationContext == nil)
    }

    @Test("A stuck machine authorization times out and can be retried")
    func timedOutMachine() async throws {
        let backend = JoiningBackend()
        let joining = DeviceEnrolment(id: "machine", kind: .machine, name: "Build machine",
            tailnetNode: "", code: "verified", askedAt: .now)
        let model = MacEnrolmentModel(enrolment: joining, backend: backend, contextFactory: { LAContext() })
        model.authenticationTimeoutDuration = .milliseconds(10)
        model.waitForAuthentication()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.failure == "Approval timed out.")
        #expect(model.outcome == nil)
        #expect(model.authenticationContext == nil)
        model.restartAuthentication()
        #expect(model.authenticationContext != nil)
        model.stopAuthentication()
    }
}

@MainActor
private final class JoiningBackend: MacEnrolmentBackend {
    var options: [Bool] = []
    func updates(enrolmentID: String) -> AsyncStream<DeviceEnrolment?> { AsyncStream { $0.finish() } }
    func approve(enrolmentID: String, comparedCode: String, allowAutomatic: Bool, context: LAContext?,
        onAuthenticated: @MainActor () -> Void, onCommitted: @MainActor () -> Void) async throws {
        options.append(allowAutomatic)
        try await Task.sleep(for: .seconds(30))
    }
    func refuse(enrolmentID: String) async throws {}
}
#endif
