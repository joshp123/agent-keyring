import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct CredentialPolicyAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var responseText = ""
    @State private var promptText = ""
    @State private var review: CredentialPolicyReview?
    @State private var message: AssistantMessage?
    @State private var isApplying = false
    private let controller: CredentialAccessController
    private let assistant = CredentialPolicyAssistant()

    init(
        controller: CredentialAccessController,
        initialResponse: String = ""
    ) {
        self.controller = controller
        _responseText = State(initialValue: initialResponse)
        _promptText = State(
            initialValue: (try? CredentialPolicyAssistant().prompt(for: controller.rows)) ?? ""
        )
        let initialReview = try? CredentialPolicyAssistant().review(
            response: initialResponse,
            against: controller.rows
        )
        _review = State(initialValue: initialReview)
        _message = State(initialValue: initialReview == nil ? nil : .responseReady)
    }

    var body: some View {
        VStack(spacing: 0) {
            AssistantHeader()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let review {
                        RecommendationReviewView(
                            review: review,
                            editResponse: {
                                self.review = nil
                                message = nil
                            }
                        )
                    } else {
                        CopyPromptStep(
                            prompt: promptText,
                            didCopy: message == .promptCopied,
                            copyPrompt: copyPrompt
                        )
                        PasteResponseStep(
                            responseText: $responseText,
                            pasteResponse: pasteResponse,
                            checkResponse: checkResponse
                        )
                    }

                    if let message, case .error = message {
                        AssistantMessageRow(message: message)
                    }
                }
                .padding(24)
            }

            Divider()
            AssistantFooter(
                canApply: review != nil,
                isApplying: isApplying,
                cancel: { dismiss() },
                apply: applyRecommendations
            )
        }
        .frame(width: 780, height: 680)
        .interactiveDismissDisabled(isApplying)
        .onChange(of: responseText) {
            if review == nil, message != .promptCopied {
                message = nil
            }
        }
    }

    private func copyPrompt() {
        guard !promptText.isEmpty else {
            message = .error("The prompt could not be created.")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(promptText, forType: .string)
        message = .promptCopied
    }

    private func pasteResponse() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            message = .error("The Clipboard does not contain an AI proposal.")
            return
        }
        responseText = value
    }

    private func checkResponse() {
        do {
            review = try assistant.review(response: responseText, against: controller.rows)
            message = .responseReady
        } catch {
            review = nil
            message = .error(error.localizedDescription)
        }
    }

    private func applyRecommendations() {
        guard let review else { return }
        isApplying = true
        Task {
            await controller.setPolicies(review.assignments)
            isApplying = false
            if let errorMessage = controller.errorMessage {
                message = .error(errorMessage)
            } else {
                dismiss()
            }
        }
    }
}

@available(macOS 26.0, *)
private struct AssistantHeader: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading) {
                Text("Set Rules with AI")
                    .font(.title2.weight(.semibold))
            }
            Spacer()
        }
        .padding(24)
    }
}

@available(macOS 26.0, *)
private struct CopyPromptStep: View {
    @State private var isShowingPrompt = false
    let prompt: String
    let didCopy: Bool
    let copyPrompt: () -> Void

    var body: some View {
        AssistantStep(number: 1, title: "Copy the Prompt") {
            VStack(alignment: .leading, spacing: 12) {
                DisclosureGroup("Preview Prompt", isExpanded: $isShowingPrompt) {
                    ScrollView {
                        Text(prompt)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(height: 160)
                    .background(.background, in: .rect(cornerRadius: 8))
                }

                Button(action: copyPrompt) {
                    Label(
                        didCopy ? "Prompt Copied" : "Copy Prompt",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct PasteResponseStep: View {
    @Binding var responseText: String
    let pasteResponse: () -> Void
    let checkResponse: () -> Void

    var body: some View {
        AssistantStep(number: 2, title: "Paste the Result") {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $responseText)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 150)
                    .padding(6)
                    .background(.background, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }

                HStack {
                    Button("Paste from Clipboard", action: pasteResponse)
                    Spacer()
                    Button("Review Changes", action: checkResponse)
                        .disabled(
                            responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

@available(macOS 26.0, *)
private struct AssistantStep<Content: View>: View {
    let number: Int
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number, format: .number)
                .font(.callout.weight(.bold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.16), in: Circle())

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@available(macOS 26.0, *)
private struct RecommendationReviewView: View {
    let review: CredentialPolicyReview
    let editResponse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(reviewTitle, systemImage: "doc.text.magnifyingglass")
                .font(.headline)
                .foregroundStyle(.primary)

            if review.changes.isEmpty {
                Text("No rules will change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                RecommendationChangesTable(changes: review.changes)
            }

            Button("Edit Response", action: editResponse)
                .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
    }

    private var reviewTitle: String {
        review.changedCount == 1 ? "1 Change" : "\(review.changedCount) Changes"
    }
}

@available(macOS 26.0, *)
private struct RecommendationChangesTable: View {
    let changes: [CredentialPolicyChange]

    var body: some View {
        VStack(spacing: 0) {
            RecommendationChangeColumns(
                credential: { Text("Login") },
                current: { Text("Current") },
                proposed: { Text("Proposed") }
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.35))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(changes) { change in
                        RecommendationChangeColumns(
                            credential: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.title)
                                        .font(.body.weight(.medium))
                                    Text(change.account)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    if change.website != change.title {
                                        Text(change.website)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .lineLimit(1)
                                .help("\(change.title)\n\(change.account)\n\(change.website)")
                            },
                            current: { PolicyLabel(policy: change.currentPolicy) },
                            proposed: { PolicyLabel(policy: change.proposedPolicy) }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            change.proposedPolicy == .allowAutomatically
                                && change.currentPolicy != .allowAutomatically
                                ? Color.orange.opacity(0.08) : .clear
                        )

                        Divider()
                    }
                }
            }
        }
        .background(.background, in: .rect(cornerRadius: 8))
        .frame(height: min(CGFloat(changes.count * 74 + 40), 300))
    }
}

@available(macOS 26.0, *)
private struct RecommendationChangeColumns<Credential: View, Current: View, Proposed: View>:
    View
{
    @ViewBuilder let credential: Credential
    @ViewBuilder let current: Current
    @ViewBuilder let proposed: Proposed

    var body: some View {
        HStack(spacing: 16) {
            credential.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
            current.frame(width: 150, alignment: .leading)
            proposed.frame(width: 170, alignment: .leading)
        }
    }
}

@available(macOS 26.0, *)
private struct PolicyLabel: View {
    let policy: CredentialAccessPolicy

    var body: some View {
        Label(policy.displayName, systemImage: policy.symbol)
            .foregroundStyle(policy.colour)
            .lineLimit(1)
    }
}

@available(macOS 26.0, *)
private struct AssistantMessageRow: View {
    let message: AssistantMessage

    var body: some View {
        Label(message.text, systemImage: message.symbol)
            .font(.callout)
            .foregroundStyle(message.colour)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(message.colour.opacity(0.08), in: .rect(cornerRadius: 10))
    }
}

@available(macOS 26.0, *)
private struct AssistantFooter: View {
    let canApply: Bool
    let isApplying: Bool
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        HStack {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if isApplying {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Apply Changes", action: apply)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || isApplying)
        }
        .padding(16)
    }
}

@available(macOS 26.0, *)
private enum AssistantMessage: Equatable {
    case promptCopied
    case responseReady
    case error(String)

    var text: String {
        switch self {
        case .promptCopied:
            "Prompt copied. Read it, then paste it into ChatGPT, Claude or another AI."
        case .responseReady: "Ready to review."
        case let .error(text): text
        }
    }

    var symbol: String {
        switch self {
        case .promptCopied, .responseReady: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var colour: Color {
        switch self {
        case .promptCopied, .responseReady: .green
        case .error: .red
        }
    }
}
