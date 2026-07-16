import SwiftUI

@available(macOS 26.0, *)
struct PrimaryActionRow: View {
    @State private var isShowingUpdateHelp = false
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
                actions

                if status == nil, providerState == .enabled {
                    PasswordsImportInstructions()
                } else if status == nil {
                    Text(actionHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        if status != nil {
            HStack(spacing: 10) {
                Button(action: manageAccess) {
                    Label("Access Rules…", systemImage: "person.badge.key")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button {
                    isShowingUpdateHelp = true
                } label: {
                    Label("Update…", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .popover(isPresented: $isShowingUpdateHelp, arrowEdge: .bottom) {
                    UpdateHelp(openPasswords: {
                        isShowingUpdateHelp = false
                        openPasswords()
                    })
                }
            }
        } else {
            Button(action: primaryAction) {
                Label(primaryLabel, systemImage: primarySymbol)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(providerState == .denied ? .orange : .accentColor)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var progressLabel: String {
        if isLoading { return "Checking encrypted credentials…" }
        if isImporting { return "Saving the updated credentials…" }
        return "Asking macOS to enable the extension…"
    }

    private var primaryLabel: String {
        if providerState == .enabled { return "Open Passwords" }
        if providerState == .denied { return "Retry after profile setup" }
        return "Allow Passwords Import"
    }

    private var primarySymbol: String {
        if providerState == .enabled { return "arrow.up.forward.app" }
        if providerState == .denied { return "arrow.clockwise" }
        return "checkmark.shield"
    }

    private var actionHint: String {
        if providerState == .denied {
            return
                "Agent Keyring needs an eligible Apple Developer Program profile before macOS can enable credential import."
        }
        return "Agent Keyring does not read Passwords in the background."
    }

    private var primaryAction: () -> Void {
        if providerState == .enabled {
            openPasswords
        } else {
            enableProvider
        }
    }
}

@available(macOS 26.0, *)
private struct PasswordsImportInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                "In Passwords, choose File → Export All Items to App → Agent Keyring."
            )
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@available(macOS 26.0, *)
private struct UpdateHelp: View {
    let openPasswords: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Update from Passwords")
                .font(.headline)
            Text("Choose File → Export All Items to App → Agent Keyring.")
                .foregroundStyle(.secondary)
            Button("Open Passwords", action: openPasswords)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(18)
        .frame(width: 330, alignment: .leading)
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
