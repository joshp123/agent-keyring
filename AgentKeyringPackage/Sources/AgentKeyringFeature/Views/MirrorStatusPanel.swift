import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct MirrorStatusPanel: View {
    let status: SafeMirrorStatus?
    let isLoading: Bool
    let isImporting: Bool
    let providerState: ProviderEnablementState
    let notice: MirrorNotice?
    let enableProvider: () -> Void
    let openPasswords: () -> Void
    let manageAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                StatusMark(symbol: presentation.symbol, colour: presentation.colour)

                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 32, weight: .semibold))
                        .tracking(-0.5)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(presentation.detail)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("mirror-status")

            if status != nil, !isImporting {
                Text(
                    "Agents use the `agent-keyring` command to copy a username, password or code. Access Rules decide whether to ask you, allow it or block it."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let status, !isImporting, status.skippedCredentialCount > 0 {
                Divider()
                MirrorDeltaStrip(status: status)
            } else if !isLoading, !isImporting {
                Divider()
                SetupSteps(providerState: providerState)
            }

            if let notice, !(providerState == .denied && status == nil) {
                MirrorNoticeRow(notice: notice)
            }

            PrimaryActionRow(
                status: status,
                isLoading: isLoading,
                isImporting: isImporting,
                providerState: providerState,
                enableProvider: enableProvider,
                openPasswords: openPasswords,
                manageAccess: manageAccess
            )

            if status != nil, !isImporting {
                Divider()
                AgentInstructionsView()
            }
        }
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var presentation: MirrorPresentation {
        if isLoading {
            return MirrorPresentation(
                title: "Opening Agent Keyring",
                detail: "Checking the encrypted logins on this Mac.",
                symbol: "ellipsis",
                colour: .secondary
            )
        }
        if isImporting {
            return MirrorPresentation(
                title: "Importing from Passwords",
                detail: "The existing logins remain available until the update is saved.",
                symbol: "arrow.triangle.2.circlepath",
                colour: .teal
            )
        }
        if let status {
            return MirrorPresentation(
                title: "\(status.credentialItemCount) logins",
                detail:
                    "Updated \(status.importedAt.formatted(.relative(presentation: .named))).",
                symbol: "checkmark.shield.fill",
                colour: .green
            )
        }
        if providerState == .denied {
            return MirrorPresentation(
                title: "Apple blocked the extension",
                detail:
                    "The app is built and signed, but credential exchange needs an eligible Developer Program profile.",
                symbol: "exclamationmark.shield.fill",
                colour: .orange
            )
        }
        if providerState == .enabled {
            return MirrorPresentation(
                title: "Import your logins",
                detail:
                    "In Passwords, export all items to Agent Keyring. They are encrypted on this Mac.",
                symbol: "arrow.down.to.line.compact",
                colour: .teal
            )
        }
        return MirrorPresentation(
            title: "Set up Agent Keyring",
            detail:
                "Agent Keyring lets local AI agents use logins from Apple Passwords without putting passwords or codes in chat.",
            symbol: "key.horizontal.fill",
            colour: .teal
        )
    }
}

@available(macOS 26.0, *)
private struct AgentInstructionsView: View {
    @State private var didCopy = false

    private static let instructions =
        "Use `agent-keyring` before asking for credentials. Resolve the page URL, copy the needed field and paste with Cmd-V; never read or print the clipboard. Run `agent-keyring --help` for commands."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Add to AGENTS.md")
                    .font(.headline)
                Spacer()
                Button(action: copyInstructions) {
                    Label(
                        didCopy ? "Copied" : "Copy",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("copy-agent-instructions")
            }

            Text(Self.instructions)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.primary.opacity(0.04), in: .rect(cornerRadius: 8))
        }
        .accessibilityIdentifier("agent-instructions")
    }

    private func copyInstructions() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.instructions, forType: .string)
        didCopy = true
    }
}

@available(macOS 26.0, *)
private struct MirrorPresentation {
    let title: String
    let detail: String
    let symbol: String
    let colour: Color
}

@available(macOS 26.0, *)
private struct StatusMark: View {
    let symbol: String
    let colour: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 24, weight: .semibold))
            .symbolEffect(
                .pulse, options: .repeat(.periodic(delay: 1.4)),
                isActive: symbol == "arrow.triangle.2.circlepath"
            )
            .foregroundStyle(colour)
            .frame(width: 54, height: 54)
            .background(colour.opacity(0.12), in: Circle())
            .overlay {
                Circle()
                    .stroke(colour.opacity(0.18), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
