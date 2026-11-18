import AppKit
import Observation
import SwiftUI
import AgentKeyringApprovalUI
import AgentKeyringFeature

@MainActor
@Observable
final class AgentKeyringPresentation {
    private(set) var mainWindowRequest = 0
    /// The tab the main window shows when it opens after first run.
    var tab = MacMainModel.Tab.logins

    func requestMainWindow(_ tab: MacMainModel.Tab? = nil) {
        if let tab { self.tab = tab }
        mainWindowRequest &+= 1
    }

    func requestAccessWindow() { requestMainWindow(.logins) }


}

/// The menu bar window (RFC 0007, U3): the shared view, with actions that
/// close the window before they open something else.
struct AgentKeyringMenuWindow: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: AgentKeyringPresentation
    let menuBar: MacMenuBarModel
    let approvals: ApprovalPresenter

    var body: some View {
        MacMenuBarView(model: menuBar)
            .onAppear {
                menuBar.review = { leaseID in
                    dismiss()
                    approvals.present(requestID: leaseID)
                }
                menuBar.reviewEnrolment = { enrolmentID in
                    dismiss()
                    approvals.present(enrolmentID: enrolmentID)
                }
                menuBar.openMachines = {
                    dismiss()
                    presentation.requestMainWindow(.devices)
                }
                menuBar.openRules = {
                    dismiss()
                    presentation.requestMainWindow(.logins)
                }
                menuBar.openAgentKeyring = {
                    dismiss()
                    presentation.requestMainWindow()
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
        MacMenuBarLabel(waitingCount: menuBar.attentionCount)
            .accessibilityIdentifier("agent-keyring-menu")
            .onChange(of: presentation.mainWindowRequest, initial: true) { _, request in
                guard request > 0 else { return }
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}
