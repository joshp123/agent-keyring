// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Mac's answer to a request: a small panel under the menu bar with the
// same facts as the iPhone and Touch ID to approve. It never takes keyboard
// focus on its own, so typing elsewhere can't answer it.

#if os(macOS)
import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import Observation
import SwiftUI

/// Everything the Mac panel needs from the outside world.
@MainActor
public protocol MacApprovalBackend: AnyObject {
    /// The request now, then each time it changes: answered on the iPhone,
    /// withdrawn by the agent, unanswered at its deadline. Ends when it is final.
    func updates(requestID: String) -> AsyncStream<AccessRequest>
    /// A Touch ID context the panel shows inside itself, so touching the sensor
    /// alone approves. `approve` must evaluate this same context, and stop
    /// waiting (invalidate it) when its task is cancelled. Nil: Approve is a
    /// button that brings up the system Touch ID or Apple Watch prompt.
    func embeddedTouchIDContext(requestID: String) -> LAContext?
    /// Runs Touch ID (or Apple Watch) and records the answer. Returns the new state.
    func approve(requestID: String) async throws -> AccessRequestState
    func deny(requestID: String, reply: String?) async throws -> AccessRequestState
}

@MainActor
@Observable
public final class MacApprovalModel {
    public private(set) var request: AccessRequest
    /// Other requests queued behind this one.
    public var moreWaiting: Int
    public var isReplying = false
    public var replyDraft = ""
    public private(set) var failure: String?
    /// Set while the panel waits for a touch on the sensor. Nil after a failed
    /// touch, so Approve falls back to the button.
    public private(set) var embeddedTouchID: LAContext?
    /// Called when Josh is done with the panel.
    public var close: () -> Void = {}

    private let backend: any MacApprovalBackend
    private var touchWait: Task<Void, Never>?

    public init(request: AccessRequest, moreWaiting: Int = 0, backend: any MacApprovalBackend) {
        self.request = request
        self.moreWaiting = moreWaiting
        self.backend = backend
        self.embeddedTouchID = backend.embeddedTouchIDContext(requestID: request.id)
    }

    /// Starts waiting for a touch, if the backend supports it. The request stays
    /// answerable with Deny meanwhile; Deny cancels the wait.
    public func waitForTouch() {
        guard embeddedTouchID != nil, touchWait == nil, request.state.isWaitingForYou else { return }
        touchWait = Task {
            do {
                request.state = try await backend.approve(requestID: request.id)
            } catch is CancellationError {
            } catch {
                embeddedTouchID = nil
                failure = "Touch ID didn't confirm. Nothing was shared."
            }
            touchWait = nil
        }
    }

    private func stopWaitingForTouch() {
        touchWait?.cancel()
        touchWait = nil
    }

    /// Follows the request until the panel closes. Call from `.task`.
    public func followUpdates() async {
        for await latest in backend.updates(requestID: request.id) {
            // An answer on its way stays on screen until the backend reports the outcome.
            if case .sendingAnswer = request.state, latest.state.isWaitingForYou { continue }
            request = latest
            if !latest.state.isWaitingForYou { stopWaitingForTouch() }
        }
    }

    public func approve() async {
        await answer(.approve) { try await backend.approve(requestID: request.id) }
    }

    public func deny() async {
        stopWaitingForTouch()
        let reply = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isReplying = false
        await answer(.deny) { try await backend.deny(requestID: request.id, reply: reply.isEmpty ? nil : reply) }
    }

    private func answer(_ choice: AnswerChoice, send: () async throws -> AccessRequestState) async {
        let previous = request.state
        request.state = .sendingAnswer(choice)
        failure = nil
        do { request.state = try await send() }
        catch {
            request.state = previous
            failure = choice == .approve ? "Touch ID didn't confirm. Nothing was shared." : "The denial wasn't saved. Try again."
        }
    }
}

public struct MacApprovalPanelView: View {
    @Bindable var model: MacApprovalModel
    @FocusState private var replyFocused: Bool

    public init(model: MacApprovalModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            AccessRequestHeadline(request: model.request, siteFont: .title)
            Divider()
            AccessRequestFacts(request: model.request)
            Divider()
            AgentClaim(request: model.request, lineLimit: 4)
            Divider()
            answers
        }
        .padding(18)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.followUpdates() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal.fill")
                .foregroundStyle(KeyringColour.signal)
            Text("Agent Keyring")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if case let .waitingForYou(until) = model.request.state {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(AccessRequestCopy.remaining(until: until, now: context.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(KeyringColour.signal)
                }
            }
        }
    }

    @ViewBuilder private var answers: some View {
        switch model.request.state {
        case .waitingForYou where model.isReplying:
            replyComposer
        case .waitingForYou, .sendingAnswer:
            answerButtons
        default:
            outcome
        }
        if let failure = model.failure {
            Text(failure)
                .font(.callout)
                .foregroundStyle(KeyringColour.denyText)
        }
    }

    private var sending: AnswerChoice? {
        if case let .sendingAnswer(choice) = model.request.state { return choice }
        return nil
    }

    @ViewBuilder private var answerButtons: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.deny() }
            } label: {
                if sending == .deny { ProgressView().controlSize(.small).tint(.white) }
                else { Text(AccessRequestCopy.deny) }
            }
            .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny, height: 36))
            .disabled(sending == .approve)

            if let context = model.embeddedTouchID {
                EmbeddedTouchIDApproval(context: context)
                    .onAppear { model.waitForTouch() }
            } else {
                Button {
                    Task { await model.approve() }
                } label: {
                    if sending == .approve {
                        Label("Touch the sensor", systemImage: "touchid")
                    } else {
                        Label(AccessRequestCopy.approve, systemImage: "touchid")
                    }
                }
                .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve, height: 36))
                .disabled(sending == .deny)
            }
        }
        .allowsHitTesting(sending == nil)

        HStack {
            Button(AccessRequestCopy.denyAndReply) { model.isReplying = true; replyFocused = true }
                .buttonStyle(.link)
                .foregroundStyle(KeyringColour.denyText)
            Spacer()
            if model.moreWaiting > 0 {
                Text("\(model.moreWaiting) more waiting")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var replyComposer: some View {
        Text(AccessRequestCopy.replySheetTitle(model.request.agent))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(KeyringColour.denyText)
        TextField(AccessRequestCopy.replyPlaceholder, text: $model.replyDraft, axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .focused($replyFocused)
            .onSubmit { Task { await model.deny() } }
        HStack(spacing: 10) {
            Button("Cancel") { model.isReplying = false }
                .buttonStyle(.quiet(height: 36))
                .frame(maxWidth: 110)
            Button(AccessRequestCopy.denyAndSend) { Task { await model.deny() } }
                .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny, height: 36))
        }
    }

    @ViewBuilder private var outcome: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: outcomeSymbol(model.request.state))
                .font(.title3)
                .foregroundStyle(outcomeColour(model.request.state) ?? .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(AccessRequestCopy.outcome(model.request) ?? "")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if case let .denied(_, reply?, _) = model.request.state {
                    Text("You replied: “\(reply)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        Button("Close", action: model.close)
            .buttonStyle(.quiet(height: 32))
    }
}

/// Approve without a click: the system Touch ID glyph, live, inside the panel.
/// Touching the sensor while the panel is up approves.
private struct EmbeddedTouchIDApproval: View {
    let context: LAContext

    var body: some View {
        HStack(spacing: 8) {
            TouchIDGlyph(context: context)
                .frame(width: 22, height: 22)
            Text("Touch ID to approve")
                .font(.headline)
                .foregroundStyle(KeyringColour.approveText)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .overlay {
            RoundedRectangle(cornerRadius: KeyringMetric.buttonCorner, style: .continuous)
                .strokeBorder(KeyringColour.approve, lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Touch ID to approve")
    }
}

private struct TouchIDGlyph: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context representableContext: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: .small)
    }

    func updateNSView(_ view: LAAuthenticationView, context representableContext: Context) {}
}

/// The blurred background menus and popovers use.
private struct PanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Hosts the panel under the menu bar, at the top right of the screen with
/// the pointer. Non-activating: the app Josh is typing in keeps focus until
/// he clicks the panel.
@MainActor
public final class MacApprovalPanelController {
    private var panel: NSPanel?

    public init() {}

    public func show(_ model: MacApprovalModel) {
        close()
        let panel = KeyringPanel.floating(MacApprovalPanelView(model: model))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 12, y: visible.maxY - 8))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        model.close = { [weak self] in self?.close() }
    }

    public func close() {
        panel?.orderOut(nil)
    }
}

/// Becomes key only when Josh clicks into it (to type a reply), never on its own.
final class KeyringPanel: NSPanel {
    /// A borderless, rounded, translucent panel above other windows that
    /// grows and shrinks with its SwiftUI content. Not yet on screen.
    static func floating(_ content: some View) -> KeyringPanel {
        let controller = NSHostingController(rootView: content
            .background(PanelMaterial())
            .clipShape(.rect(cornerRadius: 14, style: .continuous)))
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
        panel.setContentSize(controller.view.fittingSize)
        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
