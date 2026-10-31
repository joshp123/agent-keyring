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
    let model: MirrorAppModel

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

        ForEach(model.leaseStore.activeLeases, id: \.leaseID) { lease in
            Menu("\(lease.sites.first ?? "Login") · \(lease.taskRef) · until \(Self.expirationTimeFormat.string(from: Date(timeIntervalSince1970: TimeInterval(lease.notAfterUnixSeconds))))") {
                Button("End") {
                    do { try model.leaseStore.end(lease.leaseID) }
                    catch { NSLog("Could not end lease: %@", String(describing: error)) }
                }
            }
        }
        Button("End all leases", action: model.endAllGrants)
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
