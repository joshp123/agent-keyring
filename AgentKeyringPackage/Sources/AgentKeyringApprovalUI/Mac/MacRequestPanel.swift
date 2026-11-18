// Written by AI on 2026.11.18 by model claude opus 5.5, from the design in
// the Paper file "Agent Keyring", page "The request", board "On the Mac".
//
// The request beside the pointer. It never takes the keyboard when it
// appears. Apple's Touch ID control only runs while Agent Keyring is the
// active app, so a click on the request makes it active; when the request is
// answered, the app Josh was using gets the keyboard back.

#if os(macOS)
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// The design's tokens, light and dark.
enum RequestToken {
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let ink = Color(light: 0x0B0B0C, dark: 0xFFFFFF)
    static let ink2 = Color(light: 0x5F5F67, dark: 0xA6A6AE)
    static let fill = Color(light: 0xEEEEF1, dark: 0x2E2E31)
    static let line = Color(light: 0xE1E1E6, dark: 0x3A3A3D)
    static let approve = Color(light: 0x17853F, dark: 0x23A455)
    static let deny = Color(light: 0xD5302A, dark: 0xE5453D)
    static let onAnswer = Color.white
    static let width: CGFloat = 420
    static let radius: CGFloat = 18
}

/// Whether Agent Keyring is the active app, so Touch ID can run. Observed,
/// so a change redraws the words without rebuilding Apple's control.
@MainActor @Observable
final class PanelActivity {
    var isActive = RequestPanel.isFrontmost
}

struct MacApprovalPanelView: View {
    @Bindable var model: MacApprovalModel
    let activity: PanelActivity
    private var isActive: Bool { activity.isActive }

    private var request: AccessRequest { model.request }
    private var agent: String { request.agent.name }

    public var body: some View {
        Group {
            switch request.state {
            case .waitingForYou, .sendingAnswer: asking
            default: answered
            }
        }
        .frame(width: RequestToken.width)
        .background(RequestToken.surface, in: .rect(cornerRadius: RequestToken.radius, style: .continuous))
        .task { await model.followUpdates() }
        .onDisappear { model.stopWaitingForTouch() }
    }

    private var asking: some View {
        VStack(spacing: 14) {
            header
            VStack(spacing: 10) {
                VStack(spacing: 1) {
                    Text(request.agent.isLocal ? "\(agent) on this Mac wants" : "\(agent) on \(request.agent.machine) wants")
                        .font(.system(size: 13)).foregroundStyle(RequestToken.ink2)
                    Text(request.login.site)
                        .font(.system(size: 32, weight: .bold)).tracking(-0.022 * 32)
                        .foregroundStyle(RequestToken.ink).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(height: 38)
                    Text(request.login.account)
                        .font(.system(size: 13)).foregroundStyle(RequestToken.ink2).lineLimit(1)
                }
                Text("“\(request.agentReason)”")
                    .font(.system(size: 15)).foregroundStyle(RequestToken.ink)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6).padding(.bottom, 2)
            replyRow
            approveLine
            if let failure = model.failure, !ReviewRendering.isOn {
                Text(failure).font(.system(size: 13)).foregroundStyle(RequestToken.deny)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            RequestToken.line.frame(height: 1)
            Text(footer)
                .font(.system(size: 12)).foregroundStyle(RequestToken.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 14)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                AppMark().frame(width: 18, height: 18)
                Text("Agent Keyring").font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.ink2)
            }
            Spacer(minLength: 0)
            if let place {
                HStack(spacing: 5) {
                    Text(place.kind).font(.system(size: 13)).foregroundStyle(RequestToken.ink2)
                    Text(Self.shortened(place.name)).font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.ink)
                }
                .lineLimit(1)
            }
        }
    }

    /// "Project agent-keyring" in a Git repository, else "Folder" and the
    /// folder's name.
    private var place: (kind: String, name: String)? {
        if let project = request.agent.project { return ("Project", project) }
        guard let folder = request.agent.folder else { return nil }
        if folder == "~" { return ("Folder", "Home") }
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return name.isEmpty ? nil : ("Folder", name)
    }

    static func shortened(_ name: String) -> String {
        name.count <= 24 ? name : name.prefix(11) + "…" + name.suffix(12)
    }

    private var sending: AnswerChoice? {
        if case let .sendingAnswer(choice) = request.state { return choice }
        return nil
    }

    /// Return and Escape do nothing here: only the Deny button answers.
    private var replyRow: some View {
        HStack(spacing: 8) {
            TextField("What should \(agent) do instead?", text: $model.replyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 14)).foregroundStyle(RequestToken.ink)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(RequestToken.fill, in: Capsule())
                .disabled(sending != nil)
            Button { Task { await model.deny() } } label: {
                Text(sending == .deny ? "Denying…" : "Deny")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.onAnswer)
                    .padding(.horizontal, 18).frame(height: 36)
                    .background(RequestToken.deny, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(sending != nil)
        }
    }

    private var touchIDAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    @ViewBuilder private var approveLine: some View {
        if touchIDAvailable || ReviewRendering.isOn {
            approveButton
        } else if let context = model.embeddedTouchID {
            HStack(spacing: 6) {
                AppleTouchIDControl(context: context, size: .mini)
                    .frame(width: 18, height: 18)
                    .id(ObjectIdentifier(context))
                    .onAppear { model.waitForTouch() }
                Text("Double-click your Watch to approve")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(RequestToken.approve)
            }
            .frame(height: 18)
        }
    }

    /// Green until a click brings Agent Keyring to the front, then outlined
    /// while Touch ID waits. Only the colours and words fade; Apple's control
    /// sits outside the fade, because it pauses while anything covers it or
    /// it is not fully shown.
    private var approveButton: some View {
        let ready = (isActive || sending == .approve) && (model.embeddedTouchID != nil || ReviewRendering.isOn)
        return ZStack(alignment: .leading) {
            ZStack {
                Capsule().fill(ready ? RequestToken.surface : RequestToken.approve)
                Capsule().strokeBorder(RequestToken.approve, lineWidth: 1.5).opacity(ready ? 1 : 0)
                Text(approveText(ready: ready))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ready ? RequestToken.approve : RequestToken.onAnswer)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, 4 + 36 + 8).padding(.trailing, 16)
            }
            .animation(.easeInOut(duration: 0.15), value: ready)
            .animation(.easeInOut(duration: 0.15), value: sending == .approve)
            Circle().fill(RequestToken.surface).frame(width: 36, height: 36)
                .overlay { touchIDSymbol }
                .padding(.leading, 4)
        }
        .frame(height: 44)
        .contentShape(Capsule())
        .onTapGesture { if model.embeddedTouchID == nil, sending == nil, !ReviewRendering.isOn { model.retryAuthentication() } }
    }

    @ViewBuilder private var touchIDSymbol: some View {
        if ReviewRendering.isOn {
            Image(systemName: "touchid").font(.system(size: 24))
                .foregroundStyle(Color(light: 0xFF2D55, dark: 0xFF375F).opacity(isActive ? 1 : 0.35))
        } else if let context = model.embeddedTouchID, sending == nil {
            AppleTouchIDControl(context: context, size: .small)
                .frame(width: 32, height: 32)
                .id(ObjectIdentifier(context))
                .onAppear { model.waitForTouch() }
        }
    }

    private func approveText(ready: Bool) -> String {
        if sending == .approve { return "Approving…" }
        if model.embeddedTouchID == nil, !ReviewRendering.isOn { return "Try Touch ID again" }
        return ready ? "Touch the sensor to approve" : "Click here, then touch the sensor to approve"
    }

    private var footer: String {
        if case .agentProcess = request.access { return "\(agent) can keep the password once it has seen it." }
        return "\(agent) can use this login for this task, 30 minutes at most."
    }

    @ViewBuilder private var answered: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: outcomeSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(outcomeColour)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcomeTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(RequestToken.ink)
                if let detail = outcomeDetail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(RequestToken.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var outcomeSymbol: String {
        switch request.state {
        case .approved: "checkmark.circle.fill"
        case .denied, .blockedByRule: "xmark.circle.fill"
        default: "clock"
        }
    }

    private var outcomeColour: Color {
        switch request.state {
        case .approved: RequestToken.approve
        case .denied, .blockedByRule: RequestToken.deny
        default: RequestToken.ink2
        }
    }

    private var outcomeTitle: String {
        switch request.state {
        case let .approved(surface, _): surface == .iPhone ? "Approved on your iPhone" : "Approved"
        case let .denied(_, reply, _): reply == nil ? "Denied" : "Denied, with your words"
        case .unanswered: "No answer"
        case .cancelled: "\(agent) stopped asking"
        default: AccessRequestCopy.outcomeWord(request.state)
        }
    }

    private var outcomeDetail: String? {
        switch request.state {
        case let .approved(_, until): "\(agent) can use this login until \(AccessRequestCopy.clock(until)) at the latest."
        case let .denied(_, reply?, _): "You told \(agent): “\(reply)”"
        case .denied: "\(agent) was told."
        case .unanswered: "The request ended after 10 minutes. \(agent) can ask again."
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
        func embeddedTouchIDContext(requestID: String) -> LAContext? { nil }
        func cancelAuthentication(requestID: String) {}
        func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState { request.state }
        func deny(requestID: String, reply: String?, context: LAContext?, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState { request.state }
        func allowAskingAgain(requestID: String) async throws -> AccessRequestState { request.state }
    }

    @MainActor public static func panel(_ request: AccessRequest, reply: String = "", active: Bool = false) -> some View {
        isOn = true
        let model = MacApprovalModel(request: request, backend: Backend(request))
        model.replyDraft = reply
        let activity = PanelActivity()
        activity.isActive = active
        return MacApprovalPanelView(model: model, activity: activity)
    }
}

/// The app's mark from the design: a blue tile with a white keyhole figure.
struct AppMark: View {
    var body: some View {
        Canvas { context, size in
            let s = size.width / 100
            let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: 100 * s, height: 100 * s), cornerRadius: 22.5 * s)
            context.fill(tile, with: .linearGradient(Gradient(colors: [Color(light: 0x2F62F5, dark: 0x2F62F5), Color(light: 0x1040D8, dark: 0x1040D8)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: 100 * s)))
            context.fill(Path(ellipseIn: CGRect(x: (50 - 21.5) * s, y: (38.5 - 21.5) * s, width: 43 * s, height: 43 * s)), with: .color(.white))
            var body = Path()
            body.move(to: CGPoint(x: 40.2 * s, y: 51.5 * s))
            body.addLine(to: CGPoint(x: 59.8 * s, y: 51.5 * s))
            body.addLine(to: CGPoint(x: 67.2 * s, y: 81.9 * s))
            body.addLine(to: CGPoint(x: 64.1 * s, y: 85.9 * s))
            body.addLine(to: CGPoint(x: 35.9 * s, y: 85.9 * s))
            body.addLine(to: CGPoint(x: 32.8 * s, y: 81.9 * s))
            body.closeSubpath()
            context.fill(body, with: .color(.white))
            let eye = Color(light: 0x0B1B4D, dark: 0x0B1B4D)
            for x in [46.3, 60.0] {
                context.fill(Path(ellipseIn: CGRect(x: (x - 4.9) * s, y: (37.5 - 4.9) * s, width: 9.8 * s, height: 9.8 * s)), with: .color(eye))
            }
        }
    }
}

/// Apple's live Touch ID and Watch control, uncovered. It draws its own
/// symbol: pale while paused, pink while Touch ID waits.
struct AppleTouchIDControl: NSViewRepresentable {
    let context: LAContext
    let size: NSControl.ControlSize

    func makeNSView(context representableContext: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: size)
    }

    func updateNSView(_ view: LAAuthenticationView, context representableContext: Context) {}
}

/// A borderless panel beside the pointer. Showing it never activates Agent
/// Keyring; a click in it does, so Touch ID can run and the reply box can
/// take typing. Clicks in its first half second are ignored, so a click
/// already on its way cannot land on Deny.
final class RequestPanel: NSPanel {
    private var shownAt = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    /// The app Josh was using when he clicked the request.
    private var previousApp: NSRunningApplication?
    var onActiveChange: (Bool) -> Void = { _ in }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: RequestToken.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // AppKit can call the app active while another app is still in front
        // and has the keyboard; Apple's control needs the app in front.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onActiveChange(Self.isFrontmost) }
        })
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
    }

    func show(at frame: NSRect) {
        setFrame(frame, display: true)
        shownAt = Date()
        orderFrontRegardless()
    }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            guard Date().timeIntervalSince(shownAt) >= 0.5 else { return }
            if !Self.isFrontmost {
                previousApp = NSWorkspace.shared.frontmostApplication
                NSApp.activate()
            }
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

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    /// Hands the keyboard back to the app Josh was using, if he clicked here.
    func giveFocusBack() {
        guard Self.isFrontmost, let previousApp, !previousApp.isTerminated else { return }
        NSApp.yieldActivation(to: previousApp)
        previousApp.activate()
        self.previousApp = nil
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
}

/// Holds the request panel's view and keeps its height fitted to the content
/// without the window and SwiftUI resizing each other in a loop.
@MainActor
final class RequestPanelHost {
    let panel = RequestPanel()
    private let hosting: NSHostingView<AnyView>
    private let activity = PanelActivity()

    init(model: MacApprovalModel) {
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        // Only report a size; never let SwiftUI resize the window itself.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.rootView = AnyView(MacApprovalPanelView(model: model, activity: activity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                self?.fit(height: height)
            })
        panel.contentView = hosting
        panel.onActiveChange = { [weak self, weak model] active in
            guard let self, self.activity.isActive != active else { return }
            self.activity.isActive = active
            // Apple's control stays paused after the app comes to the front;
            // a fresh evaluation arms Touch ID.
            if active { model?.rearmTouchID() }
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
        let height = max(hosting.intrinsicContentSize.height, 100).rounded(.up)
        panel.show(at: RequestPanel.frame(size: CGSize(width: RequestToken.width, height: height),
            pointer: NSEvent.mouseLocation, visibleFrames: NSScreen.screens.map(\.visibleFrame)))
    }
}
#endif
