import AppKit
import AuthenticationServices
import SwiftUI
import AgentKeyringFeature

@MainActor
final class AgentKeyringAppDelegate: NSObject, NSApplicationDelegate {
    let model = MirrorAppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon
    }

    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == ASCredentialExchangeActivity else {
            return false
        }

        model.receive(userActivity)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            model.receiveAgentRequest(url)
        }
    }
}

@main
struct AgentKeyringApp: App {
    @NSApplicationDelegateAdaptor(AgentKeyringAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Window("Agent Keyring", id: "main") {
            ContentView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)

        Window("Credential access", id: "access") {
            AccessControlView(controller: appDelegate.model.accessControl)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, context in
            let display = context.defaultDisplay.visibleRect
            return WindowPlacement(
                size: CGSize(
                    width: min(960, display.width),
                    height: min(680, display.height)
                )
            )
        }
        .windowIdealPlacement { _, context in
            let display = context.defaultDisplay.visibleRect
            return WindowPlacement(
                size: CGSize(
                    width: min(1_080, display.width),
                    height: min(740, display.height)
                )
            )
        }
    }
}
