import AppKit
import AuthenticationServices
import Sparkle
import SwiftUI
import AgentKeyringFeature
#if DEBUG
import AgentKeyringTestSupport
#endif

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
    private var syncNotifier: SystemMirrorSyncNotifier?
    private var syncTask: Task<Void, Never>?
    private let accessControlFixture: MirrorGeneration?
    private let fixturePolicyStore: CredentialAccessPolicyStore?

    override init() {
        let presentation = AgentKeyringPresentation()
        self.presentation = presentation
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-access-control") {
            let fixtureDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AgentKeyringUITest-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
            let policyStore = CredentialAccessPolicyStore(
                fileURL: fixtureDirectory.appendingPathComponent("access-policies.json"),
                signer: FakeAccessRulesSigner()
            )
            self.fixturePolicyStore = policyStore
            let accessControl = CredentialAccessController(store: policyStore)
            let settings = UserDefaults(suiteName: "AgentKeyringUITest")!
            settings.set(false, forKey: "includeExampleCredential")
            self.accessControlFixture = AccessControlUITestFixture.generation()
            self.model = MirrorAppModel(
                store: EncryptedSnapshotStore(
                    directoryURL: fixtureDirectory.appendingPathComponent("vault"),
                    keyProvider: StaticVaultKeyProvider(keyData: Data(repeating: 0x45, count: 32))
                ),
                accessControl: accessControl,
                settings: settings
            )
        } else {
            self.accessControlFixture = nil
            self.fixturePolicyStore = nil
            self.model = MirrorAppModel()
        }
        #else
        self.accessControlFixture = nil
        self.fixturePolicyStore = nil
        self.model = MirrorAppModel()
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if accessControlFixture == nil {
            let notifier = SystemMirrorSyncNotifier { [weak self] in
                self?.model.openPasswordsExport()
            }
            syncNotifier = notifier
            model.syncReminders = MirrorSyncReminders(notifier: notifier)
            syncTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.model.checkMirrorFreshness()
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                }
            }
        }
        NSApplication.shared.setActivationPolicy(.regular)

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon

        if let accessControlFixture, let fixturePolicyStore {
            Task { @MainActor in
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
                do {
                    try await fixturePolicyStore.save(assignments)
                    await model.accessControl.refresh(from: accessControlFixture)
                    presentation.requestAccessWindow()
                } catch {
                    assertionFailure("Could not prepare signed UI-test rules: \(error)")
                }
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

    func loadAccessRules() async {
        if let accessControlFixture { await model.accessControl.refresh(from: accessControlFixture) }
        else { await model.loadStatus() }
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
                .task { await appDelegate.loadAccessRules() }
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
            AgentKeyringMenu(presentation: appDelegate.presentation, endAllGrants: appDelegate.model.endAllGrants)
        } label: {
            AgentKeyringMenuBarLabel(presentation: appDelegate.presentation)
        }
    }
}
