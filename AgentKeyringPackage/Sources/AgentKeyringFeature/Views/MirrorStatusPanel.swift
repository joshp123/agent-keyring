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
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 18) {
                StatusMark(symbol: presentation.symbol, colour: presentation.colour)

                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.eyebrow)
                        .font(.callout.weight(.semibold))
                        .tracking(1.1)
                        .foregroundStyle(presentation.colour)

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

            if let status, !isImporting {
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
        }
        .padding(30)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var presentation: MirrorPresentation {
        if isLoading {
            return MirrorPresentation(
                eyebrow: "CHECKING AGENT KEYRING",
                title: "Checking your credentials",
                detail: "Opening the encrypted credentials stored on this Mac.",
                symbol: "ellipsis",
                colour: .secondary
            )
        }
        if isImporting {
            return MirrorPresentation(
                eyebrow: "UPDATING CREDENTIALS",
                title: "Adding changes from Apple Passwords",
                detail:
                    "Agents keep using the existing encrypted copy until the update is safely saved.",
                symbol: "arrow.triangle.2.circlepath",
                colour: .teal
            )
        }
        if let status {
            return MirrorPresentation(
                eyebrow: "READY",
                title: "\(status.credentialItemCount) credentials ready for agent sign-ins",
                detail:
                    "New credentials ask you before sharing a password or code. Last updated from Apple Passwords \(status.importedAt.formatted(.relative(presentation: .named))).",
                symbol: "checkmark.shield.fill",
                colour: .green
            )
        }
        if providerState == .denied {
            return MirrorPresentation(
                eyebrow: "SETUP BLOCKED",
                title: "Apple blocked the extension",
                detail:
                    "The app is built and signed, but credential exchange needs an eligible Developer Program profile.",
                symbol: "exclamationmark.shield.fill",
                colour: .orange
            )
        }
        if providerState == .enabled {
            return MirrorPresentation(
                eyebrow: "READY FOR CREDENTIALS",
                title: "Add credentials from Apple Passwords",
                detail:
                    "Export your Passwords items to Agent Keyring. They are encrypted on this Mac and ask you before agents can use passwords or codes.",
                symbol: "arrow.down.to.line.compact",
                colour: .teal
            )
        }
        return MirrorPresentation(
            eyebrow: "LOCAL · ENCRYPTED",
            title: "Let local AI agents sign in",
            detail:
                "Agent Keyring gives local agents the matching password or verification code from Apple Passwords without putting it in chat. New credentials ask you first.",
            symbol: "key.horizontal.fill",
            colour: .teal
        )
    }
}

@available(macOS 26.0, *)
private struct MirrorPresentation {
    let eyebrow: String
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
