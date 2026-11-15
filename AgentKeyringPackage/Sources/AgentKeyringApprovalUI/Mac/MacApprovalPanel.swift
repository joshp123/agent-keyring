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
            return "Approval was interrupted. Try again."
        case .companionNotAvailable, .biometryNotAvailable, .biometryNotEnrolled, .biometryNotPaired, .biometryDisconnected:
            return "Touch ID or Apple Watch isn't available. Check that one is ready and try again."
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
    /// A context attached to the panel before evaluation starts. Nil means
    /// neither Touch ID nor Apple Watch is currently available.
    func embeddedTouchIDContext(requestID: String) -> LAContext?
    func cancelAuthentication(requestID: String)
    /// Runs Touch ID (or Apple Watch) and records the answer. Returns the new state.
    func approve(requestID: String, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState
    func deny(requestID: String, reply: String?, context: LAContext?, onAuthenticated: @MainActor () -> Void) async throws -> AccessRequestState
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
    /// Set while the panel waits for Touch ID or Apple Watch.
    public private(set) var embeddedTouchID: LAContext?
    public private(set) var pendingDenialReply: String?
    /// Called when Josh is done with the panel.
    public var close: () -> Void = {}

    private let backend: any MacApprovalBackend
    private var touchWait: Task<Void, Never>?
    private var previousWait: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    var authenticationTimeoutDuration: Duration = .seconds(60)
    private var touchWaitID = UUID()

    public init(request: AccessRequest, moreWaiting: Int = 0, backend: any MacApprovalBackend) {
        self.request = request
        self.moreWaiting = moreWaiting
        self.backend = backend
        self.embeddedTouchID = backend.embeddedTouchIDContext(requestID: request.id)
        if embeddedTouchID == nil { failure = "Touch ID or Apple Watch isn't available. Check that one is ready and try again." }
    }

    /// Starts waiting for a touch, if the backend supports it. The request stays
    /// answerable with Deny meanwhile; Deny cancels the wait.
    public func waitForTouch() {
        guard embeddedTouchID != nil, touchWait == nil, request.state.isWaitingForYou else { return }
        let waitID = touchWaitID
        let previous = previousWait
        previousWait = nil
        timeout = Task {
            do { try await Task.sleep(for: authenticationTimeoutDuration) } catch { return }
            guard touchWaitID == waitID, request.state.isWaitingForYou else { return }
            stopWaitingForTouch()
            embeddedTouchID = nil
            failure = "Approval timed out. Try again."
        }
        touchWait = Task {
            await previous?.value
            guard !Task.isCancelled, touchWaitID == waitID else { return }
            do {
                let state: AccessRequestState
                if let reply = pendingDenialReply, let context = embeddedTouchID {
                    state = try await backend.deny(requestID: request.id, reply: reply, context: context) { self.cancelTimeout() }
                } else {
                    state = try await backend.approve(requestID: request.id) { self.cancelTimeout() }
                }
                guard !Task.isCancelled, touchWaitID == waitID else { return }
                request.state = state
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, touchWaitID == waitID else { return }
                let native = error as NSError
                approvalLogger.error("Approval failed: domain=\(native.domain, privacy: .public) code=\(native.code, privacy: .public)")
                embeddedTouchID = nil
                failure = ownerAuthenticationFailure(error, fallback: "Approval didn't finish. Nothing was shared. Try again.")
            }
            if touchWaitID == waitID { touchWait = nil; timeout?.cancel(); timeout = nil }
        }
    }

    /// Stops waiting for a touch without answering. Call when the panel goes away.
    public func stopWaitingForTouch() {
        touchWaitID = UUID()
        if let touchWait { previousWait = touchWait }
        touchWait?.cancel()
        touchWait = nil
        timeout?.cancel()
        timeout = nil
        backend.cancelAuthentication(requestID: request.id)
    }

    public func retryAuthentication() {
        guard touchWait == nil else { return }
        failure = nil
        embeddedTouchID = backend.embeddedTouchIDContext(requestID: request.id)
        if embeddedTouchID == nil { failure = "Touch ID or Apple Watch isn't available. Check that one is ready and try again." }
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

    public func deny() async {
        stopWaitingForTouch()
        let reply = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty && !request.agent.isLocal {
            pendingDenialReply = reply
            retryAuthentication()
            return
        }
        await answer(.deny) { try await backend.deny(requestID: request.id, reply: reply.isEmpty ? nil : reply, context: nil, onAuthenticated: {}) }
    }

    public func cancelDenial() {
        stopWaitingForTouch()
        pendingDenialReply = nil
        retryAuthentication()
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    private func answer(_ choice: AnswerChoice, send: () async throws -> AccessRequestState) async {
        let previous = request.state
        request.state = .sendingAnswer(choice)
        failure = nil
        do { request.state = try await send() }
        catch {
            let native = error as NSError
            approvalLogger.error("Answer failed: domain=\(native.domain, privacy: .public) code=\(native.code, privacy: .public)")
            request.state = previous
            failure = (error as? LocalizedError)?.errorDescription
                ?? (choice == .approve ? "Approval didn't finish. Nothing was shared. Try again." : "The denial wasn't saved. Try again.")
        }
    }
}

public struct MacApprovalPanelView: View {
    @Bindable var model: MacApprovalModel

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
        .onDisappear { model.stopWaitingForTouch() }
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
        case .waitingForYou, .sendingAnswer:
            replyField
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

    private var hasReply: Bool {
        !model.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Takes focus only when Josh clicks into it. Return does nothing: only
    /// the Deny button answers, so typing meant for another app can never deny.
    private var replyField: some View {
        TextField(AccessRequestCopy.replyPlaceholder(model.request.agent), text: $model.replyDraft, axis: .vertical)
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            .disabled(sending != nil || model.pendingDenialReply != nil)
    }

    @ViewBuilder private var answerButtons: some View {
        HStack(spacing: 10) {
            Button {
                if model.pendingDenialReply != nil { model.cancelDenial() }
                else { Task { await model.deny() } }
            } label: {
                if model.pendingDenialReply != nil {
                    Text("Cancel")
                } else if sending == .deny {
                    ProgressView().controlSize(.small).tint(.white)
                } else if hasReply && !model.request.agent.isLocal {
                    // A reply to an agent on another machine is signed, so it takes Touch ID.
                    Label(AccessRequestCopy.denyAndSendReply, systemImage: "touchid")
                } else {
                    Text(hasReply ? AccessRequestCopy.denyAndSendReply : AccessRequestCopy.deny)
                }
            }
            .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny, height: 36))
            .disabled(sending == .approve)

            if let context = model.embeddedTouchID {
                EmbeddedOwnerApproval(context: context, action: model.pendingDenialReply == nil ? "approve" : "send your reply")
                    .id(ObjectIdentifier(context))
                    .onAppear { model.waitForTouch() }
            } else {
                Button {
                    model.retryAuthentication()
                } label: {
                    Label("Try again", systemImage: "touchid")
                }
                .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve, height: 36))
                .disabled(sending == .deny)
            }
        }
        .allowsHitTesting(sending == nil)

        if model.moreWaiting > 0 {
            Text("\(model.moreWaiting) more waiting")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                if model.request.answerIsQueued {
                    Text(AccessRequestCopy.answerQueued)
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
public struct EmbeddedOwnerApproval: View {
    public let context: LAContext
    public let action: String

    public init(context: LAContext, action: String = "approve") { self.context = context; self.action = action }

    private var label: String {
        let touch = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let watch = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithCompanion, error: nil)
        if touch && watch { return "Touch ID or Apple Watch to \(action)" }
        return touch ? "Touch ID to \(action)" : "Apple Watch to \(action)"
    }

    public var body: some View {
        HStack(spacing: 8) {
            TouchIDGlyph(context: context)
                .frame(width: 22, height: 22)
            Text(label)
                .font(.headline)
                .foregroundStyle(KeyringColour.approveText)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .overlay {
            RoundedRectangle(cornerRadius: KeyringMetric.buttonCorner, style: .continuous)
                .strokeBorder(KeyringColour.approve, lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

private struct TouchIDGlyph: NSViewRepresentable {
    let context: LAContext

    func makeNSView(context representableContext: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: context, controlSize: .small)
    }

    func updateNSView(_ view: LAAuthenticationView, context representableContext: Context) {}
}

/// Hosts the panel beside the window Josh is working in (see
/// ApprovalPanelPlacement). Non-activating: the app Josh is typing in keeps focus until
/// he clicks the panel.
@MainActor
public final class MacApprovalPanelController {
    private var panel: NSPanel?

    public init() {}

    public func show(_ model: MacApprovalModel) {
        showPanel(MacApprovalPanelView(model: model))
        model.close = { [weak self] in self?.close() }
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
        // Buttons work without the panel taking the keyboard; only a click in
        // the reply field makes it key.
        panel.becomesKeyOnlyIfNeeded = true
        panel.setContentSize(controller.view.fittingSize)
        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Never hand the keyboard to a field on Josh's behalf, even when Agent
    /// Keyring is the active app: SwiftUI would focus the reply field and
    /// catch typing meant for elsewhere. A click in the field still focuses
    /// it, because the click is handled after this.
    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(nil)
    }
}
#endif
