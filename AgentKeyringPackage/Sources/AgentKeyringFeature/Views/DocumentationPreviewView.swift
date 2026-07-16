import SwiftUI

@available(macOS 26.0, *)
public enum DocumentationScreen: String, CaseIterable, Sendable {
    case setup
    case ready
    case access
    case assistant
    case assistantReview = "assistant-review"
    case approval

    public var logicalSize: CGSize {
        switch self {
        case .setup, .ready:
            CGSize(width: 720, height: 440)
        case .access:
            CGSize(width: 960, height: 680)
        case .assistant, .assistantReview:
            CGSize(width: 720, height: 480)
        case .approval:
            CGSize(width: 520, height: 420)
        }
    }

    public var windowTitle: String {
        switch self {
        case .setup, .ready, .approval: "Agent Keyring"
        case .access, .assistant, .assistantReview: "Access Rules"
        }
    }
}

@available(macOS 26.0, *)
public struct DocumentationPreviewView: View {
    private let screen: DocumentationScreen
    private let controller: CredentialAccessController

    public init(screen: DocumentationScreen, controller: CredentialAccessController) {
        self.screen = screen
        self.controller = controller
    }

    public var body: some View {
        Group {
            switch screen {
            case .setup:
                DocumentationStatusView(status: nil, providerState: .unknown)
            case .ready:
                DocumentationStatusView(status: Self.readyStatus, providerState: .enabled)
            case .access:
                AccessControlView(controller: controller)
            case .assistant:
                CredentialPolicyAssistantView(
                    controller: controller,
                    initiallyShowsPrompt: true
                )
            case .assistantReview:
                CredentialPolicyAssistantView(
                    controller: controller,
                    initialResponse: Self.assistantResponse(for: controller.rows)
                )
            case .approval:
                DocumentationApprovalView()
            }
        }
        .frame(width: screen.logicalSize.width, height: screen.logicalSize.height)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.colorScheme, .light)
    }

    private static func assistantResponse(for rows: [AccessCredentialRow]) -> String {
        let recommendations = rows.map { row in
            let policy: CredentialAccessPolicy =
                switch row.title {
                case "Code Forge": .allowAutomatically
                case "Home Lab": .block
                default: row.policy
                }
            return CredentialPolicyRecommendation(credentialID: row.id, policy: policy)
        }
        let document = CredentialPolicyRecommendationDocument(
            recommendations: recommendations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(document)) ?? Data(), as: UTF8.self)
    }

    private static var readyStatus: SafeMirrorStatus {
        SafeMirrorStatus(
            generationID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0)),
            importedAt: Date().addingTimeInterval(-120),
            sourceExportedAt: Date().addingTimeInterval(-180),
            scope: .full,
            credentialItemCount: 522,
            addedCount: 522,
            changedCount: 0,
            removedCount: 0,
            skippedCredentialCount: 2,
            skippedCredentialSummary: MirrorSkippedCredentialSummary(passkeyCount: 2)
        )
    }
}

@available(macOS 26.0, *)
private struct DocumentationStatusView: View {
    let status: SafeMirrorStatus?
    let providerState: ProviderEnablementState

    var body: some View {
        ZStack {
            DocumentationGradient()
            VStack(spacing: 18) {
                MirrorStatusPanel(
                    status: status,
                    isLoading: false,
                    isImporting: false,
                    providerState: providerState,
                    notice: nil,
                    enableProvider: {},
                    openPasswords: {},
                    manageAccess: {}
                )
            }
            .padding(24)
        }
        .tint(.teal)
    }
}

@available(macOS 26.0, *)
private struct DocumentationApprovalView: View {
    var body: some View {
        ZStack {
            DocumentationGradient()
            CredentialReleaseApprovalView(
                request: CredentialReleaseAuthorizationRequest(
                    destination: "billing.example.com",
                    account: "alex@example.com",
                    field: .password,
                    credentialTitle: "Example invoices"
                ),
                showsProgressIndicator: false
            )
            .padding(24)
        }
        .tint(.teal)
    }
}

@available(macOS 26.0, *)
private struct DocumentationGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.93, green: 0.96, blue: 1.00),
                Color(red: 0.90, green: 0.98, blue: 0.96),
                Color(red: 0.96, green: 0.94, blue: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
