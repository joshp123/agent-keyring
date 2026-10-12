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
    let endAllGrants: () -> Void

    var body: some View {
        Button("Open Agent Keyring") {
            presentation.requestMainWindow()
        }
        .accessibilityIdentifier("open-agent-keyring")

        Divider()

        Button("End all grants", action: endAllGrants)
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
