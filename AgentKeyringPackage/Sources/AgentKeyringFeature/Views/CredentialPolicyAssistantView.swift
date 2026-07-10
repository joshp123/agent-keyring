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

    init(controller: CredentialAccessController) {
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            AssistantHeader()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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

                    if let review {
                        RecommendationReviewView(review: review)
                    }

                    if let message, message != .promptCopied {
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
        .frame(width: 700, height: 680)
        .interactiveDismissDisabled(isApplying)
        .onChange(of: responseText) {
            review = nil
            if message != .promptCopied {
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
            message = .error("The pasteboard does not contain a model response.")
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
                .foregroundStyle(.purple)
                .frame(width: 46, height: 46)
                .background(.purple.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("Let AI sort your credentials")
                    .font(.title2.weight(.semibold))
                Text(
                    "Copy a prompt to your preferred model. It will ask about your needs before recommending access rules."
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
        AssistantStep(number: 1, title: "Ask a model to choose") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "The prompt lists \(credentialCount) credential IDs, titles, websites and account labels. It never includes passwords, seeds or verification codes."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Label(
                    "Pasting the prompt shares that metadata with the model you choose.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.orange)

                Button(action: copyPrompt) {
                    Label(
                        didCopy ? "Prompt copied" : "Copy prompt",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
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
        AssistantStep(number: 2, title: "Bring back its recommendations") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Finish the model's questions, then paste its final response here. Agent Keyring checks every ID before changing anything."
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
                    Button("Paste model response", action: pasteResponse)
                    Spacer()
                    Button("Check recommendations", action: checkResponse)
                        .buttonStyle(.borderedProminent)
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
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.purple, in: Circle())

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

    private var newlyAutomaticCount: Int {
        review.changes.lazy.filter { $0.proposedPolicy == .allowAutomatically }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recommendations checked", systemImage: "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.green)

            HStack(spacing: 12) {
                RecommendationCount(policy: .ask, count: review.askCount)
                RecommendationCount(policy: .allowAutomatically, count: review.automaticCount)
                RecommendationCount(policy: .block, count: review.blockedCount)
            }

            Text("Applying this response will change \(review.changedCount) access rules.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if newlyAutomaticCount > 0 {
                Label(
                    "\(newlyAutomaticCount) credentials will stop asking for confirmation.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            }

            if review.changes.isEmpty {
                Text("The model recommends keeping every current rule.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Review every proposed change before applying it.")
                    .font(.headline)
                RecommendationChangesTable(changes: review.changes)
            }
        }
        .padding(18)
        .background(.green.opacity(0.07), in: .rect(cornerRadius: 14))
    }
}

@available(macOS 26.0, *)
private struct RecommendationChangesTable: View {
    let changes: [CredentialPolicyChange]

    var body: some View {
        Table(changes) {
            TableColumn("Credential") { change in
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(change.account)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("\(change.title)\n\(change.account)\n\(change.website)")
            }
            .width(min: 220, ideal: 280)

            TableColumn("Current") { change in
                PolicyLabel(policy: change.currentPolicy)
            }
            .width(min: 120, ideal: 140)

            TableColumn("Proposed") { change in
                PolicyLabel(policy: change.proposedPolicy)
            }
            .width(min: 130, ideal: 160)
        }
        .frame(height: min(CGFloat(changes.count * 44 + 34), 260))
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
            Button("Apply recommendations", action: apply)
                .buttonStyle(.borderedProminent)
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
        case .promptCopied: "Prompt copied. Paste it into your preferred model."
        case .responseReady: "Every mirrored credential has one valid recommendation."
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
