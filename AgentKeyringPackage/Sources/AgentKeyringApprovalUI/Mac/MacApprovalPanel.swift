// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Mac's answer to a request: a small panel under the menu bar with the
// same facts as the iPhone and Touch ID to approve. It never takes keyboard
// focus on its own, so typing elsewhere can't answer it. The reply field is
// always there: type a reply first, then Deny sends it.

#if os(macOS)
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import Observation
import OSLog
import SwiftUI

private let approvalLogger = Logger(subsystem: "com.agentkeyring.app", category: "Approval")

public func ownerAuthenticationFailure(_ error: Error, fallback: String) -> String {
    let native = error as NSError
    if native.domain == LAError.errorDomain, let code = LAError.Code(rawValue: native.code) {
        switch code {
        case .systemCancel, .appCancel, .userCancel:
            return "Approval was interrupted."
        case .companionNotAvailable, .biometryNotAvailable, .biometryNotEnrolled, .biometryNotPaired, .biometryDisconnected:
            return "Touch ID or Apple Watch isn't available. Check that one is ready."
        default: break
        }
    }
    return (error as? LocalizedError)?.errorDescription ?? fallback
}

/// Everything the Mac panel needs from the outside world.
@MainActor
public protocol MacApprovalBackend: AnyObject {
    /// The request now, then each time it changes: answered on the iPhone,
    /// withdrawn by the agent, unanswered at its deadline. Ends when it is final.
    func updates(requestID: String) -> AsyncStream<AccessRequest>
    /// Asks for Touch ID or the Watch in macOS's own dialog, then records the
    /// answer. `onAuthenticated` runs once Josh has confirmed, before the
    /// answer is sent. Returns the new state.
    func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState
    /// Closes a dialog still waiting for Touch ID or the Watch.
    func cancelAuthentication(requestID: String)
    /// A reply to an agent on another machine is signed, so it asks for Touch ID too.
    func deny(requestID: String, reply: String?) async throws -> AccessRequestState
    /// Lifts the 30-minute hold-off a denial puts on this login, so the agent may ask again.
    func allowAskingAgain(requestID: String) async throws -> AccessRequestState
}

@MainActor
@Observable
public final class MacApprovalModel {
    public private(set) var request: AccessRequest
    /// Other requests queued behind this one.
    public var moreWaiting: Int
    /// What Josh has typed for the agent. Deny sends it; empty means a plain denial.
    public var replyDraft = ""
    public private(set) var failure: String?
    /// True from the click on Approve until Josh confirms in macOS's dialog.
    public private(set) var isWaitingForTouch = false
    /// The lid is shut, so Touch ID is off. Set by whoever shows the panel.
    public var lidClosed = false
    /// The iPhone or Apple Watch also has this request, so it can be answered there.
    public var approvesElsewhere = false
    /// Called when Josh is done with the panel.
    public var close: () -> Void = {}
    /// Called once the request has an answer, from here or elsewhere.
    public var answered: () -> Void = {}

    private let backend: any MacApprovalBackend
    private var approval: Task<Void, Never>?

    public init(request: AccessRequest, moreWaiting: Int = 0, backend: any MacApprovalBackend) {
        self.request = request
        self.moreWaiting = moreWaiting
        self.backend = backend
    }

    /// Josh clicked Approve: macOS asks for Touch ID or the Watch.
    public func approve() {
        guard approval == nil, request.state.isWaitingForYou else { return }
        failure = nil
        isWaitingForTouch = true
        approval = Task {
            defer { isWaitingForTouch = false; approval = nil }
            do {
                let state = try await backend.approve(requestID: request.id) { self.isWaitingForTouch = false }
                request.state = state
                if !state.isWaitingForYou { answered() }
            } catch where Self.isCancel(error) {
            } catch {
                let native = error as NSError
                approvalLogger.error("Approval failed: domain=\(native.domain, privacy: .public) code=\(native.code, privacy: .public)")
                failure = ownerAuthenticationFailure(error, fallback: "Approval didn't finish. Nothing was shared.")
            }
        }
    }

    /// Closes macOS's dialog if it is still waiting, leaving the request unanswered.
    public func cancelApproval() {
        guard isWaitingForTouch else { return }
        backend.cancelAuthentication(requestID: request.id)
    }

    /// Cancel, Escape, clicking away or closing the panel: not an answer.
    /// Backends report those as `CancellationError` or as LocalAuthentication's own cancels.
    private static func isCancel(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let native = error as NSError
        guard native.domain == LAError.errorDomain, let code = LAError.Code(rawValue: native.code) else { return false }
        return [.userCancel, .systemCancel, .appCancel].contains(code)
    }

    /// Test only: replaces the request as an update from the backend would.
    func replace(_ latest: AccessRequest) async { request = latest }

    /// Follows the request until the panel closes. Call from `.task`.
    public func followUpdates() async {
        for await latest in backend.updates(requestID: request.id) {
            // An answer on its way stays on screen until the backend reports the outcome.
            if case .sendingAnswer = request.state, latest.state.isWaitingForYou { continue }
            request = latest
            if !latest.state.isWaitingForYou { cancelApproval(); answered() }
        }
    }

    public func deny() async {
        cancelApproval()
        let reply = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        await answer(.deny) { try await backend.deny(requestID: request.id, reply: reply.isEmpty ? nil : reply) }
    }

    public private(set) var askAgainFailure: String?
    private var deniedHere = false
    private var liftedHere = false
    /// A denial holds the login off for 30 minutes unless Josh lifts it.
    public var isHoldingOff: Bool {
        guard case .denied = request.state, !liftedHere else { return false }
        return deniedHere || request.state.isHoldingOffNewRequests(now: .now)
    }

    public func allowAskingAgain() async {
        do {
            request.state = try await backend.allowAskingAgain(requestID: request.id)
            liftedHere = true
        } catch {
            askAgainFailure = "That didn't go through. Try again."
        }
    }

    private func answer(_ choice: AnswerChoice, send: () async throws -> AccessRequestState) async {
        let previous = request.state
        request.state = .sendingAnswer(choice)
        failure = nil
        do {
            request.state = try await send()
            if !request.state.isWaitingForYou { answered() }
            failure = nil
            if choice == .deny { deniedHere = true }
        }
        catch {
            let native = error as NSError
            approvalLogger.error("Answer failed: domain=\(native.domain, privacy: .public) code=\(native.code, privacy: .public)")
            request.state = previous
            failure = (error as? LocalizedError)?.errorDescription
                ?? (choice == .approve ? "Approval didn't finish. Nothing was shared." : "The denial wasn't saved. Try again.")
        }
    }
}

/// Touch ID when the lid is open, otherwise the Watch.
public func ownerApprovalSymbol(_ context: LAContext = LAContext()) -> String {
    context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) ? "touchid" : "applewatch"
}

/// The approve button outside the request panel: a click starts macOS's own
/// Touch ID or Watch dialog, the same route the request panel uses.
public struct TouchIDButton: View {
    let action: String
    let isWaiting: Bool
    let start: () -> Void

    public init(action: String, isWaiting: Bool, start: @escaping () -> Void) {
        self.action = action
        self.isWaiting = isWaiting
        self.start = start
    }

    public var body: some View {
        Button(action: start) {
            Label(isWaiting ? "Touch the sensor to \(action)" : "Click here, then touch the sensor to \(action)",
                systemImage: ownerApprovalSymbol())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve, height: 40))
        .disabled(isWaiting)
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
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let controller = NSHostingController(rootView: content
            .background(KeyringColour.surface)
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
