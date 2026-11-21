// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt from the shared page parts on 2026.11.21.
//
// One request inside the app, opened from its notification, from Deny and
// Explain, or from Home: who asks and for what, the agent's reason, a reply
// box that grows with our microphone, then Deny and Send, or Approve Instead
// with Face ID. The reply box is a system text field until the shared parts
// have one.

#if os(iOS)
import AgentKeyringDesign
import SwiftUI

struct PhoneRequestView: View {
    @Bindable var model: PhoneModel
    let request: AccessRequest
    /// First run's practice request: the same layout, the practice words.
    var practice = false
    @FocusState private var replyFocused: Bool
    @State private var dictation = PhoneDictation()
    /// What was in the box before speaking; what is heard follows it.
    @State private var spokenAfter = ""

    var body: some View {
        let busy = model.answering != nil
        KeyringPage(step: nil, title: request.login.site, sentence: PhoneCopy.wants(request.agent), status: status,
                    primary: .deny(PhoneCopy.denyAndSend, isEnabled: !busy) { deny() },
                    secondary: .approve(PhoneCopy.approveInstead, isEnabled: !busy) { approve() },
                    aside: .link(PhoneCopy.cancel) { model.shownRequestID = nil }) {
            KeyringText(PhoneCopy.askedAgo(request.askedAt), as: .caption)
            if !request.login.account.isEmpty { KeyringText(request.login.account, as: .meta) }
            if !request.agentReason.isEmpty { KeyringText(PhoneCopy.quoted(request.agentReason), as: .body) }
            KeyringText(PhoneCopy.tellTheAgent, as: .heading)
            replyBox
            if case .cannotListen(.microphoneOff) = dictation.state {
                KeyringButton(.link(PhoneCopy.openSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                })
            }
            if dictation.isListening { KeyringText(PhoneCopy.speakHint, as: .caption) }
            KeyringText(practice ? PhoneCopy.practiceLasts : PhoneCopy.lasts(request.agent), as: .caption)
        }
        .alert(PhoneCopy.answerFailed, isPresented: failureShown) { Button(PhoneCopy.ok) { model.dismissFailure() } }
        .sensoryFeedback(.selection, trigger: model.answering)
        .onChange(of: dictation.heard) { _, heard in if dictation.isListening { model.replyDraft = spokenAfter + heard } }
        .onDisappear { Task { await dictation.stop() } }
        .onAppear { if model.explaining == request.id { replyFocused = true } }
    }

    /// The microphone's state, or the answer not delivered yet; nothing otherwise.
    private var status: KeyringStatus? {
        if model.snapshot.undelivered.contains(request.id) { return .takingLong(PhoneCopy.notDeliveredYet) }
        switch dictation.state {
        case .listening, .starting: return .waiting(PhoneCopy.listening)
        case let .cannotListen(reason): return .problem(PhoneCopy.cannotListen(reason))
        case .idle: return nil
        }
    }

    /// A system text field that grows to ten lines, with the microphone: one tap to speak, one to stop.
    private var replyBox: some View {
        HStack(alignment: .bottom, spacing: KeyringSpace.s2) {
            TextField(PhoneCopy.tellTheAgent, text: $model.replyDraft, axis: .vertical)
                .lineLimit(1...10)
                .focused($replyFocused)
                .textFieldStyle(.roundedBorder)
            Button {
                if !dictation.isListening { spokenAfter = model.replyDraft.isEmpty ? "" : model.replyDraft + " " }
                replyFocused = false
                Task { await dictation.toggle() }
            } label: {
                Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(dictation.isListening ? KeyringPalette.deny : KeyringPalette.brand)
            .accessibilityLabel(dictation.isListening ? PhoneCopy.stopSpeaking : PhoneCopy.speakReply)
        }
    }

    private func deny() {
        replyFocused = false
        Task { if dictation.isListening { await dictation.stop() }; await model.deny(request.id) }
    }

    private func approve() {
        replyFocused = false
        Task { if dictation.isListening { await dictation.stop() }; await model.approve(request.id) }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
    }
}
#endif
