// Written by AI on 2026.11.18 by model Claude Opus 5.5; unified on 2026.11.26
// by model gemini-4-neon with KeyringUnifiedApprovalCard across Decide, Explain,
// Approving, and read-only Settled inspection states.

#if os(iOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import SwiftUI

struct PhoneRequestView: View {
    @Bindable var model: PhoneModel
    let request: AccessRequest
    var mode: PhoneSheetMode = .decide
    var practice = false
    @FocusState private var replyFocused: Bool
    @State private var dictation = PhoneDictation()
    @State private var spokenAfter = ""

    private enum SubmissionState: Equatable {
        case idle
        case stoppingDictation
        case submitted(id: String, mode: PhoneSheetMode, draft: String?)
    }

    @State private var dictationRequestID: String?
    @State private var submission: SubmissionState = .idle

    private var effectiveMode: PhoneSheetMode {
        if case let .submitted(id, submittedMode, _) = submission, id == request.id {
            return submittedMode
        }
        return mode
    }

    var body: some View {
        Group {
            switch effectiveMode {
            case .decide: decidePage
            case .approving: approvingPage
            case .explain: explainPage
            case .settled: settledPage
            }
        }
        .navigationTitle(effectiveMode == .settled ? "Activity Detail" : "Password Request")
        .navigationBarTitleDisplayMode(.inline)
        .alert(model.failure ?? PhoneCopy.answerFailed, isPresented: failureShown) { Button(PhoneCopy.ok) { model.dismissFailure() } }
        .sensoryFeedback(.selection, trigger: model.answering)
        .onChange(of: dictation.heard) { _, heard in
            if dictation.isListening, dictationRequestID == request.id {
                model.setDraft(spokenAfter + heard, for: request.id)
            }
        }
        .onChange(of: request.id) { _, _ in
            dictationRequestID = nil
            submission = .idle
            replyFocused = (mode == .explain)
            spokenAfter = ""
            Task { await dictation.stop() }
        }
        .onChange(of: mode) { _, next in
            if case let .submitted(id, _, _) = submission, id == request.id { return }
            if next == .explain {
                replyFocused = true
            } else {
                dictationRequestID = nil
                replyFocused = false
                spokenAfter = ""
                Task { await dictation.stop() }
            }
        }
        .onDisappear {
            dictationRequestID = nil
            Task { await dictation.stop() }
        }
        .onAppear { if mode == .explain { replyFocused = true } }
    }

    private var busy: Bool {
        if model.answering != nil || effectiveMode == .approving { return true }
        switch submission {
        case .idle: return false
        case .stoppingDictation: return true
        case let .submitted(id, _, _): return id == request.id
        }
    }

    private var machineLabel: String {
        request.agent.isLocal ? "This Mac" : request.agent.machine
    }

    /// Unified Decide card: identical anatomy to Mac Float, Mac Menu Bar, and iPhone Activity.
    private var decidePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KeyringSpace.s4) {
                KeyringUnifiedApprovalCard(
                    site: request.login.site,
                    account: request.login.account.isEmpty ? nil : request.login.account,
                    agent: practice ? "Practice" : request.agent.name,
                    machine: practice ? "" : machineLabel,
                    reason: request.agentReason.isEmpty ? nil : request.agentReason,
                    footer: practice ? PhoneCopy.practiceLasts : nil,
                    showBrandBar: false,
                    compact: false,
                    approve: .approve(PhoneCopy.approveWithFaceID, symbol: "faceid", isEnabled: !busy) { approve() },
                    deny: .deny(PhoneCopy.deny, isEnabled: !busy) { deny(withDraft: false) },
                    denyAndReply: .denySecondary(PhoneCopy.denyAndExplain, isEnabled: !busy) { model.explain(request.id) },
                    busy: busy
                ) {
                    SiteIconView(host: request.login.site, size: 30)
                }
                .padding(KeyringSpace.s4)
                .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))

                if let status {
                    KeyringStatusLine(status)
                }
            }
            .padding(KeyringSpace.s4)
        }
        .background(KeyringPalette.canvas)
    }

    /// Direct approval started from a Lock Screen notification's Approve action or in-flight Face ID.
    private var approvingPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KeyringSpace.s4) {
                requestSummaryCard
                KeyringStatusLine(status ?? .waiting(PhoneCopy.approving))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, KeyringSpace.s2)
            }
            .padding(KeyringSpace.s4)
        }
        .background(KeyringPalette.canvas)
    }

    /// Deny & Reply: identical header + quoted reason well above the reply field + mic + Cancel / Deny & Send.
    private var explainPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KeyringSpace.s4) {
                VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                    twoSidedHeader
                    if !request.agentReason.isEmpty {
                        KeyringText(PhoneCopy.quoted(request.agentReason), as: .body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, KeyringSpace.s3)
                            .padding(.vertical, KeyringSpace.s2 + 2)
                            .background(KeyringPalette.fill, in: .rect(cornerRadius: 10, style: .continuous))
                    }
                    replyBox
                    if dictation.isListening {
                        KeyringText(PhoneCopy.speakHint, as: .caption)
                    }
                    HStack(spacing: KeyringSpace.s2) {
                        KeyringButton(.plain(PhoneCopy.cancel, isEnabled: !busy) {
                            if model.sheet.canReturnToDecide {
                                model.backToDecide()
                            } else {
                                model.dismissSheet()
                            }
                        })
                        KeyringButton(.deny(PhoneCopy.denyAndSend, isEnabled: !busy) { deny(withDraft: true) })
                    }
                    .environment(\.keyringButtonsFill, true)
                    .environment(\.keyringButtonTall, true)
                }
                .padding(KeyringSpace.s4)
                .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))

                if let status {
                    KeyringStatusLine(status)
                }
            }
            .padding(KeyringSpace.s4)
        }
        .background(KeyringPalette.canvas)
    }

    /// Settled read-only inspection (opened by tapping a settled 2-line Activity row's chevron):
    /// reuses the exact same request card layout to reveal full host, account, reason, outcome, and any denial reply.
    private var settledPage: some View {
        let outcome = PhoneHomeView.outcomeStyle(request)
        return ScrollView {
            VStack(alignment: .leading, spacing: KeyringSpace.s4) {
                VStack(alignment: .leading, spacing: KeyringSpace.s3) {
                    twoSidedHeader

                    if !request.agentReason.isEmpty {
                        KeyringText(PhoneCopy.quoted(request.agentReason), as: .body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, KeyringSpace.s3)
                            .padding(.vertical, KeyringSpace.s2 + 2)
                            .background(KeyringPalette.fill, in: .rect(cornerRadius: 10, style: .continuous))
                    }

                    HStack {
                        KeyringOutcomeBadge(outcome)
                        Spacer(minLength: 0)
                        KeyringText(AccessRequestCopy.clock(request.askedAt), as: .meta)
                            .monospacedDigit()
                    }
                    .padding(.top, 2)

                    if let reply = request.state.reply, !reply.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 2) {
                            KeyringText("YOUR REPLY", as: .sectionName)
                            KeyringText(reply, as: .body, colour: KeyringPalette.denyText)
                        }
                    }
                }
                .padding(KeyringSpace.s4)
                .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
            }
            .padding(KeyringSpace.s4)
        }
        .background(KeyringPalette.canvas)
    }

    private var requestSummaryCard: some View {
        VStack(alignment: .leading, spacing: KeyringSpace.s3) {
            twoSidedHeader
            if !request.agentReason.isEmpty {
                KeyringText(PhoneCopy.quoted(request.agentReason), as: .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, KeyringSpace.s3)
                    .padding(.vertical, KeyringSpace.s2 + 2)
                    .background(KeyringPalette.fill, in: .rect(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(KeyringSpace.s4)
        .background(KeyringPalette.surface, in: .rect(cornerRadius: KeyringRadius.card, style: .continuous))
    }

    private var twoSidedHeader: some View {
        HStack(alignment: .top, spacing: KeyringSpace.s3) {
            SiteIconView(host: request.login.site, size: 30)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                KeyringText(request.login.site, as: .heading, fit: .siteName)
                if !request.login.account.isEmpty {
                    KeyringText(request.login.account, as: .meta)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                KeyringText(practice ? "Practice" : request.agent.name, as: .meta, colour: KeyringPalette.ink)
                    .lineLimit(1)
                if !practice && !machineLabel.isEmpty {
                    KeyringText(machineLabel, as: .meta, colour: KeyringPalette.ink2)
                        .lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var status: KeyringStatus? {
        model.snapshot.undelivered.contains(request.id) ? .takingLong(PhoneCopy.notDeliveredYet) : nil
    }

    private var note: KeyringStatus? {
        switch dictation.state {
        case .listening: .listening(PhoneCopy.listening)
        case .starting, .idle: nil
        case let .cannotListen(.gettingReady(percent)): .waiting(PhoneCopy.cannotListen(.gettingReady(percent: percent)))
        case let .cannotListen(reason): .problem(PhoneCopy.cannotListen(reason))
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: {
                if case let .submitted(id, _, draft?) = submission, id == request.id { return draft }
                return model.draft(for: request.id)
            },
            set: {
                if case let .submitted(id, _, _) = submission, id == request.id { return }
                model.setDraft($0, for: request.id)
            }
        )
    }

    private var replyBox: some View {
        KeyringReplyBox(text: draftBinding, prompt: PhoneCopy.replyPrompt, note: note, noteAction: openSettings, focus: $replyFocused) {
            Button {
                let current = model.draft(for: request.id)
                if !dictation.isActive {
                    spokenAfter = current.isEmpty ? "" : current + " "
                    dictationRequestID = request.id
                } else {
                    dictationRequestID = nil
                }
                replyFocused = false
                Task { await dictation.toggle() }
            } label: {
                Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                    .foregroundStyle(KeyringPalette.brand)
            }
            .disabled(busy)
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
        guard !busy else { return }
        let targetID = request.id
        let prefix = spokenAfter
        let wasListening = dictation.isListening && dictationRequestID == targetID
        let wasActive = dictation.isActive
        dictationRequestID = nil
        replyFocused = false
        submission = .stoppingDictation
        Task {
            if wasListening {
                let spoken = await dictation.stop()
                if !spoken.isEmpty { model.setDraft(prefix + spoken, for: targetID) }
            } else if wasActive {
                await dictation.stop()
            }
            submission = .submitted(id: targetID, mode: mode, draft: model.draft(for: targetID))
            await model.denyAccessRequest(targetID, withDraft: withDraft)
            if model.sheet.requestID == targetID {
                submission = .idle
            }
        }
    }

    private func approve() {
        guard !busy else { return }
        let targetID = request.id
        let wasActive = dictation.isActive
        dictationRequestID = nil
        replyFocused = false
        submission = .stoppingDictation
        Task {
            if wasActive { await dictation.stop() }
            submission = .submitted(id: targetID, mode: .approving, draft: nil)
            await model.approveAccessRequest(targetID)
            if model.sheet.requestID == targetID {
                submission = .idle
            }
        }
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
    }
}
#endif
