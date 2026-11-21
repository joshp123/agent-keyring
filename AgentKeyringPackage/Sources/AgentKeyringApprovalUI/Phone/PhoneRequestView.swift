// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt from the shared page parts on 2026.11.21.
//
// One request inside the app, opened from its notification, from Deny and
// Explain, or from Home: who asks and for what, the agent's reason, a reply
// box that grows with our microphone, then Deny and Send, or Approve Instead
// with Face ID.

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
            if dictation.isListening { KeyringText(PhoneCopy.speakHint, as: .caption) }
            KeyringText(practice ? PhoneCopy.practiceLasts : PhoneCopy.lasts(request.agent), as: .caption)
        }
        .alert(PhoneCopy.answerFailed, isPresented: failureShown) { Button(PhoneCopy.ok) { model.dismissFailure() } }
        .sensoryFeedback(.selection, trigger: model.answering)
        .onChange(of: dictation.heard) { _, heard in if dictation.isListening { model.replyDraft = spokenAfter + heard } }
        .onDisappear { Task { await dictation.stop() } }
        .onAppear { if model.explaining == request.id { replyFocused = true } }
    }

    /// The answer not delivered yet; nothing otherwise.
    private var status: KeyringStatus? {
        model.snapshot.undelivered.contains(request.id) ? .takingLong(PhoneCopy.notDeliveredYet) : nil
    }

    /// The microphone's state, under the reply box.
    private var note: KeyringStatus? {
        switch dictation.state {
        case .listening, .starting: .listening(PhoneCopy.listening)
        case let .cannotListen(.gettingReady(percent)): .waiting(PhoneCopy.cannotListen(.gettingReady(percent: percent)))
        case let .cannotListen(reason): .problem(PhoneCopy.cannotListen(reason))
        case .idle: nil
        }
    }

    /// The reply box grows to ten lines, with the microphone: one tap to speak, one to stop.
    private var replyBox: some View {
        KeyringReplyBox(text: $model.replyDraft, prompt: PhoneCopy.tellTheAgent, note: note, noteAction: openSettings) {
            Button {
                if !dictation.isListening { spokenAfter = model.replyDraft.isEmpty ? "" : model.replyDraft + " " }
                replyFocused = false
                Task { await dictation.toggle() }
            } label: {
                Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
            }
            .accessibilityLabel(dictation.isListening ? PhoneCopy.stopSpeaking : PhoneCopy.speakReply)
        }
        .focused($replyFocused)
    }

    private var openSettings: KeyringAction? {
        guard case .cannotListen(.microphoneOff) = dictation.state else { return nil }
        return .link(PhoneCopy.openSettings) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
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
