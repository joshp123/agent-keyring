import AppKit
import Observation
import Sparkle
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

    @ObservationIgnored private var tip: NSPanel?

    /// After first run's Done: "Agent Keyring stays here." under the menu bar
    /// icon for a few seconds. It takes no clicks and never activates the app.
    func showMenuBarTip() {
        guard tip == nil, let item = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("NSStatusBarWindow") })
        else { return }
        // With a full menu bar, or a tool that hides icons, the keyhole is not
        // on screen; the tip would point at nothing, so it doesn't show.
        guard item.occlusionState.contains(.visible),
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: item.frame.midX, y: item.frame.midY)) })
        else { return }
        let hosting = NSHostingView(rootView: MenuBarTipView())
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        let icon = item.frame
        // The view has 16 points of room around the bubble for its shadow.
        let x = min(max(icon.midX - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width)
        panel.setFrameOrigin(NSPoint(x: x, y: icon.minY - 6 + 16 - size.height))
        panel.orderFrontRegardless()
        tip = panel
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.tip?.orderOut(nil)
            self?.tip = nil
        }
    }


}

/// The menu bar window (RFC 0007, U3): the shared view, with actions that
/// close the window before they open something else.
struct AgentKeyringMenuWindow: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: AgentKeyringPresentation
    let menuBar: MacMenuBarModel
    let approvals: ApprovalPresenter
    let model: MirrorAppModel
    let updater: SPUUpdater
    let checkForUpdates: () -> Void

    var body: some View {
        MacMenuBarView(model: menuBar)
            .frame(width: 360)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck in
                menuBar.canCheckForUpdates = canCheck
            }
            .onAppear {
                menuBar.canCheckForUpdates = updater.canCheckForUpdates
                menuBar.review = { leaseID in
                    dismiss()
                    approvals.present(requestID: leaseID)
                }
                menuBar.reviewEnrolment = { enrolmentID in
                    dismiss()
                    approvals.present(enrolmentID: enrolmentID)
                }
                menuBar.openDevices = {
                    dismiss()
                    presentation.requestMainWindow(.devices)
                }
                menuBar.openPasswords = {
                    dismiss()
                    presentation.requestMainWindow(.logins)
                }
                // The main window shows "Copy your passwords" while the copy is open.
                menuBar.copyAgain = {
                    dismiss()
                    model.openPasswordsExport()
                    presentation.requestMainWindow(.logins)
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
        MacMenuBarLabel()
            .accessibilityIdentifier("agent-keyring-menu")
            .onChange(of: presentation.mainWindowRequest, initial: true) { _, request in
                guard request > 0 else { return }
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}
