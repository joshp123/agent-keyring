import SwiftUI

@available(macOS 26.0, *)
struct PrimaryActionRow: View {
    let status: SafeMirrorStatus?
    let isLoading: Bool
    let isImporting: Bool
    let providerState: ProviderEnablementState
    let enableProvider: () -> Void
    let openPasswords: () -> Void
    let manageAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading || isImporting || providerState == .requesting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progressLabel)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    Button(action: primaryAction) {
                        Label(primaryLabel, systemImage: primarySymbol)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(providerState == .denied && status == nil ? .orange : .accentColor)
                    .keyboardShortcut(.defaultAction)

                    if status != nil {
                        Button(action: manageAccess) {
                            Label("Agent access rules…", systemImage: "person.badge.key")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }

                if status != nil || providerState == .enabled {
                    PasswordsImportInstructions()
                } else {
                    Text(actionHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var progressLabel: String {
        if isLoading { return "Checking the encrypted mirror…" }
        if isImporting { return "Encrypting the new snapshot…" }
        return "Asking macOS to enable the extension…"
    }

    private var primaryLabel: String {
        if status != nil { return "Open Passwords" }
        if providerState == .enabled { return "Open Passwords" }
        if providerState == .denied { return "Retry after profile setup" }
        return "Enable secure import"
    }

    private var primarySymbol: String {
        if status != nil { return "arrow.up.forward.app" }
        if providerState == .enabled { return "arrow.up.forward.app" }
        if providerState == .denied { return "arrow.clockwise" }
        return "checkmark.shield"
    }

    private var actionHint: String {
        if providerState == .denied {
            return "Agent Keyring needs an eligible Apple Developer Program profile before macOS can enable credential import."
        }
        return "This enables Agent Keyring as an export destination. It does not read any passwords."
    }

    private var primaryAction: () -> Void {
        if status != nil || providerState == .enabled {
            openPasswords
        } else {
            enableProvider
        }
    }
}

@available(macOS 26.0, *)
private struct PasswordsImportInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Import changes from Apple Passwords:")
                .font(.callout.weight(.semibold))
            Text("1. Open Passwords.")
            Text("2. Choose File → Export All Items to App.")
            Text("3. Select Agent Keyring and approve the export.")
            Text("New, changed and removed credentials will update Agent Keyring’s encrypted copy.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@available(macOS 26.0, *)
struct MirrorNoticeRow: View {
    let notice: MirrorNotice

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(symbolColour)
            Text(notice.text)
                .foregroundStyle(textColour)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(symbolColour.opacity(0.07), in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("mirror-message")
    }

    private var symbol: String {
        switch notice.kind {
        case .information:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        }
    }

    private var symbolColour: Color {
        switch notice.kind {
        case .information:
            .green
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private var textColour: Color {
        notice.kind == .information ? .secondary : symbolColour
    }
}
