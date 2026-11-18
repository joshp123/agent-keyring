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
    var request = AccessRequest(id: "r", login: RequestedLogin(site: "example.com", account: "josh@example.com"),
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
