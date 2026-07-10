import SwiftUI

@available(macOS 26.0, *)
public enum DocumentationScreen: String, CaseIterable, Sendable {
    case setup
    case ready
    case access
    case assistant
    case approval

    public var logicalSize: CGSize {
        switch self {
        case .setup, .ready:
            CGSize(width: 828, height: 572)
        case .access:
            CGSize(width: 1_008, height: 728)
        case .assistant:
            CGSize(width: 748, height: 728)
        case .approval:
            CGSize(width: 668, height: 620)
        }
    }

    var windowTitle: LocalizedStringResource {
        switch self {
        case .setup, .ready, .approval: "Agent Keyring"
        case .access, .assistant: "Credential access"
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
        DocumentationWindow(title: screen.windowTitle) {
            switch screen {
            case .setup:
                DocumentationStatusView(status: nil, providerState: .unknown)
            case .ready:
                DocumentationStatusView(status: Self.readyStatus, providerState: .enabled)
            case .access:
                DocumentationAccessView(
                    rows: controller.visibleRows,
                    askCount: controller.count(for: .ask),
                    automaticCount: controller.count(for: .allowAutomatically),
                    blockedCount: controller.count(for: .block)
                )
            case .assistant:
                CredentialPolicyAssistantView(controller: controller)
            case .approval:
                DocumentationApprovalView()
            }
        }
        .frame(width: screen.logicalSize.width, height: screen.logicalSize.height)
        .environment(\.locale, Locale(identifier: "en_GB"))
        .environment(\.colorScheme, .light)
    }

    private static var readyStatus: SafeMirrorStatus {
        SafeMirrorStatus(
            generationID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0)),
            importedAt: Date().addingTimeInterval(-120),
            sourceExportedAt: Date().addingTimeInterval(-180),
            scope: .full,
            credentialItemCount: 8,
            addedCount: 8,
            changedCount: 0,
            removedCount: 0,
            skippedCredentialCount: 2,
            skippedCredentialSummary: MirrorSkippedCredentialSummary(passkeyCount: 2)
        )
    }
}

@available(macOS 26.0, *)
private struct DocumentationWindow<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            DocumentationTitleBar(title: title)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.black.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .padding(24)
        .background(Color(red: 0.93, green: 0.95, blue: 0.98))
    }
}

@available(macOS 26.0, *)
private struct DocumentationTitleBar: View {
    let title: LocalizedStringResource

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red.opacity(0.85)).frame(width: 12, height: 12)
            Circle().fill(.yellow.opacity(0.90)).frame(width: 12, height: 12)
            Circle().fill(.green.opacity(0.85)).frame(width: 12, height: 12)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            Spacer()
        }
        .frame(height: 38)
        .padding(.horizontal, 14)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
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
                DocumentationSecurityFooter()
            }
            .padding(32)
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
                    destination: "accounts.example.com",
                    account: "alex@example.com",
                    field: .password,
                    credentialTitle: "Example account"
                )
            )
            .padding(32)
        }
        .tint(.teal)
    }
}

@available(macOS 26.0, *)
private struct DocumentationAccessView: View {
    let rows: [AccessCredentialRow]
    let askCount: Int
    let automaticCount: Int
    let blockedCount: Int

    var body: some View {
        HStack(spacing: 0) {
            DocumentationAccessSidebar(
                askCount: askCount,
                automaticCount: automaticCount,
                blockedCount: blockedCount
            )
            Divider()
            DocumentationAccessDetail(rows: rows)
        }
        .background(.background)
    }
}

@available(macOS 26.0, *)
private struct DocumentationAccessSidebar: View {
    let askCount: Int
    let automaticCount: Int
    let blockedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Access groups")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 16)

            DocumentationAccessSidebarRow(
                policy: .ask,
                count: askCount,
                isSelected: true
            )
            DocumentationAccessSidebarRow(
                policy: .allowAutomatically,
                count: automaticCount,
                isSelected: false
            )
            DocumentationAccessSidebarRow(
                policy: .block,
                count: blockedCount,
                isSelected: false
            )

            Spacer()

            Button(action: {}) {
                Label("Let AI choose…", systemImage: "sparkles")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .padding(14)
        }
        .frame(width: 250)
        .background(.regularMaterial)
    }
}

@available(macOS 26.0, *)
private struct DocumentationAccessSidebarRow: View {
    let policy: CredentialAccessPolicy
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: policy.symbol)
                .foregroundStyle(policy.colour)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(policy.displayName)
                Text(policy.sidebarDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(count, format: .number)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            isSelected ? policy.colour.opacity(0.12) : .clear,
            in: .rect(cornerRadius: 8)
        )
        .padding(.horizontal, 8)
    }
}

@available(macOS 26.0, *)
private struct DocumentationAccessDetail: View {
    let rows: [AccessCredentialRow]

    var body: some View {
        VStack(spacing: 0) {
            DocumentationAccessHeader(count: rows.count)
            Divider()
            DocumentationAccessTable(rows: rows)
        }
    }
}

@available(macOS 26.0, *)
private struct DocumentationAccessHeader: View {
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: CredentialAccessPolicy.ask.symbol)
                .font(.title2)
                .foregroundStyle(CredentialAccessPolicy.ask.colour)
                .frame(width: 44, height: 44)
                .background(CredentialAccessPolicy.ask.colour.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(CredentialAccessPolicy.ask.displayName)
                    .font(.title2.weight(.semibold))
                Text(CredentialAccessPolicy.ask.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("\(count) credentials")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CredentialAccessPolicy.ask.colour)
            }
            Spacer()
            Label("Search this group", systemImage: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.quaternary, in: Capsule())
        }
        .padding(24)
    }
}

@available(macOS 26.0, *)
private struct DocumentationAccessTable: View {
    let rows: [AccessCredentialRow]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Credential").frame(maxWidth: .infinity, alignment: .leading)
                Text("Website").frame(width: 240, alignment: .leading)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(.quaternary.opacity(0.45))

            ForEach(rows) { row in
                DocumentationAccessTableRow(
                    title: row.title,
                    account: row.account,
                    website: row.website
                )
                Divider().padding(.leading, 18)
            }
            Spacer()
        }
    }
}

@available(macOS 26.0, *)
private struct DocumentationAccessTableRow: View {
    let title: String
    let account: String
    let website: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(account).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(website)
                .frame(width: 240, alignment: .leading)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }
}

@available(macOS 26.0, *)
private struct DocumentationSecurityFooter: View {
    var body: some View {
        HStack(spacing: 14) {
            Label("Encrypted locally", systemImage: "lock.fill")
            Divider().frame(height: 12)
            Label("Apple Passwords stays primary", systemImage: "key.fill")
            Spacer()
            Label("Passkeys stay in Passwords", systemImage: "person.badge.key.fill")
        }
        .font(.callout)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
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
