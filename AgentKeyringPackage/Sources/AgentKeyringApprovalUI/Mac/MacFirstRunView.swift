// Written by AI on 2026.11.16 by model Claude Opus 5.5.
//
// The window Agent Keyring opens on: before logins are imported, one step to
// bring them in; afterwards, what happens when an agent asks and the line to
// give agents. Nothing else, because nothing else is needed to start.

#if os(macOS)
import SwiftUI

public enum FirstRunState: Hashable, Sendable {
    /// macOS hasn't yet let Apple Passwords export to Agent Keyring.
    case needsAllow
    case needsExport
    case importing
    /// Apple refused the export extension for this build.
    case blocked
    case ready(logins: Int, importedAt: Date)
}

public struct MacFirstRunView: View {
    let state: FirstRunState
    let agentInstructions: String
    let allow: () -> Void
    let openPasswords: () -> Void
    let openRules: () -> Void
    @State private var didCopy = false

    public init(state: FirstRunState, agentInstructions: String, allow: @escaping () -> Void,
        openPasswords: @escaping () -> Void, openRules: @escaping () -> Void) {
        self.state = state
        self.agentInstructions = agentInstructions
        self.allow = allow
        self.openPasswords = openPasswords
        self.openRules = openRules
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case let .ready(logins, importedAt) = state {
                ready(logins: logins, importedAt: importedAt)
            } else {
                setUp
            }
        }
        .padding(28)
        .frame(width: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(KeyringColour.surface)
    }

    @ViewBuilder private var setUp: some View {
        Heading(title: FirstRunCopy.title, intro: FirstRunCopy.intro)
        Divider()
        Section(title: FirstRunCopy.importHeading) {
            switch state {
            case .needsAllow:
                Text(FirstRunCopy.allowBody)
                PrimaryButton(title: FirstRunCopy.allowButton, action: allow)
            case .needsExport:
                Text(FirstRunCopy.exportBody)
                PrimaryButton(title: FirstRunCopy.exportButton, action: openPasswords)
            case .importing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(FirstRunCopy.importing)
                }
            case .blocked, .ready:
                Text(FirstRunCopy.blockedBody).foregroundStyle(KeyringColour.denyText)
            }
        }
    }

    @ViewBuilder private func ready(logins: Int, importedAt: Date) -> some View {
        Heading(title: FirstRunCopy.readyTitle, intro: FirstRunCopy.readyIntro(logins))
        Divider()
        Section(title: FirstRunCopy.whenAgentAsksHeading) {
            Text(FirstRunCopy.whenAgentAsksBody)
        }
        Section(title: FirstRunCopy.tellAgentsHeading) {
            Text(FirstRunCopy.tellAgentsBody)
            HStack(alignment: .top, spacing: 10) {
                Text(agentInstructions)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(didCopy ? FirstRunCopy.copied : FirstRunCopy.copy) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(agentInstructions, forType: .string)
                    didCopy = true
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
        }
        Divider()
        HStack(spacing: 12) {
            Text(FirstRunCopy.imported(importedAt.formatted(.relative(presentation: .named))))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(FirstRunCopy.importAgain, action: openPasswords)
                .buttonStyle(.link)
                .font(.callout)
            Spacer()
            Button(FirstRunCopy.rules, action: openRules)
        }
    }
}

private struct Heading: View {
    let title: String
    let intro: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.weight(.bold)).tracking(-0.6)
            Text(intro).font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(DecisionButtonStyle(colour: KeyringColour.signal, height: 36))
            .frame(maxWidth: 200)
            .padding(.top, 4)
    }
}
#endif
