// Written by AI on 2026.11.18 by model claude opus 5.5.
// The request panel crashed in a sitting with an endless layout loop between
// its SwiftUI host and the window. This drives the real host and window, off
// screen, through every state many times.
#if os(macOS)
import AppKit
import Testing
@testable import AgentKeyringApprovalUI

@MainActor
@Test func requestPanelResizesWithoutALayoutLoop() async throws {
    _ = NSApplication.shared
    ReviewRendering.isOn = true
    var request = AccessRequest(id: "r", login: RequestedLogin(site: "example.com", account: "you@example.com"),
        agent: RequestingAgent(name: "Codex", machine: "Mac mini", address: "100.64.0.2", folder: "/tmp/bookkeeping"),
        access: .login, agentReason: "You asked me to download October’s invoice.", askedAt: .now,
        state: .waitingForYou(until: .now.addingTimeInterval(600)))
    let view = ReviewRendering.panel(request)
    _ = view
    final class Backend: MacApprovalBackend {
        func updates(requestID: String) -> AsyncStream<AccessRequest> { AsyncStream { $0.finish() } }
        func cancelAuthentication(requestID: String) {}
        func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState { .unanswered }
        func deny(requestID: String, reply: String?) async throws -> AccessRequestState { .unanswered }
        func allowAskingAgain(requestID: String) async throws -> AccessRequestState { .unanswered }
    }
    let model = MacApprovalModel(request: request, backend: Backend())
    let host = RequestPanelHost(model: model)
    host.panel.setFrame(NSRect(x: 100, y: 100, width: 420, height: 200), display: false)
    var heights = Set<Int>()
    let states: [AccessRequestState] = [.waitingForYou(until: .now.addingTimeInterval(600)), .sendingAnswer(.approve),
        .approved(by: .mac, until: .now.addingTimeInterval(1800)), .denied(by: .mac, reply: "Use the other account, the one for work.", askAgainAfter: nil), .unanswered]
    for round in 0..<300 {
        request.state = states[round % states.count]
        model.replyDraft = round % 2 == 0 ? "" : String(repeating: "typing ", count: round % 7)
        await model.replace(request)
        host.panel.contentView?.layoutSubtreeIfNeeded()
        host.panel.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(2))
        heights.insert(Int(host.panel.frame.height))
    }
    // The asking and answered states must give two different, stable heights.
    #expect(heights.count >= 2)
    #expect(heights.allSatisfy { $0 > 50 && $0 < 600 })
}
#endif

#if os(macOS)
/// During first run the request sits beside the window that explains it, never over it:
/// on his 16-inch screen (1728 points wide), and on a 13-inch one (1280) with the wider main window.
@MainActor @Test func requestPanelNeverCoversAgentKeyringsOwnWindow() {
    let panel = CGSize(width: 420, height: 330)
    let sixteen = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    for windowX in stride(from: 0.0, through: 1328.0, by: 64) {
        let practice = CGRect(x: windowX, y: 500, width: 400, height: 330)
        let placed = RequestPanel.frame(size: panel, beside: practice, visibleFrames: [sixteen])
        #expect(!placed.panel.intersects(placed.window), "window at \(windowX)")
        #expect(sixteen.contains(placed.panel) && sixteen.contains(placed.window))
    }
    let thirteen = CGRect(x: 0, y: 0, width: 1280, height: 800)
    let main = CGRect(x: 230, y: 100, width: 820, height: 600)
    let placed = RequestPanel.frame(size: panel, beside: main, visibleFrames: [thirteen])
    #expect(!placed.panel.intersects(placed.window))
    #expect(thirteen.contains(placed.panel) && thirteen.contains(placed.window))
}
#endif

#if os(macOS)
/// He types a reply and clicks Deny; while it is on its way the relay reports
/// the request as still waiting. The panel stays on his answer, then shows the denial.
@MainActor
@Test func anUpdateWhileHisDenialIsSentDoesNotUndoIt() async throws {
    let waiting = AccessRequest(id: "r", login: RequestedLogin(site: "example.com", account: "you@example.com"),
        agent: RequestingAgent(name: "Codex", machine: "this Mac", address: "", isLocal: true), access: .login, agentReason: "",
        askedAt: .now, state: .waitingForYou(until: .now.addingTimeInterval(600)))
    final class Backend: MacApprovalBackend {
        var sent: CheckedContinuation<AccessRequestState, Error>?
        func updates(requestID: String) -> AsyncStream<AccessRequest> { AsyncStream { $0.finish() } }
        func cancelAuthentication(requestID: String) {}
        func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState { .unanswered }
        func deny(requestID: String, reply: String?) async throws -> AccessRequestState {
            try await withCheckedThrowingContinuation { sent = $0 }
        }
        func allowAskingAgain(requestID: String) async throws -> AccessRequestState { .unanswered }
    }
    let backend = Backend()
    let model = MacApprovalModel(request: waiting, backend: backend)
    model.replyDraft = "Use the work account."
    let denying = Task { await model.deny() }
    while backend.sent == nil { await Task.yield() }
    await model.replace(waiting)
    #expect(model.request.state == .sendingAnswer(.deny))
    backend.sent?.resume(returning: .denied(by: .mac, reply: "Use the work account.", askAgainAfter: .now.addingTimeInterval(1800)))
    await denying.value
    #expect(model.isHoldingOff)
    #expect(model.local == .denied)
}
#endif
