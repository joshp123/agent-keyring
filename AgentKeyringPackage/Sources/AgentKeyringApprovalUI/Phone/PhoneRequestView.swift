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
    @FocusState private var replyFocused: Bool

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
    }

    private var answers: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField(PhoneCopy.replyPlaceholder(request.agent), text: $model.replyDraft, axis: .vertical)
                        .font(.subheadline)
                        .foregroundStyle(Phone.ink)
                        .lineLimit(1...4)
                        .focused($replyFocused)
                        .submitLabel(.send)
                    // iOS's own dictation is on the keyboard; the microphone here opens it.
                    Image(systemName: "mic.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Phone.ink)
                        .accessibilityHidden(true)
                }
                // Paper has 16; 14 keeps "What should Codex do instead?" on one line beside Deny.
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(Phone.fill, in: .capsule)
                .contentShape(.capsule)
                .onTapGesture { replyFocused = true }

                Button(PhoneCopy.deny) { Task { await model.deny(request.id) } }
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
                Text(PhoneCopy.lasts(request.agent))
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
