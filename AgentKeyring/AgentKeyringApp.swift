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
    private let accessControlFixture: MirrorGeneration?

    override init() {
        let presentation = AgentKeyringPresentation()
        self.presentation = presentation
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-access-control") {
            let fixtureDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AgentKeyringUITest-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            let accessControl = CredentialAccessController(
                store: CredentialAccessPolicyStore(
                    fileURL: fixtureDirectory.appendingPathComponent("access-policies.json")
                )
            )
            self.accessControlFixture = AccessControlUITestFixture.generation()
            self.model = MirrorAppModel(
                store: EncryptedSnapshotStore(
                    directoryURL: fixtureDirectory.appendingPathComponent("vault"),
                    keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x45, count: 32))
                ),
                accessControl: accessControl,
                approvalWindowPresenter: {
                    await presentation.presentApprovalWindow()
                }
            )
        } else {
            self.accessControlFixture = nil
            self.model = MirrorAppModel(
                approvalWindowPresenter: {
                    await presentation.presentApprovalWindow()
                }
            )
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon

        if let accessControlFixture {
            Task { @MainActor in
                await model.accessControl.refresh(from: accessControlFixture)
                let assignments = Dictionary(
                    uniqueKeysWithValues: accessControlFixture.items.enumerated().compactMap {
                        index, item -> (UUID, CredentialAccessPolicy)? in
                        if (440..<492).contains(index) {
                            return (item.id, .allowAutomatically)
                        }
                        if index >= 492 { return (item.id, .block) }
                        return nil
                    }
                )
                await model.accessControl.setPolicies(assignments)
                presentation.requestAccessWindow()
            }
        }

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

private enum AccessControlUITestFixture {
    static func generation() -> MirrorGeneration {
        let items = (1...522).map(item)
        return MirrorGeneration(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 10)),
            previousGenerationID: nil,
            createdAt: Date(timeIntervalSince1970: 2_000),
            sourceExportedAt: Date(timeIntervalSince1970: 1_900),
            scope: .full,
            exporterIdentifier: "com.apple.Passwords",
            exporterDisplayName: "Passwords",
            items: items,
            delta: MirrorDelta(addedItemIDs: items.map(\.id)),
            skippedCredentialCount: 0
        )
    }

    private static func item(number: Int) -> MirrorItem {
        let high = UInt8((number >> 8) & 0xFF)
        let low = UInt8(number & 0xFF)
        let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, high, low))
        return MirrorItem(
            id: id,
            sourceIdentity: MirrorSourceIdentity(
                exporterIdentifier: "com.apple.Passwords",
                accountID: Data("account-\(number)".utf8),
                itemID: Data("item-\(number)".utf8)
            ),
            title: "Credential \(number)",
            origins: ["https://service-\(number).example/login"],
            credentials: [.password(userName: "account-\(number)", password: "SYNTHETIC")]
        )
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

        Window("Access Rules", id: "access") {
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
