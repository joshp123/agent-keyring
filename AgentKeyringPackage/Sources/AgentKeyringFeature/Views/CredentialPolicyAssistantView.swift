import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct CredentialPolicyAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var responseText = ""
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
                            credentialCount: controller.rows.count,
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
        do {
            let prompt = try assistant.prompt(for: controller.rows)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(prompt, forType: .string)
            message = .promptCopied
        } catch {
            message = .error(error.localizedDescription)
        }
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

            VStack(alignment: .leading, spacing: 5) {
                Text("Work Out Your Rules with AI")
                    .font(.title2.weight(.semibold))
                Text(
                    "Copy a prompt into the AI you already use. It will help you decide what you trust, then propose rules for your credentials. Paste the proposal here; nothing changes until you review and apply it."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(24)
    }
}

@available(macOS 26.0, *)
private struct CopyPromptStep: View {
    let credentialCount: Int
    let didCopy: Bool
    let copyPrompt: () -> Void

    var body: some View {
        AssistantStep(number: 1, title: "Copy the Prompt") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "The prompt explains the three rules, then lists \(credentialCount) random IDs, sites and current rules. The IDs do not identify your accounts, and the prompt does not include account names, usernames, passwords or verification codes."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Label(
                    "You can and should read the copied text before sharing it with the AI you choose.",
                    systemImage: "doc.text.magnifyingglass"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

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
        AssistantStep(number: 2, title: "Paste the Proposal") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "After answering the AI’s questions, paste its complete reply below. Agent Keyring checks that every credential has one valid rule, then shows each proposed change."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                    Button("Review Proposal", action: checkResponse)
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
        .padding(18)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
    }
}

@available(macOS 26.0, *)
private struct RecommendationReviewView: View {
    let review: CredentialPolicyReview
    let editResponse: () -> Void

    private var newlyAutomaticCount: Int {
        review.changes.lazy.filter { $0.proposedPolicy == .allowAutomatically }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Proposal ready to review", systemImage: "doc.text.magnifyingglass")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack(spacing: 12) {
                RecommendationCount(policy: .ask, count: review.askCount)
                RecommendationCount(policy: .allowAutomatically, count: review.automaticCount)
                RecommendationCount(policy: .block, count: review.blockedCount)
            }

            Text(
                "Agent Keyring found one valid rule for every credential. Applying this proposal will change \(review.changedCount) rules."
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            if newlyAutomaticCount > 0 {
                Label(
                    newlyAutomaticCount == 1
                        ? "1 credential will stop asking for confirmation."
                        : "\(newlyAutomaticCount) credentials will stop asking for confirmation.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            }

            if review.changes.isEmpty {
                Text("The proposal keeps every current rule.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Review every proposed change before applying it.")
                    .font(.headline)
                RecommendationChangesTable(changes: review.changes)
            }

            Button("Edit Pasted Response", action: editResponse)
                .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 14))
    }
}

@available(macOS 26.0, *)
private struct RecommendationChangesTable: View {
    let changes: [CredentialPolicyChange]

    var body: some View {
        VStack(spacing: 0) {
            RecommendationChangeColumns(
                credential: { Text("Credential") },
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
private struct RecommendationCount: View {
    let policy: CredentialAccessPolicy
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(policy.displayName, systemImage: policy.symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(policy.colour)
            Text(count, format: .number)
                .font(.title2.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 10))
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
        case .responseReady: "The proposal includes one valid rule for every credential."
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
