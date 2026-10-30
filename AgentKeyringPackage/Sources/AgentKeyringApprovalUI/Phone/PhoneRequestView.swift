// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// One request, one question, two answers. Everything Josh needs to decide is
// on one screen; the answer buttons stay under his thumb.

#if os(iOS)
import SwiftUI

struct PhoneRequestView: View {
    @Bindable var model: PhoneKeyringModel
    let requestID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let request = model.request(id: requestID) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if case let .waitingForYou(until) = request.state {
                            WaitingStatusLine(deadline: until)
                        }
                        AccessRequestHeadline(request: request)
                        Hairline()
                        AccessRequestFacts(request: request)
                        Hairline()
                        AgentClaim(request: request)
                    }
                    .padding(.horizontal, KeyringMetric.margin)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PhoneAnswerArea(model: model, request: request) { dismiss() }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
                .alert("Something went wrong", isPresented: failureShown) {
                    Button("OK") { model.dismissFailure() }
                } message: {
                    Text(model.failure ?? "")
                }
            }
            .tint(KeyringColour.signal)
            .presentationDragIndicator(.visible)
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
    }
}

/// The bottom of the request screen: the two answers while waiting, the
/// outcome once there is one.
private struct PhoneAnswerArea: View {
    let model: PhoneKeyringModel
    let request: AccessRequest
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            switch request.state {
            case .waitingForYou where model.isReplying:
                PhoneReplyComposer(model: model, request: request)
            case .waitingForYou, .sendingAnswer:
                answerButtons
            default:
                outcome
            }
        }
        .padding(.horizontal, KeyringMetric.margin)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Hairline()
                Rectangle().fill(.background)
            }
            .ignoresSafeArea()
        }
        .sensoryFeedback(trigger: request.state) { _, state in
            switch state {
            case .approved: .success
            case .denied: .warning
            default: nil
            }
        }
    }

    private var sending: AnswerChoice? {
        if case let .sendingAnswer(choice) = request.state { return choice }
        return nil
    }

    @ViewBuilder private var answerButtons: some View {
        // While an answer is on its way, its button keeps its colour and shows
        // progress; the other one fades.
        HStack(spacing: 12) {
            Button {
                Task { await model.deny(request.id) }
            } label: {
                if sending == .deny { ProgressView().tint(.white) } else { Text(AccessRequestCopy.deny) }
            }
            .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny))
            .disabled(sending == .approve)

            Button {
                Task { await model.approve(request.id) }
            } label: {
                if sending == .approve {
                    ProgressView().tint(.white)
                } else {
                    Label(AccessRequestCopy.approve, systemImage: "faceid")
                }
            }
            .buttonStyle(DecisionButtonStyle(colour: KeyringColour.approve))
            .disabled(sending == .deny)
        }
        .allowsHitTesting(sending == nil)

        Button(AccessRequestCopy.denyAndReply) { model.isReplying = true }
            .font(.body.weight(.medium))
            .foregroundStyle(KeyringColour.denyText)
            .disabled(sending != nil)
            .frame(minHeight: 32)
    }

    @ViewBuilder private var outcome: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: outcomeSymbol(request.state))
                .font(.title2)
                .foregroundStyle(outcomeColour(request.state) ?? .secondary)
                .symbolEffect(.bounce, value: request.state)
            VStack(alignment: .leading, spacing: 6) {
                Text(AccessRequestCopy.outcome(request) ?? "")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if case let .denied(_, reply?) = request.state {
                    Text("You replied: “\(reply)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 12) {
            if request.state.isInUse {
                Button(AccessRequestCopy.endNow) { Task { await model.endAccess(request.id) } }
                    .buttonStyle(.quiet(text: KeyringColour.denyText))
            }
            Button("Done", action: close)
                .buttonStyle(.quiet())
        }
    }
}

/// Deny, with something to tell the agent, typed or dictated. Takes the
/// place of the two answer buttons, so the request stays in view.
private struct PhoneReplyComposer: View {
    @Bindable var model: PhoneKeyringModel
    let request: AccessRequest
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AccessRequestCopy.replySheetTitle(request.agent))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KeyringColour.denyText)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(AccessRequestCopy.replyPlaceholder, text: $model.replyDraft, axis: .vertical)
                    .lineLimit(2...6)
                    .focused($focused)
                    .padding(.vertical, 10)
                    .padding(.leading, 12)
                Button {
                    model.toggleDictation()
                } label: {
                    Image(systemName: model.isListening ? "waveform" : "mic.fill")
                        .symbolEffect(.variableColor.iterative, isActive: model.isListening)
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(KeyringColour.signal, in: .circle)
                }
                .accessibilityLabel(model.isListening ? "Stop dictation" : "Dictate a reply")
                .padding(4)
            }
            .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 22, style: .continuous))

            HStack(spacing: 12) {
                Button("Cancel") {
                    model.stopDictation()
                    model.isReplying = false
                }
                .buttonStyle(.quiet())
                .frame(maxWidth: 120)

                Button(AccessRequestCopy.denyAndSend) {
                    Task { await model.deny(request.id) }
                }
                .buttonStyle(DecisionButtonStyle(colour: KeyringColour.deny))
            }
        }
        .onAppear { focused = model.replyDraft.isEmpty }
    }
}
#endif
