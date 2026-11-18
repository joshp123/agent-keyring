import AppKit
import AuthenticationServices
import LocalAuthentication
import Sparkle
import SwiftUI
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringScreenBackends

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
    private(set) lazy var approvals = ApprovalPresenter(model: model)
    private(set) lazy var menuBar: MacMenuBarModel = {
        let backend = LeaseMenuBarBackend(model: model)
        return MacMenuBarModel(backend: backend, initial: backend.snapshot())
    }()

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
            let policyStore = CredentialAccessPolicyStore(fileURL: fixtureDirectory.appendingPathComponent("access-policies.json"))
            let fixture = AccessControlUITestFixture.generation()
            try? policyStore.save(Dictionary(uniqueKeysWithValues: fixture.items.enumerated().compactMap {
                index, item -> (UUID, CredentialAccessPolicy)? in
                if (440..<492).contains(index) { return (item.id, .allowAutomatically) }
                return index >= 492 ? (item.id, .block) : nil
            }))
            let settings = UserDefaults(suiteName: "AgentKeyringUITest")!
            settings.set(false, forKey: "includeExampleCredential")
            self.accessControlFixture = fixture
            self.model = MirrorAppModel(store: LoginStore(directory: fixtureDirectory.appendingPathComponent("logins")),
                accessControl: CredentialAccessController(store: policyStore), settings: settings)
        } else {
            self.accessControlFixture = nil
            self.model = MirrorAppModel()
        }
        #else
        self.accessControlFixture = nil
        self.model = MirrorAppModel()
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the socket opens, so no request reaches the old system prompt.
        approvals.start()
        // At launch, not when the window opens: the icon shows the waiting count.
        Task { [menuBar] in await menuBar.followUpdates() }
        do { try model.startAgentListener() }
        catch { NSLog("Agent Keyring could not start the agent socket: %@", String(describing: error)) }
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
        if accessControlFixture == nil {
            Task { @MainActor in
                await model.loadStatus()
                if model.status == nil { presentation.requestMainWindow() }
            }
        }

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon

        if let accessControlFixture {
            Task { @MainActor in
                await model.accessControl.refresh(from: accessControlFixture)
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

private struct FirstRunHome: View {
    @Environment(\.openWindow) private var openWindow
    let model: MirrorAppModel

    private var state: FirstRunState {
        if model.isImporting || model.providerState == .requesting { return .importing }
        if let status = model.status {
            return .ready(logins: status.credentialItemCount, importedAt: status.importedAt)
        }
        switch model.providerState {
        case .unknown: return .needsAllow
        case .enabled: return .needsExport
        case .denied: return .blocked
        case .requesting: return .importing
        }
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView().padding(40)
            } else {
                VStack(alignment: .leading) {
                    MacFirstRunView(state: state, agentInstructions: AgentInstructions.snippet,
                        allow: model.requestProviderEnablement, openPasswords: model.openPasswordsExport,
                        openRules: { openWindow(id: "access") })
                    if let notice = model.notice {
                        Text(notice.text).font(.callout).padding(.horizontal, 28).padding(.bottom, 20)
                    }
                }
            }
        }
        .task { await model.loadStatus() }
        .onContinueUserActivity(ASCredentialExchangeActivity) { model.receive($0) }
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
            FirstRunHome(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Window("Machines", id: "machines") {
            MachinesWindow(model: appDelegate.model, approvals: appDelegate.approvals)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Window("Rules", id: "access") {
            RulesWindow(model: appDelegate.model)
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
            AgentKeyringMenuWindow(presentation: appDelegate.presentation, menuBar: appDelegate.menuBar,
                approvals: appDelegate.approvals) {
                updaterController.checkForUpdates(nil)
            }
        } label: {
            AgentKeyringMenuBarLabel(presentation: appDelegate.presentation, menuBar: appDelegate.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}
