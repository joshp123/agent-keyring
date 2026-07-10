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
        HStack(spacing: 14) {
            if isLoading || isImporting || providerState == .requesting {
                ProgressView()
                    .controlSize(.small)
                Text(progressLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button(action: primaryAction) {
                    Label(primaryLabel, systemImage: primarySymbol)
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(providerState == .denied && status == nil ? .orange : .teal)
                .keyboardShortcut(.defaultAction)

                if status != nil {
                    Button(action: manageAccess) {
                        Label("Manage access", systemImage: "person.badge.key")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(actionHintTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(actionHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var progressLabel: String {
        if isLoading { return "Checking the encrypted mirror…" }
        if isImporting { return "Encrypting the new snapshot…" }
        return "Asking macOS to enable the extension…"
    }

    private var primaryLabel: String {
        if status != nil { return "Refresh mirror" }
        if providerState == .enabled { return "Open Passwords" }
        if providerState == .denied { return "Retry after profile setup" }
        return "Enable secure import"
    }

    private var primarySymbol: String {
        if status != nil { return "arrow.clockwise" }
        if providerState == .enabled { return "arrow.up.forward.app" }
        if providerState == .denied { return "arrow.clockwise" }
        return "checkmark.shield"
    }

    private var actionHintTitle: String {
        if status != nil || providerState == .enabled {
            return "Opens Apple Passwords"
        }
        if providerState == .denied {
            return "Developer profile required"
        }
        return "One-time macOS setting"
    }

    private var actionHint: String {
        if status != nil || providerState == .enabled {
            return "Use File → Export All Items to App in Apple Passwords."
        }
        if providerState == .denied {
            return "Use an eligible Apple Developer Program team."
        }
        return "No passwords are read when you enable it."
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
