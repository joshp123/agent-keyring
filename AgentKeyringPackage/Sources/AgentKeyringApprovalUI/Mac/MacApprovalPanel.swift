// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Mac's answer to a request: a small panel under the menu bar with the
// same facts as the iPhone and Touch ID to approve. It never takes keyboard
// focus on its own, so typing elsewhere can't answer it. The reply field is
// always there: type a reply first, then Deny sends it.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import AppKit
import Observation
import OSLog
import SwiftUI

private let approvalLogger = Logger(subsystem: "com.agentkeyring.app", category: "Approval")

public func ownerAuthenticationFailure(_ error: Error, fallback: String) -> String {
    switch OwnerAuthenticationFailure(error) {
    case .interrupted: "Approval was interrupted."
    case .approverUnavailable: AccessRequestCopy.approverUnavailable()
    case .other: (error as? LocalizedError)?.errorDescription ?? fallback
    }
}

/// Everything the Mac panel needs from the outside world.
@MainActor
public protocol MacApprovalBackend: AnyObject {
    /// The request now, then each time it changes: answered on the iPhone,
    /// withdrawn by the agent, unanswered at its deadline. Ends when it is final.
    func accessRequestUpdates(requestID: String) -> AsyncStream<AccessRequest>
    /// Asks for Touch ID or the Watch in macOS's own dialog, then records the
    /// answer. `onAuthenticated` runs once Josh has confirmed, before the
    /// answer is sent. Returns the new state.
    func approveAccessRequest(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState
    /// Closes a dialog still waiting for Touch ID or the Watch.
    func cancelAuthentication(requestID: String)
    /// A reply to an agent on another machine is signed, so it asks for Touch ID too.
    func denyAccessRequest(requestID: String, reply: String?) async throws -> AccessRequestState
    /// Lifts the 30-minute hold-off a denial puts on this login, so the agent may ask again.
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState
}

/// What Josh is doing in this panel. The request's own state is the
/// backend's alone; this only says what he has started here and how it went.
public enum ApprovalPanelLocalAction: Equatable, Sendable {
    case idle
    /// macOS's dialog is waiting for Touch ID or the Watch.
    case authenticating
    /// His answer is on its way.
    case sending(AnswerChoice)
    /// He denied it here, so the password is held off for 30 minutes.
    case denied
    /// He lifted the hold-off here ("Let it ask again").
    case lifted
    /// What he started didn't go through; he can try again.
    case failed(String)
}

@MainActor
@Observable
public final class MacApprovalModel {

    /// The request as the backend last reported it.
    private var reported: AccessRequest
    public private(set) var local = ApprovalPanelLocalAction.idle
    /// Other requests queued behind this one.
    public var moreWaiting: Int
    /// What Josh has typed for the agent. Deny sends it; empty means a plain denial.
    public var replyDraft = ""
    /// The reply box is open. Kept here, not in the view, so focusing the panel again keeps it and its draft.
    public var isReplying = false
    /// Why this Mac can't approve now: the lid is shut, or the Touch ID keyboard is gone. Nil when it can.
    public var cannotApproveHere: MacApproverState? {
        let state = stateInRender ?? MacApprover.shared.state
        return state == .lidClosed || state == .touchIDMissing ? state : nil
    }
    /// Renders draw any state, and any approver, on any Mac.
    var stateInRender: MacApproverState?
    var approverInRender: MacApproverKind?
    /// What approves on this Mac now, for the green button's words.
    var approver: MacApproverKind { approverInRender ?? MacApprover.shared.approver }
    /// The iPhone or Apple Watch also has this request, so it can be answered there.
    public var approvesElsewhere = false
    /// Called when Josh is done with the panel.
    public var close: () -> Void = {}
    /// Called once the request has an answer, from here or elsewhere.
    public var answered: () -> Void = {}

    private let backend: any MacApprovalBackend

    public init(request: AccessRequest, moreWaiting: Int = 0, backend: any MacApprovalBackend) {
        self.reported = request
        self.moreWaiting = moreWaiting
        self.backend = backend
    }

    /// The request as the panel shows it: the backend's, with his answer shown as sending until the backend reports it.
    public var request: AccessRequest {
        guard case let .sending(choice) = local, reported.state.isWaitingForYou else { return reported }
        var shown = reported
        shown.state = .sendingAnswer(choice)
        return shown
    }

    /// From the click on Approve until Josh confirms in macOS's dialog.
    public var isWaitingForTouch: Bool { local == .authenticating }

    public var failure: String? {
        if case let .failed(message) = local { message } else { nil }
    }

    private var canStart: Bool {
        switch local {
        case .idle, .failed: true
        case .authenticating, .sending, .denied, .lifted: false
        }
    }

    /// Josh clicked Approve: macOS asks for Touch ID or the Watch.
    public func approveAccessRequest() {
        guard canStart, reported.state.isWaitingForYou else { return }
        local = .authenticating
        Task {
            do {
                let state = try await backend.approveAccessRequest(requestID: reported.id) { self.local = .sending(.approve) }
                reported.state = state
                endApproval(.idle)
                if !state.isWaitingForYou { answered() }
            } catch where OwnerAuthenticationFailure.isCancel(error) {
                endApproval(.idle)
            } catch {
                let native = error as NSError
                approvalLogger.error("Approval failed: domain=\(native.domain, privacy: .public) code=\(native.code, privacy: .public)")
                endApproval(.failed(ownerAuthenticationFailure(error, fallback: "Approval didn't finish. Nothing was shared.")))
            }
        }
    }

    /// A Deny clicked while macOS's dialog was up has taken over; the dialog's end leaves it alone.
    private func endApproval(_ next: ApprovalPanelLocalAction) {
        if local == .authenticating || local == .sending(.approve) { local = next }
    }

    /// Closes macOS's dialog if it is still waiting, leaving the request unanswered.
    public func cancelApproval() {
        guard local == .authenticating else { return }
        backend.cancelAuthentication(requestID: reported.id)
    }

    /// Test only: an update from the backend.
    func replace(_ latest: AccessRequest) async { reported = latest }

    /// Follows the request until the panel closes. Call from `.task`.
    public func followUpdates() async {
        for await latest in backend.accessRequestUpdates(requestID: reported.id) {
            reported = latest
            if !latest.state.isWaitingForYou { cancelApproval(); answered() }
        }
    }

    public func denyAccessRequest() async {
        cancelApproval()
        let reply = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard local == .idle || local == .authenticating || failure != nil else { return }
        local = .sending(.deny)
        do {
            reported.state = try await backend.denyAccessRequest(requestID: reported.id, reply: reply.isEmpty ? nil : reply)
            local = .denied
            if !reported.state.isWaitingForYou { answered() }
        } catch {
            let native = error as NSError
            approvalLogger.error("Denial failed: domain=\(native.domain, privacy: .public) code=\(native.code, privacy: .public)")
            local = .failed((error as? LocalizedError)?.errorDescription ?? "The denial wasn't saved. Try again.")
        }
    }

    /// A denial holds the login off for 30 minutes unless Josh lifts it.
    public var isHoldingOff: Bool {
        guard case .denied = reported.state, local != .lifted else { return false }
        return local == .denied || reported.state.isHoldingOffNewRequests(now: .now)
    }

    public func allowAskingAgain() async {
        do {
            reported.state = try await backend.allowAskingAgain(requestID: reported.id)
            local = .lifted
        } catch {
            local = .failed("That didn't go through. Try again.")
        }
    }
}

/// Hosts the panel beside the window Josh is working in (see
/// ApprovalPanelPlacement). Non-activating: the app Josh is typing in keeps focus until
/// he clicks the panel.
@MainActor
public final class MacApprovalPanelController {
    private var panel: NSPanel?

    public init() {}

    private var requestHost: RequestPanelHost?

    /// The request on screen now, if any.
    public var shownRequestID: String? { requestHost?.model.request.id }

    /// Brings the request already on screen forward, keeping its reply draft; `openReply` opens its reply box.
    public func focus(openReply: Bool) {
        requestHost?.focus(openReply: openReply)
    }

    public func show(_ model: MacApprovalModel) {
        close()
        let host = RequestPanelHost(model: model)
        requestHost = host
        model.close = { [weak self] in self?.close() }
        model.answered = { [weak host] in host?.panel.giveKeyBack() }
        host.show()
    }

    func showPanel(_ content: some View) {
        close()
        MacApprover.shared.refresh()
        let panel = KeyringPanel.floating(content)
        panel.setFrame(ApprovalPanelPlacement.frame(panel: panel.frame.size,
            focusedWindow: ApprovalPanelPlacement.focusedWindow(), pointer: NSEvent.mouseLocation,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)), display: false)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    public func close() {
        panel?.orderOut(nil)
        if let requestHost {
            requestHost.panel.giveKeyBack()
            requestHost.panel.orderOut(nil)
            self.requestHost = nil
        }
    }
}

/// Becomes key only when Josh clicks into its reply field, never on its own.
final class KeyringPanel: NSPanel {
    /// A borderless, rounded, opaque panel above other windows that
    /// grows and shrinks with its SwiftUI content. Not yet on screen.
    static func floating(_ content: some View) -> KeyringPanel {
        // The same ground and corner as the request card's panel.
        let shape = RoundedRectangle(cornerRadius: KeyringRadius.panel, style: .continuous)
        let controller = NSHostingController(rootView: content
            .background(KeyringPalette.surface)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.separator, lineWidth: 0.5)))
        controller.sizingOptions = [.preferredContentSize]
        let panel = KeyringPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.contentViewController = controller
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Any click in the panel is Josh's own, so it may take the keyboard;
        // becomeKey decides where the keys go.
        panel.becomesKeyOnlyIfNeeded = false
        panel.setContentSize(controller.view.fittingSize)
        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Only a click in the reply box puts the caret there, and that first
    /// click is enough: a click on a panel that isn't key would otherwise
    /// only make it key, and the box would miss the typing. Any other way of
    /// becoming key leaves no field focused, so typing meant for another app
    /// goes nowhere.
    override func becomeKey() {
        super.becomeKey()
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === self,
            let content = contentView,
            let field = Self.textInputs(in: content).first(where: {
                $0.convert($0.bounds, to: nil).contains(event.locationInWindow)
            })
        else {
            makeFirstResponder(nil)
            return
        }
        makeFirstResponder(field)
    }

    /// SwiftUI's hosting view answers hit tests itself, so the text box is
    /// found by where it is drawn, not by hitTest.
    private static func textInputs(in view: NSView) -> [NSView] {
        (view is NSTextField || view is NSTextView ? [view] : []) + view.subviews.flatMap(textInputs)
    }

}
#endif
