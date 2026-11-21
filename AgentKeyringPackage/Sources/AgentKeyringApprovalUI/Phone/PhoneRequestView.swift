// Written by AI on 2026.11.18 by model Claude Opus 5.5; rebuilt with explicit Decide / Approving / Explain modes on 2026.11.21 by Gemini 4 Neon.
//
// One request inside the app's single modal sheet, driven by PhoneSheetState.Mode:
// - .decide: normal tap on a notification or practice request (Approve with Face ID, Deny, Deny and Explain).
// - .approving: one-step Approve from a held notification or in-flight send (clean status, never flashes a Deny form).
// - .explain: Deny and Explain with compact 2-line request header and direct TextField focus so the reply box and microphone stay clear above the keyboard.

#if os(iOS)
import AgentKeyringDesign
import SwiftUI

struct PhoneRequestView: View {
    @Bindable var model: PhoneModel
    let request: AccessRequest
    var mode: PhoneSheetState.Mode = .decide
    /// First run's practice request: the same layout, the practice words.
    var practice = false
    @FocusState private var replyFocused: Bool
    @State private var dictation = PhoneDictation()
    /// What was in the box before speaking; what is heard follows it.
    @State private var spokenAfter = ""

    var body: some View {
        Group {
            switch mode {
            case .decide: decidePage
            case .approving: approvingPage
            case .explain: explainPage
            }
        }
        .alert(PhoneCopy.answerFailed, isPresented: failureShown) { Button(PhoneCopy.ok) { model.dismissFailure() } }
        .sensoryFeedback(.selection, trigger: model.answering)
        .onChange(of: dictation.heard) { _, heard in
            if dictation.isListening { model.setDraft(spokenAfter + heard, for: request.id) }
        }
        .onChange(of: request.id) { _, _ in
            // Switching requests inside the single sheet must stop dictation immediately and reset prefix.
            replyFocused = (mode == .explain)
            spokenAfter = ""
            Task { await dictation.stop() }
        }
        .onChange(of: mode) { _, next in
            if next == .explain {
                replyFocused = true
            } else {
                replyFocused = false
                spokenAfter = ""
                Task { await dictation.stop() }
            }
        }
        .onDisappear { Task { await dictation.stop() } }
        .onAppear { if mode == .explain { replyFocused = true } }
    }

    private var busy: Bool { model.answering != nil || mode == .approving }

    /// Normal notification tap: balanced Approve with Face ID, Deny, and Deny and Explain.
    private var decidePage: some View {
        KeyringPage(status: status,
                    primary: .approve(PhoneCopy.approveWithFaceID, isEnabled: !busy) { approve() },
                    secondary: .deny(PhoneCopy.deny, isEnabled: !busy) { deny(withDraft: false) },
                    aside: .denyLink(PhoneCopy.denyAndExplain, isEnabled: !busy) { model.explain(request.id) }) {
            KeyringRequestHeader(lead: PhoneCopy.wants(request.agent),
                                 subject: request.login.site,
                                 detail: request.login.account.isEmpty ? nil : request.login.account,
                                 reason: request.agentReason.isEmpty ? nil : request.agentReason)
            KeyringText(PhoneCopy.askedAgo(request.askedAt), as: .caption).frame(maxWidth: .infinity)
            KeyringText(practice ? PhoneCopy.practiceLasts : PhoneCopy.lasts(request.agent), as: .caption)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    /// Direct approval started from a notification's Approve action or an in-flight send: never shows a Deny form.
    private var approvingPage: some View {
        KeyringPage(alignment: .centre, status: status ?? .waiting(PhoneCopy.approving)) {
            KeyringRequestHeader(lead: PhoneCopy.wants(request.agent),
                                 subject: request.login.site,
                                 detail: request.login.account.isEmpty ? nil : request.login.account,
                                 reason: request.agentReason.isEmpty ? nil : request.agentReason)
            KeyringText(PhoneCopy.askedAgo(request.askedAt), as: .caption).frame(maxWidth: .infinity)
        }
    }

    /// Deny and Explain: compact 2-line top summary keeps the reply box and microphone clear above the keyboard.
    private var explainPage: some View {
        KeyringPage(status: status,
                    primary: .deny(PhoneCopy.denyAndSend, isEnabled: !busy) { deny(withDraft: true) },
                    secondary: .approveLink(PhoneCopy.approveInstead, isEnabled: !busy) { approve() }) {
            KeyringHint(symbol: "key.fill", title: request.login.site, compactSummary, tone: .plain)
            KeyringText(PhoneCopy.tellTheAgent, as: .heading)
            replyBox
            if dictation.isListening { KeyringText(PhoneCopy.speakHint, as: .caption) }
        }
    }

    private var compactSummary: String {
        var parts = [PhoneCopy.who(request)]
        if !request.login.account.isEmpty { parts.append(request.login.account) }
        return parts.joined(separator: " · ")
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

    private var draftBinding: Binding<String> {
        Binding(get: { model.draft(for: request.id) },
                set: { model.setDraft($0, for: request.id) })
    }

    /// The reply box grows with the words, with the microphone: one tap to speak, one to stop.
    private var replyBox: some View {
        KeyringReplyBox(text: draftBinding, prompt: PhoneCopy.replyPrompt, note: note, noteAction: openSettings, focus: $replyFocused) {
            Button {
                let current = model.draft(for: request.id)
                if !dictation.isListening { spokenAfter = current.isEmpty ? "" : current + " " }
                replyFocused = false
                Task { await dictation.toggle() }
            } label: {
                Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
            }
            .accessibilityLabel(dictation.isListening ? PhoneCopy.stopSpeaking : PhoneCopy.speakReply)
        }
    }

    private var openSettings: KeyringAction? {
        guard case .cannotListen(.microphoneOff) = dictation.state else { return nil }
        return .link(PhoneCopy.openSettings) {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    private func deny(withDraft: Bool) {
        let targetID = request.id
        let prefix = spokenAfter
        let wasListening = dictation.isListening
        replyFocused = false
        Task {
            if wasListening {
                let spoken = await dictation.stop()
                if !spoken.isEmpty { model.setDraft(prefix + spoken, for: targetID) }
            }
            await model.deny(targetID, withDraft: withDraft)
        }
    }

    private func approve() {
        let targetID = request.id
        replyFocused = false
        Task {
            if dictation.isListening { await dictation.stop() }
            await model.approve(targetID)
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
    }
}
#endif
