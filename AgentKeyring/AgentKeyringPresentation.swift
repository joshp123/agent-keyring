import AppKit
import Observation
import SwiftUI
import AgentKeyringApprovalUI
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

/// The menu bar window (RFC 0007, U3): the shared view, with actions that
/// close the window before they open something else.
struct AgentKeyringMenuWindow: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: AgentKeyringPresentation
    let menuBar: MacMenuBarModel
    let leaseApprovals: LeaseApprovalPresenter
    let checkForUpdates: () -> Void

    var body: some View {
        MacMenuBarView(model: menuBar)
            .onAppear {
                menuBar.review = { leaseID in
                    dismiss()
                    leaseApprovals.present(leaseID: leaseID)
                }
                menuBar.openRules = {
                    dismiss()
                    presentation.requestAccessWindow()
                }
                menuBar.openAgentKeyring = {
                    dismiss()
                    presentation.requestMainWindow()
                }
                menuBar.checkForUpdates = {
                    dismiss()
                    checkForUpdates()
                }
                menuBar.quit = { NSApplication.shared.terminate(nil) }
            }
    }
}

struct AgentKeyringMenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let presentation: AgentKeyringPresentation
    let menuBar: MacMenuBarModel

    var body: some View {
        MacMenuBarLabel(waitingCount: menuBar.waiting.count)
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
