// Written by AI on 2026.11.18 by model claude opus 5.5, from the design in
// the Paper file "Agent Keyring", page "The request", board "On the Mac".
//
// The request beside the pointer. It never takes the keyboard when it
// appears. Approve asks for Touch ID, the Watch or the Mac password in macOS's own dialog, which
// comes only after Josh's click and gives the keyboard back when it closes.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import AppKit
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
    var onDismiss: (() -> Void)? = nil

    /// The card's width with the panel's tinted canvas margin round it.
    static let width: CGFloat = 400

    private var request: AccessRequest { model.request }
    private var agent: String { request.agent.name }
    private var isPractice: Bool { request.access == .practice }

    init(model: MacApprovalModel, onDismiss: (() -> Void)? = nil) {
        self.model = model
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            switch request.state {
            case .waitingForYou, .sendingAnswer: asking
            default: answered
            }
        }
        .padding(KeyringSpace.s4)
        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: KeyringRadius.card, style: .continuous).strokeBorder(KeyringPalette.line))
        .padding(KeyringSpace.s3)
        .frame(width: Self.width)
        .background(KeyringPalette.canvas, in: .rect(cornerRadius: KeyringRadius.panel, style: .continuous))
        .task { await model.followUpdates() }
        .task {
            guard !ReviewRendering.isOn else { return }
            while !Task.isCancelled {
                MacApprover.shared.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
        var isSetUp: Bool
    }

    private var words: Words {
        switch request.access {
        case .login:
            Words(lead: AccessRequestCopy.wants(request.agent), detail: request.login.account, reason: request.agentReason, replies: true,
                  replyPrompt: AccessRequestCopy.replyPlaceholder(agent), footer: nil, isSetUp: false)
        case .practice:
            Words(lead: FirstRunCopy.practiceWants, detail: request.login.account, reason: request.agentReason, replies: true,
                  replyPrompt: FirstRunCopy.practiceReplyPrompt, footer: FirstRunCopy.practiceFooter, isSetUp: false)
        case let .setUp(lead, detail, footer, _, replies, _):
            Words(lead: lead, explanation: detail.isEmpty ? nil : detail, replies: replies, replyPrompt: SetupCopy.denyNotePrompt,
                  footer: footer.isEmpty ? nil : footer, isSetUp: true)
        }
    }

    private var sending: AnswerChoice? {
        if case let .sendingAnswer(choice) = request.state { return choice }
        return nil
    }

    @ViewBuilder private var asking: some View {
        let words = words
        VStack(spacing: KeyringSpace.s3) {
            if words.isSetUp {
                VStack(alignment: .leading, spacing: KeyringSpace.s4) {
                    brandBar
                    HStack(alignment: .top, spacing: KeyringSpace.s3) {
                        Image(systemName: request.login.site.localizedCaseInsensitiveContains("iphone") ? "iphone" : "desktopcomputer")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(KeyringPalette.brand)
                            .frame(width: 36, height: 36)
                            .background(KeyringPalette.brandTint, in: .rect(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            KeyringText(words.lead, as: .heading)
                            if let explanation = words.explanation {
                                KeyringText(explanation, as: .meta)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(spacing: KeyringSpace.s2) {
                        KeyringButton(.plain(sending == .deny ? AccessRequestCopy.denying : "Don’t Add", isEnabled: sending == nil) {
                            Task { await model.denyAccessRequest() }
                        })
                        if model.cannotApproveHere == nil {
                            KeyringButton(approve)
                        } else {
                            KeyringText(
                                model.approvesElsewhere ? AccessRequestCopy.approveElsewhere
                                    : model.cannotApproveHere == .touchIDMissing ? AccessRequestCopy.connectTouchID : AccessRequestCopy.openTheLid,
                                as: .meta
                            )
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .environment(\.keyringButtonsFill, true)
                    .environment(\.keyringButtonTall, true)
                }
            } else {
                KeyringUnifiedApprovalCard(
                    site: request.login.site,
                    account: words.detail?.isEmpty == false ? words.detail : nil,
                    agent: isPractice ? "Practice" : request.agent.name,
                    machine: isPractice ? "" : (request.agent.isLocal ? "This Mac" : request.agent.machine),
                    reason: words.reason.flatMap { $0.isEmpty ? nil : $0 },
                    footer: words.footer,
                    showBrandBar: true,
                    onDismiss: onDismiss ?? {},
                    compact: false,
                    approve: model.cannotApproveHere == nil ? approve : nil,
                    inPlaceOfApprove: model.approvesElsewhere ? AccessRequestCopy.approveElsewhere
                        : model.cannotApproveHere == .touchIDMissing ? AccessRequestCopy.connectTouchID : AccessRequestCopy.openTheLid,
                    deny: .deny(sending == .deny ? AccessRequestCopy.denying : AccessRequestCopy.deny, isEnabled: sending == nil) {
                        Task { await model.denyAccessRequest() }
                    },
                    denyAndReply: words.replies ? .denySecondary(AccessRequestCopy.denyAndReply, isEnabled: sending == nil) {
                        model.isReplying = true
                    } : nil,
                    replyDraft: model.isReplying ? $model.replyDraft : nil,
                    replyPrompt: words.replyPrompt,
                    onCancelReply: {
                        model.replyDraft = ""
                        model.isReplying = false
                    },
                    onSendReply: {
                        Task { await model.denyAccessRequest() }
                    },
                    sendReplyTitle: MenuBarCopy.sendReply,
                    busy: sending != nil
                ) {
                    SiteIconView(host: request.login.site, size: 30)
                }
            }
            if let failure = model.failure { KeyringStatusLine(.problem(failure)) }
        }
    }

    private var brandBar: some View {
        HStack(spacing: KeyringSpace.s2) {
            KeyringKeyholeMark(size: 16, colour: KeyringPalette.brand)
            KeyringText(SetupCopy.appName, as: .meta, colour: KeyringPalette.ink)
            if model.moreWaiting > 0 {
                KeyringText(AccessRequestCopy.moreWaiting(model.moreWaiting), as: .caption, colour: KeyringPalette.brand)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(KeyringPalette.brandTint, in: Capsule(style: .circular))
            }
            Spacer(minLength: 0)
            Button(action: onDismiss ?? {}) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KeyringPalette.ink2)
                    .frame(width: 22, height: 22)
                    .background(KeyringPalette.fill, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    /// One green button, the card's full width. Clicking it opens macOS's
    /// dialog for Touch ID, the Watch or the Mac password; while that is up,
    /// it says what to do. With the lid shut or the Touch ID keyboard gone
    /// there is none: the card says why in its place.
    private var approve: KeyringAction {
        if sending == .approve { return .approve(AccessRequestCopy.approving, isEnabled: false) {} }
        let waiting = model.isWaitingForTouch
        let title = AccessRequestCopy.approveTitle(model.approver, waiting: waiting)
        let symbol = waiting ? nil : AccessRequestCopy.approveSymbol(model.approver)
        return .approve(title ?? AccessRequestCopy.noApprover, symbol: symbol, isEnabled: !waiting && sending == nil && title != nil) { model.approveAccessRequest() }
    }

    @ViewBuilder private var answered: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s3) {
            brandBar
            if !words.isSetUp {
                HStack(alignment: .center, spacing: KeyringSpace.s2 + 2) {
                    SiteIconView(host: request.login.site, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        KeyringText(request.login.site, as: .heading, fit: .siteName)
                        if !request.login.account.isEmpty {
                            KeyringText(request.login.account, as: .meta, fit: .siteName)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 1) {
                        KeyringText(isPractice ? "Practice" : request.agent.name, as: .meta, colour: KeyringPalette.ink)
                        if !isPractice {
                            KeyringText(request.agent.isLocal ? "This Mac" : request.agent.machine, as: .caption, colour: KeyringPalette.ink2)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: true)
                }
            }
            switch request.state {
            case .approved:
                KeyringConfirmation(outcomeTitle, detail: outcomeDetail)
            case .denied, .blockedByRule:
                KeyringConfirmation(outcomeTitle, detail: outcomeDetail, tone: .denied)
            default:
                KeyringHint(symbol: "clock", title: outcomeTitle, outcomeDetail ?? AccessRequestCopy.outcomeWord(request.state), tone: .plain)
            }
        }
    }

    private var setUp: (denied: String, approved: String)? {
        if case let .setUp(_, _, _, denied, _, approved) = request.access { return (denied, approved) }
        return nil
    }

    private var outcomeTitle: String {
        switch request.state {
        case .approved where setUp != nil: SetupCopy.added(request.login.site)
        case let .approved(surface, _):
            switch surface {
            case .iPhone: AccessRequestCopy.approvedOnPhone
            case .watch: AccessRequestCopy.approvedOnWatch
            default: AccessRequestCopy.approved
            }
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

    /// `waiting`: as while macOS's dialog is open. `lidClosed`, `touchIDMissing` and
    /// `approvesElsewhere` as `ApprovalPresenter` sets them. `approver`: Touch ID unless given.
    @MainActor public static func panel(_ request: AccessRequest, reply: String = "", replying: Bool = false, waiting: Bool = false,
        lidClosed: Bool = false, touchIDMissing: Bool = false, approvesElsewhere: Bool = false,
        approver: MacApproverKind = .touchID) -> some View {
        isOn = true
        var state = SandboxState.builtIn()
        state.thisDeviceID = "macbook"
        state.requests = [SandboxRequest(request)]
        // While macOS's dialog would be up, Touch ID never answers.
        let world = SandboxWorld(state, effects: SandboxEffectRunner([.ownerApproval: .delayed(.seconds(3600))]))
        let model = MacApprovalModel(request: request, backend: SandboxPanelBackend(world))
        model.replyDraft = reply
        model.isReplying = replying || !reply.isEmpty
        model.stateInRender = lidClosed ? .lidClosed : touchIDMissing ? .touchIDMissing : .ready
        model.approverInRender = approver
        model.approvesElsewhere = approvesElsewhere
        if waiting { model.approveAccessRequest() }
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

    nonisolated static let authenticationDialogBundleID = "com.apple.LocalAuthentication.UIAgent"

    /// Only the Touch ID or Apple Watch dialog is closed when focus moves away; the password dialog is not.
    nonisolated static func cancelsWhenFocusMoves(_ mode: MacApprovalMode) -> Bool { mode == .biometricOrCompanion }

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

    static func textInputs(in view: NSView) -> [NSView] {
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
    let model: MacApprovalModel
    private let hosting: FirstClickHostingView

    init(model: MacApprovalModel) {
        self.model = model
        hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))
        // Only report a size; never let SwiftUI resize the window itself.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.rootView = AnyView(MacApprovalPanelView(model: model)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                self?.fit(height: height)
            })
        panel.contentView = hosting
        // macOS's Touch ID dialog stops listening once another app is in
        // front, but stays on screen looking ready; close it and offer
        // Approve again. The password dialog keeps listening, and Josh may
        // click elsewhere while he types, so it is left alone.
        panel.onOtherAppActivated = { [weak model] in
            guard let model, RequestPanel.cancelsWhenFocusMoves(MacApprover.shared.mode) else { return }
            model.cancelApproval()
        }
        panel.onClickElsewhere = { [weak model] point in
            guard let model, model.isWaitingForTouch, RequestPanel.cancelsWhenFocusMoves(MacApprover.shared.mode),
                !RequestPanel.isOnAuthenticationDialog(point) else { return }
            model.cancelApproval()
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

    /// Brings the shown panel forward without rebuilding it, and with `openReply` opens its reply box and
    /// puts the caret there: Josh asked for it from Activity or the menu bar, so the panel may take the keyboard.
    func focus(openReply: Bool) {
        panel.orderFrontRegardless()
        guard openReply else { return }
        model.isReplying = true
        // The box exists once SwiftUI has drawn the change.
        DispatchQueue.main.async { [panel, hosting] in
            hosting.layoutSubtreeIfNeeded()
            panel.makeKey()
            guard let field = RequestPanel.textInputs(in: hosting).first else { return }
            panel.makeFirstResponder(field)
        }
    }

    func show() {
        MacApprover.shared.refresh()
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
