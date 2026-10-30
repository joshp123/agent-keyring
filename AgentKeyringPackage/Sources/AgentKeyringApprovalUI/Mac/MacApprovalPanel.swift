// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// The Mac's answer to a request: a small panel under the menu bar with the
// same facts as the iPhone and Touch ID to approve. It never takes keyboard
// focus on its own, so typing elsewhere can't answer it.

#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// Everything the Mac panel needs from the outside world.
@MainActor
public protocol MacApprovalBackend: AnyObject {
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
    /// Called when Josh is done with the panel.
    public var close: () -> Void = {}

    private let backend: any MacApprovalBackend

    public init(request: AccessRequest, moreWaiting: Int = 0, backend: any MacApprovalBackend) {
        self.request = request
        self.moreWaiting = moreWaiting
        self.backend = backend
    }

    public func approve() async {
        await answer(.approve) { try await backend.approve(requestID: request.id) }
    }

    public func deny() async {
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
                if case let .denied(_, reply?) = model.request.state {
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

/// Hosts the panel under the menu bar, at the top right of the screen with
/// the pointer. Non-activating: the app Josh is typing in keeps focus until
/// he clicks the panel.
@MainActor
public final class MacApprovalPanelController {
    private var panel: NSPanel?

    public init() {}

    public func show(_ model: MacApprovalModel) {
        let hosting = NSHostingView(rootView: MacApprovalPanelView(model: model)
            .ignoresSafeArea()
            .background(.regularMaterial))
        let panel = panel ?? KeyringPanel(contentRect: .zero,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
