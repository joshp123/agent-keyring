import AppKit
import AuthenticationServices
import Sparkle
import SwiftUI
import AgentKeyringFeature

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

@MainActor
final class AgentKeyringAppDelegate: NSObject, NSApplicationDelegate {
    let presentation: AgentKeyringPresentation
    let model: MirrorAppModel

    override init() {
        let presentation = AgentKeyringPresentation()
        self.presentation = presentation
        self.model = MirrorAppModel(
            approvalWindowPresenter: {
                await presentation.presentApprovalWindow()
            }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon

    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            presentation.requestMainWindow()
        }
        return true
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

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        Window("Agent Keyring", id: "main") {
            ContentView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

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

        MenuBarExtra {
            AgentKeyringMenu(presentation: appDelegate.presentation)
        } label: {
            AgentKeyringMenuBarLabel(presentation: appDelegate.presentation)
        }
    }
}
