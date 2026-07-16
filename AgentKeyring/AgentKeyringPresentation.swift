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

    func presentApprovalWindow() async -> ApprovalWindowPresentation {
        let existingWindow = mainWindow
        let wasVisible = existingWindow?.isVisible == true
        let wasMiniaturized = existingWindow?.isMiniaturized == true

        requestMainWindow()

        for _ in 0..<50 {
            if let window = mainWindow, window.isVisible {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                return ApprovalWindowPresentation(
                    window: window,
                    closeWhenFinished: !wasVisible,
                    miniaturizeWhenFinished: wasMiniaturized
                )
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }

        return ApprovalWindowPresentation(
            window: nil,
            closeWhenFinished: !wasVisible,
            miniaturizeWhenFinished: wasMiniaturized
        )
    }

    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first(where: {
            $0.title == "Agent Keyring" && $0.isVisible
        }) ?? NSApplication.shared.windows.first(where: { $0.title == "Agent Keyring" })
    }
}

struct AgentKeyringMenu: View {
    let presentation: AgentKeyringPresentation

    var body: some View {
        Button("Open Agent Keyring") {
            presentation.requestMainWindow()
        }
        .accessibilityIdentifier("open-agent-keyring")

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
