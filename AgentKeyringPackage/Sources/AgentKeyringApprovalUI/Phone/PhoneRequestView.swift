// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// One request inside the app (Paper, "The request", "After a tap"). The
// answers stay under the thumb: a box for words to the agent with Deny
// beside it, and Approve with Face ID below.

#if os(iOS)
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
        VStack(spacing: 0) {
            PhoneRequestHeader(agent: request.agent)
                .padding(.top, 14)
            PhoneRequestBody(request: request)
                .frame(maxHeight: .infinity)
                .padding(.bottom, 40)
                .contentShape(.rect)
                .onTapGesture { replyFocused = false }
            answers
        }
        .padding(.horizontal, 22)
        .padding(.bottom, replyFocused ? 12 : 44)
        .background(Phone.surface)
        .ignoresSafeArea(.container, edges: .bottom)
        .alert(PhoneCopy.answerFailed, isPresented: failureShown) {
            Button(PhoneCopy.ok) { model.dismissFailure() }
        }
        .sensoryFeedback(.selection, trigger: model.answering)
        .onChange(of: dictation.heard) { _, heard in if dictation.isListening { model.replyDraft = spokenAfter + heard } }
        .onDisappear { Task { await dictation.stop() } }
    }

    private var answers: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("", text: $model.replyDraft, axis: .vertical)
                        .font(.subheadline)
                        .foregroundStyle(Phone.ink)
                        .lineLimit(1...4)
                        .focused($replyFocused)
                        .submitLabel(.send)
                        .accessibilityLabel(PhoneCopy.replyPlaceholder(request.agent))
                        .background(alignment: .leading) {
                            if model.replyDraft.isEmpty {
                                // The whole sentence, never cut off: the agent's name if it fits, else "it".
                                ViewThatFits(in: .horizontal) {
                                    Text(PhoneCopy.replyPlaceholder(request.agent))
                                    Text(PhoneCopy.replyPlaceholderShort)
                                }
                                .font(.subheadline).foregroundStyle(Phone.ink2).lineLimit(1)
                                .allowsHitTesting(false)
                            }
                        }
                    // One tap to speak, one to stop. If it can't listen, the keyboard opens, with its own dictation key.
                    Button {
                        if !dictation.isListening { spokenAfter = model.replyDraft.isEmpty ? "" : model.replyDraft + " " }
                        replyFocused = false
                        Task {
                            await dictation.toggle()
                            if dictation.state == .unavailable { replyFocused = true }
                        }
                    } label: {
                        Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(dictation.isListening ? Phone.deny : Phone.ink)
                    }
                    .accessibilityLabel(dictation.isListening ? PhoneCopy.stopSpeaking : PhoneCopy.speakReply)
                }
                // Paper has 16; 14 keeps "What should Codex do instead?" on one line beside Deny.
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(Phone.fill, in: .capsule)
                .contentShape(.capsule)
                .onTapGesture { replyFocused = true }

                Button(PhoneCopy.deny) { Task { if dictation.isListening { await dictation.stop() }; await model.deny(request.id) } }
                    .buttonStyle(PillButtonStyle(fill: Phone.deny, height: 50, stretches: false))
                    .fixedSize()
            }
            Button {
                replyFocused = false
                Task { await model.approve(request.id) }
            } label: {
                Label(PhoneCopy.approveWithFaceID, systemImage: "faceid")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PillButtonStyle(fill: Phone.approve))
            if !replyFocused {
                Text(practice ? PhoneCopy.practiceLasts : PhoneCopy.lasts(request.agent))
                    .font(.footnote).foregroundStyle(Phone.ink2)
                    .multilineTextAlignment(.center)
            }
        }
        .disabled(model.answering != nil)
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failure != nil }, set: { if !$0 { model.dismissFailure() } })
    }
}
#endif
