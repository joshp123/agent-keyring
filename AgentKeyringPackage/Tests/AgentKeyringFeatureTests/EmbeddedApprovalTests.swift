#if os(macOS)
@testable import AgentKeyringApprovalUI
import Foundation
import LocalAuthentication
import Testing

@MainActor
@Suite("Embedded approval")
struct EmbeddedApprovalTests {
    @Test("A plain denial cancels the pending approval and needs no authentication")
    func plainDenial() async throws {
        let backend = RequestBackend()
        let model = MacApprovalModel(request: request(), backend: backend)
        model.waitForTouch()
        await Task.yield()
        await model.deny()
        #expect(backend.cancelled == 1)
        #expect(backend.denials == [false])
        #expect(model.request.state == .denied(by: .mac, reply: nil, askAgainAfter: nil))
    }

    @Test("A remote denial with a reply authenticates the reply, not the approval")
    func signedDenial() async throws {
        let backend = RequestBackend()
        let model = MacApprovalModel(request: request(), backend: backend)
        model.waitForTouch()
        await Task.yield()
        model.replyDraft = "Please wait"
        await model.deny()
        #expect(backend.denials.isEmpty)
        #expect(model.pendingDenialReply == "Please wait")
        model.waitForTouch()
        await Task.yield()
        await Task.yield()
        #expect(backend.denials == [true])
        #expect(model.request.state == .denied(by: .mac, reply: "Please wait", askAgainAfter: nil))
    }

    @Test("An interrupted authentication leaves the request available to retry")
    func interruptedApproval() async throws {
        let backend = RequestBackend()
        backend.approvalError = NSError(domain: LAError.errorDomain, code: LAError.Code.systemCancel.rawValue)
        let model = MacApprovalModel(request: request(), backend: backend)
        model.waitForTouch()
        await Task.yield()
        await Task.yield()
        #expect(model.failure == "Approval was interrupted. Try again.")
        #expect(model.embeddedTouchID == nil)
        #expect(model.request.state.isWaitingForYou)
        backend.approvalError = nil
        model.retryAuthentication()
        #expect(model.embeddedTouchID != nil)
        model.stopWaitingForTouch()
    }

    @Test("A stuck authentication times out without ending the request")
    func timedOutApproval() async throws {
        let backend = RequestBackend()
        let model = MacApprovalModel(request: request(), backend: backend)
        model.authenticationTimeoutDuration = .milliseconds(10)
        model.waitForTouch()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.failure == "Approval timed out. Try again.")
        #expect(model.embeddedTouchID == nil)
        #expect(model.request.state.isWaitingForYou)
        model.retryAuthentication()
        #expect(model.embeddedTouchID != nil)
    }

    @Test("A slow delivery does not turn an authenticated approval into a timeout")
    func deliveryAfterAuthentication() async throws {
        let backend = RequestBackend()
        backend.slowDelivery = true
        let model = MacApprovalModel(request: request(), backend: backend)
        model.authenticationTimeoutDuration = .milliseconds(10)
        model.waitForTouch()
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.failure == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.request.state.isInUse)
    }

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
        #expect(model.failure == "Approval timed out. Try again.")
        #expect(model.outcome == nil)
        #expect(model.authenticationContext == nil)
        model.restartAuthentication()
        #expect(model.authenticationContext != nil)
        model.stopAuthentication()
    }

    private func request() -> AccessRequest {
        AccessRequest(id: "request", login: RequestedLogin(site: "example.com", account: "user"),
            agent: RequestingAgent(name: "Agent", machine: "Build machine", address: "", isLocal: false),
            access: .agentProcess, agentReason: "test", askedAt: .now,
            state: .waitingForYou(until: .now.addingTimeInterval(60)))
    }
}

@MainActor
private final class RequestBackend: MacApprovalBackend {
    var context: LAContext?
    var cancelled = 0
    var denials: [Bool] = []
    var approvalError: Error?
    var slowDelivery = false
    func updates(requestID: String) -> AsyncStream<AccessRequest> { AsyncStream { $0.finish() } }
    func embeddedTouchIDContext(requestID: String) -> LAContext? {
        let context = LAContext(); self.context = context; return context
    }
    func cancelAuthentication(requestID: String) { context?.invalidate(); context = nil; cancelled += 1 }
    func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        if let approvalError { context = nil; throw approvalError }
        if slowDelivery {
            onAuthenticated()
            try await Task.sleep(for: .milliseconds(100))
            return .approved(by: .mac, until: .now.addingTimeInterval(60))
        }
        try await Task.sleep(for: .seconds(30))
        return .approved(by: .mac, until: .now)
    }
    func deny(requestID: String, reply: String?, context: LAContext?, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
        denials.append(context != nil)
        return .denied(by: .mac, reply: reply, askAgainAfter: nil)
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
