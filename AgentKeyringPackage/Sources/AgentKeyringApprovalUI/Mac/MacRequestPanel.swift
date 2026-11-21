// Written by AI on 2026.11.18 by model claude opus 5.5, from the design in
// the Paper file "Agent Keyring", page "The request", board "On the Mac".
//
// The request beside the pointer. It never takes the keyboard when it
// appears. Approve asks for Touch ID or the Watch in macOS's own dialog, which
// comes only after Josh's click and gives the keyboard back when it closes.

#if os(macOS)
import AgentKeyringDesign
import AppKit
import LocalAuthentication
import SwiftUI

/// The design's tokens, light and dark, for the menu bar window and the main
/// window, which do not use the page parts yet.
enum RequestToken {
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let ink = Color(light: 0x0B0B0C, dark: 0xFFFFFF)
    static let ink2 = Color(light: 0x5F5F67, dark: 0xA6A6AE)
    static let fill = Color(light: 0xEEEEF1, dark: 0x2E2E31)
    static let line = Color(light: 0xE1E1E6, dark: 0x3A3A3D)
    static let approve = Color(light: 0x17853F, dark: 0x23A455)
    static let deny = Color(light: 0xD5302A, dark: 0xE5453D)
    /// Links, such as "Agent Keyring isn't in the list?".
    static let brand = Color(light: 0x1447E6, dark: 0x5B8CFF)
    /// A finished request that was neither approved nor denied, in lists.
    static let idle = Color(light: 0xB4B4BC, dark: 0x6E6E76)
    static let onAnswer = Color.white
}

/// The card beside the window, built from the parts: an agent's request, the
/// practice request, or a device or computer asking to join (Paper page
/// "Agent Keyring (Holistic)", board 2). Rebuilt on 2026.11.21 by model claude opus 5.5.
struct MacApprovalPanelView: View {
    @Bindable var model: MacApprovalModel

    /// The card's width with the panel's margin round it.
    static let width = KeyringSize.macCard + 2 * KeyringSpace.s5

    private var request: AccessRequest { model.request }
    private var agent: String { request.agent.name }
    private var isPractice: Bool { request.access == .practice }

    var body: some View {
        Group {
            switch request.state {
            case .waitingForYou, .sendingAnswer: asking
            default: answered
            }
        }
        .padding(KeyringSpace.s5)
        .frame(width: Self.width)
        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.panel, style: .continuous))
        .task { await model.followUpdates() }
        .onDisappear { model.cancelApproval() }
    }

    private struct Words {
        var lead: String
        var detail: String?
        var reason: String?
        var explanation: String?
        var replies: Bool
        var replyPrompt: String
        var footer: String?
    }

    private var words: Words {
        switch request.access {
        case .login:
            Words(lead: AccessRequestCopy.wants(request.agent), detail: request.login.account, reason: request.agentReason, replies: true,
                  replyPrompt: AccessRequestCopy.replyPlaceholder(agent), footer: AccessRequestCopy.footer(agent))
        case .practice:
            Words(lead: FirstRunCopy.practiceWants, detail: request.login.account, reason: request.agentReason, replies: true,
                  replyPrompt: FirstRunCopy.practiceReplyPrompt, footer: FirstRunCopy.practiceFooter)
        case let .setUp(lead, detail, footer, _, replies, _):
            Words(lead: lead, explanation: detail.isEmpty ? nil : detail, replies: replies, replyPrompt: SetupCopy.denyNotePrompt,
                  footer: footer.isEmpty ? nil : footer)
        }
    }

    private var sending: AnswerChoice? {
        if case let .sendingAnswer(choice) = request.state { return choice }
        return nil
    }

    private var asking: some View {
        let words = words
        return VStack(spacing: KeyringSpace.s3) {
            KeyringApprovalCard(lead: words.lead, subject: request.login.site, detail: words.detail,
                                reason: words.reason.flatMap { $0.isEmpty ? nil : $0 }, explanation: words.explanation,
                                reply: words.replies ? $model.replyDraft : nil, replyPrompt: words.replyPrompt,
                                approve: model.lidClosed ? nil : approve,
                                inPlaceOfApprove: model.approvesElsewhere ? AccessRequestCopy.approveElsewhere : AccessRequestCopy.openTheLid,
                                deny: KeyringAction(sending == .deny ? AccessRequestCopy.denying : AccessRequestCopy.deny,
                                                    words.replies ? .deny : .denyLink, isEnabled: sending == nil) {
                                    Task { await model.deny() }
                                },
                                footer: words.footer, header: SetupCopy.appName)
            if let failure = model.failure { KeyringStatusLine(.problem(failure)) }
        }
    }

    private enum Approver { case touchID, watch, none }

    private var approver: Approver {
        let context = LAContext()
        if canAsk(context, .deviceOwnerAuthenticationWithBiometrics) { return .touchID }
        return canAsk(context, .deviceOwnerAuthenticationWithCompanion) ? .watch : .none
    }

    /// One green button, the card's full width. Clicking it opens macOS's
    /// Touch ID or Apple Watch dialog; while that is up, it says what to do.
    /// With the lid shut there is none: the card says why in its place.
    private var approve: KeyringAction {
        if sending == .approve { return .approve(AccessRequestCopy.approving, isEnabled: false) {} }
        let waiting = model.isWaitingForTouch
        let title = switch approver {
        case .touchID: waiting ? AccessRequestCopy.useTouchID : AccessRequestCopy.clickForTouchID
        case .watch: waiting ? AccessRequestCopy.useWatch : AccessRequestCopy.clickForWatch
        case .none: AccessRequestCopy.noApprover
        }
        return .approve(title, isEnabled: !waiting && sending == nil && approver != .none) { model.approve() }
    }

    @ViewBuilder private var answered: some View {
        switch request.state {
        case .approved:
            KeyringConfirmation(outcomeTitle, detail: outcomeDetail)
        case .denied, .blockedByRule:
            KeyringConfirmation(outcomeTitle, detail: outcomeDetail, tone: .denied)
        default:
            KeyringHint(symbol: "clock", title: outcomeTitle, outcomeDetail ?? AccessRequestCopy.outcomeWord(request.state), tone: .plain)
        }
    }

    private var setUp: (denied: String, approved: String)? {
        if case let .setUp(_, _, _, denied, _, approved) = request.access { return (denied, approved) }
        return nil
    }

    private var outcomeTitle: String {
        switch request.state {
        case .approved where setUp != nil: SetupCopy.added(request.login.site)
        case let .approved(surface, _): surface == .iPhone ? AccessRequestCopy.approvedOnPhone : AccessRequestCopy.approved
        case .denied: AccessRequestCopy.denied
        case .unanswered: AccessRequestCopy.noAnswer
        case .cancelled: AccessRequestCopy.cancelled
        default: AccessRequestCopy.outcomeWord(request.state)
        }
    }

    private var outcomeDetail: String? {
        switch request.state {
        case .approved where isPractice: FirstRunCopy.practiceApproved
        case .approved where setUp != nil: setUp.flatMap { $0.approved.isEmpty ? nil : $0.approved }
        case let .approved(_, until): AccessRequestCopy.canUseUntil(agent, AccessRequestCopy.clock(until))
        case .denied where setUp != nil: setUp?.denied
        case let .denied(_, reply?, _): AccessRequestCopy.youTold(isPractice ? AccessRequestCopy.theAgent : agent, reply)
        case .denied where isPractice: nil
        case .denied: AccessRequestCopy.wasTold(agent)
        case .unanswered: AccessRequestCopy.ended(agent)
        case .cancelled: AccessRequestCopy.stopped(agent)
        default: nil
        }
    }
}

/// Draws the panel off screen for a design check, with no Touch ID.
public enum ReviewRendering {
    nonisolated(unsafe) public static var isOn = false

    private final class Backend: MacApprovalBackend {
        let request: AccessRequest
        init(_ request: AccessRequest) { self.request = request }
        func updates(requestID: String) -> AsyncStream<AccessRequest> { AsyncStream { $0.finish() } }
        func cancelAuthentication(requestID: String) {}
        func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState {
            try await Task.sleep(for: .seconds(3600)); return request.state
        }
        func deny(requestID: String, reply: String?) async throws -> AccessRequestState { request.state }
        func allowAskingAgain(requestID: String) async throws -> AccessRequestState { request.state }
    }

    /// `waiting`: as while macOS's dialog is open. `lidClosed` and
    /// `approvesElsewhere` as `ApprovalPresenter` sets them.
    @MainActor public static func panel(_ request: AccessRequest, reply: String = "", waiting: Bool = false,
        lidClosed: Bool = false, approvesElsewhere: Bool = false) -> some View {
        isOn = true
        let model = MacApprovalModel(request: request, backend: Backend(request))
        model.replyDraft = reply
        model.lidClosedInRender = lidClosed
        model.approvesElsewhere = approvesElsewhere
        if waiting { model.approve() }
        return MacApprovalPanelView(model: model)
    }
}

/// A borderless panel beside the pointer. Showing it never activates Agent
/// Keyring, and neither does a click in it. Clicks in its first half second
/// are ignored, so a click already on its way cannot land on Deny.
final class RequestPanel: NSPanel {
    private var shownAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    /// Another app came to the front, other than macOS's Touch ID dialog.
    var onOtherAppActivated: () -> Void = {}
    /// A click went to another app, at this point on screen (AppKit coordinates).
    var onClickElsewhere: (NSPoint) -> Void = { _ in }
    private var clickMonitor: Any?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: MacApprovalPanelView.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier != Self.authenticationDialogBundleID else { return }
            MainActor.assumeIsolated { self?.onOtherAppActivated() }
        })
        // A click back into the app that is already in front activates nothing,
        // so clicks that go to other apps are watched too. Needs no permission.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.onClickElsewhere(NSEvent.mouseLocation) }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static let authenticationDialogBundleID = "com.apple.LocalAuthentication.UIAgent"

    /// Whether a point (AppKit coordinates) is on macOS's Touch ID dialog.
    static func isOnAuthenticationDialog(_ point: NSPoint) -> Bool {
        let owners = Set(NSRunningApplication.runningApplications(withBundleIdentifier: authenticationDialogBundleID).map(\.processIdentifier))
        guard !owners.isEmpty, let top = NSScreen.screens.first?.frame.maxY,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let flipped = CGPoint(x: point.x, y: top - point.y)
        return windows.contains { window in
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owners.contains(owner),
                let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(flipped)
        }
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        clickMonitor.map(NSEvent.removeMonitor)
        clickMonitor = nil
    }

    func show(at frame: NSRect) {
        setFrame(frame, display: true)
        shownAt = Date()
        orderFrontRegardless()
    }

    /// Set while the rest of an ignored click arrives: its release must be
    /// dropped too, or the button under it is left half pressed.
    private var droppingClick = false

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            droppingClick = Date().timeIntervalSince(shownAt) < 0.5
            if droppingClick { return }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if droppingClick { return }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if droppingClick { droppingClick = false; return }
        default: break
        }
        super.sendEvent(event)
    }

    /// Only a click in the reply box puts the caret there.
    override func becomeKey() {
        super.becomeKey()
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === self,
            let content = contentView,
            let field = Self.textInputs(in: content).first(where: { $0.convert($0.bounds, to: nil).contains(event.locationInWindow) })
        else { makeFirstResponder(nil); return }
        makeFirstResponder(field)
    }

    private static func textInputs(in view: NSView) -> [NSView] {
        (view is NSTextField || view is NSTextView ? [view] : []) + view.subviews.flatMap(textInputs)
    }

    /// After a reply was typed here, the keys go back to the app in front.
    func giveKeyBack() {
        guard isKeyWindow else { return }
        resignKey()
        NSWorkspace.shared.frontmostApplication?.activate()
    }

    /// The design's spot: just above and to the right of the pointer, on the
    /// pointer's screen, flipping to below or left where it would not fit.
    static func frame(size: CGSize, pointer: CGPoint, visibleFrames: [CGRect]) -> CGRect {
        let gap: CGFloat = 28, margin: CGFloat = 12
        let screen = visibleFrames.first { $0.contains(pointer) } ?? visibleFrames.first ?? .zero
        var x = pointer.x - 24
        var y = pointer.y + gap
        if y + size.height > screen.maxY - margin { y = pointer.y - gap - size.height }
        if x + size.width > screen.maxX - margin { x = pointer.x + 24 - size.width }
        x = min(max(x, screen.minX + margin), screen.maxX - margin - size.width)
        y = min(max(y, screen.minY + margin), screen.maxY - margin - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Beside Agent Keyring's own window (first run's, which explains the
    /// request, or the main window), never over it: on its right if there is
    /// room, else on its left, else the window moves aside to make room.
    /// Returns the panel's frame and the window's, which may have moved.
    static func frame(size: CGSize, beside window: CGRect, visibleFrames: [CGRect]) -> (panel: CGRect, window: CGRect) {
        let gap: CGFloat = 16, margin: CGFloat = 12
        let screen = visibleFrames.first { $0.contains(CGPoint(x: window.midX, y: window.midY)) } ?? visibleFrames.first ?? .zero
        var window = window
        let room = { (x: CGFloat) in x >= screen.minX + margin && x + size.width <= screen.maxX - margin }
        var x = window.maxX + gap
        if !room(x) { x = window.minX - gap - size.width }
        if !room(x) {
            // Neither side has room: the window moves to the left edge, the panel goes beside it.
            window.origin.x = max(screen.minX + margin, min(window.minX, screen.maxX - margin - size.width - gap - window.width))
            x = min(window.maxX + gap, screen.maxX - margin - size.width)
        }
        let y = min(max(window.maxY - size.height, screen.minY + margin), screen.maxY - margin - size.height)
        return (CGRect(x: x, y: y, width: size.width, height: size.height), window)
    }
}

/// The panel is never key until clicked, so the first click must reach the
/// button under it, not only make the panel key.
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds the request panel's view and keeps its height fitted to the content
/// without the window and SwiftUI resizing each other in a loop.
@MainActor
final class RequestPanelHost {
    let panel = RequestPanel()
    private let hosting: FirstClickHostingView

    init(model: MacApprovalModel) {
        hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))
        // Only report a size; never let SwiftUI resize the window itself.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.rootView = AnyView(MacApprovalPanelView(model: model)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                self?.fit(height: height)
            })
        panel.contentView = hosting
        // macOS's dialog stops listening once another app is in front, but
        // stays on screen looking ready; close it and offer Approve again.
        panel.onOtherAppActivated = { [weak model] in model?.cancelApproval() }
        panel.onClickElsewhere = { [weak model] point in
            guard !RequestPanel.isOnAuthenticationDialog(point) else { return }
            model?.cancelApproval()
        }
    }

    /// Resizes once per real change of height, keeping the top edge in place.
    private func fit(height: CGFloat) {
        let height = height.rounded(.up)
        guard height > 0, abs(panel.frame.height - height) >= 1 else { return }
        DispatchQueue.main.async { [panel] in
            var frame = panel.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true)
        }
    }

    func show() {
        hosting.layoutSubtreeIfNeeded()
        let size = CGSize(width: MacApprovalPanelView.width, height: max(hosting.intrinsicContentSize.height, 100).rounded(.up))
        let screens = NSScreen.screens.map(\.visibleFrame)
        // Agent Keyring's own window on screen (first run, or the main window) is where he is looking.
        if let own = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.level == .normal && $0.frame.width > 300 }) {
            let placed = RequestPanel.frame(size: size, beside: own.frame, visibleFrames: screens)
            if placed.window != own.frame { own.setFrame(placed.window, display: true, animate: true) }
            panel.show(at: placed.panel)
        } else {
            panel.show(at: RequestPanel.frame(size: size, pointer: NSEvent.mouseLocation, visibleFrames: screens))
        }
    }
}
#endif
