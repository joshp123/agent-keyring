import AppKit
import Observation
import SwiftUI
import AgentKeyringFeature

@MainActor
@Observable
final class AgentKeyringPresentation {
    private(set) var mainWindowRequest = 0
    private(set) var accessWindowRequest = 0

    func requestMainWindow() {
        mainWindowRequest &+= 1
    }

    func requestAccessWindow() {
        accessWindowRequest &+= 1
    }


}

struct AgentKeyringMenu: View {
    let presentation: AgentKeyringPresentation
    let grants: CredentialApprovalGrants

    private static let expirationTimeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        Button("Open Agent Keyring") {
            presentation.requestMainWindow()
        }
        .accessibilityIdentifier("open-agent-keyring")

        Divider()

        TimelineView(.periodic(from: .now, by: 60)) { _ in
            ForEach(grants.active) { grant in
                Menu("\(grant.site) · \(grant.account) · \(grant.id.action.rawValue) · until \(Self.expirationTimeFormat.string(from: grant.expiresAt))") {
                    Button("End") { grants.end(grant.id) }
                }
            }
        }

        Button("End all grants", action: grants.endAll)
            .accessibilityIdentifier("end-all-grants")

        Divider()

        Button("Quit Agent Keyring") {
            NSApplication.shared.terminate(nil)
        }
        .accessibilityIdentifier("quit-agent-keyring")
    }
}

struct AgentKeyringMenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let presentation: AgentKeyringPresentation

    var body: some View {
        Label("Agent Keyring", systemImage: "key.fill")
            .accessibilityLabel("Agent Keyring")
            .accessibilityIdentifier("agent-keyring-menu")
            .onChange(of: presentation.mainWindowRequest, initial: true) { _, request in
                guard request > 0 else { return }
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .onChange(of: presentation.accessWindowRequest, initial: true) { _, request in
                guard request > 0 else { return }
                openWindow(id: "access")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}
