import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringDesign
import AgentKeyringEngine
import AgentKeyringScreenBackends
import AgentKeyringSealing
import AppKit
import AuthenticationServices
import Combine
import LocalAuthentication
import OSLog
import Sparkle
import SwiftUI

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
        Button(MenuBarCopy.checkForUpdates, action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

@MainActor
final class AgentKeyringAppDelegate: NSObject, NSApplicationDelegate {
    let presentation: AgentKeyringPresentation
    let model: MacKeyringEngine
    private var syncNotifier: SystemStalePasswordsReminderNotifier?
    private var syncTask: Task<Void, Never>?
    private(set) lazy var approvals = ApprovalPresenter(model: model)
    private(set) lazy var menuBar: MacMenuBarModel = {
        let backend = LeaseMenuBarBackend(model: model)
        return MacMenuBarModel(backend: backend, initial: backend.snapshot())
    }()

    override init() {
        KeyringFont.register()
        // Before the model makes its device, whose relay is read from this once.
        MacSyncCoordinator.useRelay(UserDefaults.standard.string(forKey: "AgentKeyringRelayURL"))
        let presentation = AgentKeyringPresentation()
        self.presentation = presentation
        MacKeyringEngine.forgetPreviousInstall()
        self.model = MacKeyringEngine()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "TouchIDOnly") {
            Logger(subsystem: "com.agentkeyring.app", category: "Approval").notice("TouchIDOnly: approvals use Touch ID only; the Watch is never asked.")
        }
        // Before the socket opens, so no request reaches the old system prompt.
        approvals.start()
        // At launch, not when the window opens, so the menu is ready when clicked.
        Task { [menuBar] in await menuBar.followUpdates() }
        do { try model.startAgentListener() }
        catch { NSLog("Agent Keyring could not start the agent socket: %@", String(describing: error)) }
        // A push address, so another computer can show its request here, and iCloud can say what changed.
        NSApplication.shared.registerForRemoteNotifications()
        do {
            let notifier = SystemStalePasswordsReminderNotifier { [weak self] in
                self?.model.openPasswordsCopyFlow()
                self?.presentation.requestMainWindow(.logins)
            }
            notifier.onRequest = { [weak self] userInfo in self?.model.receivedPush(userInfo) }
            syncNotifier = notifier
            model.syncReminders = StalePasswordsReminders(notifier: notifier)
            syncTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.model.checkPasswordCopyFreshness()
                    do { try await Task.sleep(for: .seconds(60)) }
                    catch { return }
                }
            }
        }
        do {
            Task { @MainActor in
                await model.loadStatus()
                if !model.firstRunFinished || model.setup.isAsking { presentation.requestMainWindow() }
                #if DEBUG
                // -SandboxExport <file>: this Mac's keyring for the screens to run on elsewhere, every password "hunter2".
                if let path = UserDefaults.standard.string(forKey: "SandboxExport"), !path.isEmpty {
                    do {
                        try AppMainWindowBackend(model: model).sandboxBundle(model: model).write(to: URL(fileURLWithPath: path), options: .atomic)
                        KeyringDiagnosticLog.mac.noteDeviceEvent("sandbox", "exported", ["path": path])
                    } catch {
                        KeyringDiagnosticLog.mac.noteDeviceEvent("sandbox", "export-failed", ["reason": "\(error)"])
                    }
                }
                #endif
            }
            Task {
                let account = await MacSyncCoordinator.cloudAccountSeed()
                await VersionCheck.checkIfDue(platform: "macos", accountSeed: account)
            }
        }

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon

    }

    /// Back from System Settings: if Agent Keyring is now on in AutoFill, the AutoFill sheet closes.
    /// In front again: whatever changed in iCloud meanwhile is fetched.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.recheckAutoFill()
        model.device?.cloudChanged()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        #if DEBUG
        let production = false
        #else
        let production = true
        #endif
        model.registerPush(token: deviceToken, topic: Bundle.main.bundleIdentifier ?? "", production: production)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Logger(subsystem: "com.agentkeyring.app", category: "Push").error("No push address: \(String(describing: error), privacy: .public)")
    }

    /// A computer's request, or iCloud saying something changed. macOS opens no quit app for it: Open at Login keeps it running.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        model.receivedPush(userInfo)
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


}

/// How this Mac is used, while its keys wait for Josh; then first run until
/// he clicks Show Passwords; then the Passwords and Devices tabs.
private struct HomeWindow: View {
    let model: MacKeyringEngine
    let presentation: AgentKeyringPresentation
    @State private var main: MacMainModel?

    var body: some View {
        Group {
            if let page = SetupScreens.thisMac(model.setup) {
                ThisMacPage(page, actions: thisMacActions)
            } else if model.setup == .loading {
                // Not yet known whether this Mac must be asked how it is used first.
                ProgressView().padding(40)
            } else if model.firstRunFinished, model.importSession.isFlowOpen {
                // Copy Again: the same "Copy your passwords" as first run, with Cancel.
                CopyPasswordsPage(model: model, inFirstRun: false)
            } else if model.firstRunFinished {
                if let main {
                    // Add Device opens the add sheets through this one closure.
                    MacMainWindowView(model: main) { sheet, close in sheet == .addIPhone ? AnyView(AddIPhoneSheet(model: model, close: close)) : AnyView(AddComputerSheet(model: model, close: close)) }
                        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 640)
                } else { ProgressView().padding(40) }
            } else {
                FirstRunHome(model: model, presentation: presentation)
            }
        }
        .onAppear {
            if main == nil {
                let backend = AppMainWindowBackend(model: model)
                main = MacMainModel(backend: backend, initial: backend.snapshot())
            }
            main?.tab = presentation.tab
        }
        .onChange(of: presentation.mainWindowRequest) { main?.tab = presentation.tab }
        .background(BesidePasswords(isOn: model.importSession.exportState == .waiting))
    }

    private var thisMacActions: ThisMacPageActions {
        var actions = ThisMacPageActions()
        actions.chooseForAgents = { model.sendSetup(.chooseForAgents) }
        actions.choosePersonalMac = { model.sendSetup(.choosePersonalMac) }
        actions.usePassword = model.usePasswordOnThisMac
        actions.tryAgain = { model.sendSetup(.tryAgain) }
        actions.back = { model.sendSetup(.back) }
        actions.quit = { NSApp.terminate(nil) }
        return actions
    }
}

/// Step 3 of first run ("Add passwords") and the main window's selective import flow,
/// with the AutoFill helper sheet and the manual Add a Password sheet over it.
private struct CopyPasswordsPage: View {
    let model: MacKeyringEngine
    let inFirstRun: Bool
    @State private var showManualAdd = false

    var body: some View {
        MacSelectiveImportPage(SetupScreens.selectiveImport(model, inFirstRun: inFirstRun), actions: actions)
            .sheet(isPresented: Binding(get: { model.importSession.exportState == .allowExport }, set: { if !$0 { model.closeAllowExport() } })) {
                MacAllowExportSheet(openSettings: model.openAutoFillSettings, cancel: model.closeAllowExport)
            }
            .sheet(isPresented: $showManualAdd) {
                MacAddPasswordSheet(
                    onSave: { site, account, password, totp, rule in
                        try await model.addManualPassword(
                            website: site,
                            account: account,
                            password: password,
                            totpSecret: totp,
                            rule: rule,
                            showReceipt: true
                        )
                    },
                    onCancel: { showManualAdd = false }
                )
            }
    }

    private var actions: MacSelectiveImportPageActions {
        var a = MacSelectiveImportPageActions()
        a.selectPath = { choice in
            model.sendImport(.selectPath(choice))
        }
        a.continueFromChoose = {
            model.sendImport(.continueFromChoose)
        }
        a.skipForNow = {
            Task { await model.useTestPassword() }
        }
        a.backToPreviousSetupStep = {
            model.sendFirstRunEvent(.back)
        }
        a.cancelFlow = {
            model.closePasswordsCopy()
        }
        a.showGuideStep = { step in
            model.sendImport(.setGuideStep(step))
        }
        a.openApplePasswords = {
            model.openPasswordsExport()
        }
        a.notInList = {
            model.explainAllowExport()
        }
        a.openManualAdd = {
            showManualAdd = true
        }
        a.switchToCategories = {
            model.sendImport(.switchToCategories)
        }
        a.switchToPickFew = {
            model.sendImport(.switchToPickFew)
        }
        a.switchToAllPasswords = {
            model.sendImport(.switchToAllPasswords)
        }
        a.toggleCategory = { cat in
            model.sendImport(.toggleCategory(cat))
        }
        a.continueFromCategories = {
            model.sendImport(.continueFromCategories)
        }
        a.backToChoose = {
            model.sendImport(.backToChoose)
        }
        a.backToCategories = {
            model.sendImport(.backToCategories)
        }
        a.toggleReviewItem = { id in
            model.sendImport(.toggleItem(id))
        }
        a.includeAllSensitive = {
            model.sendImport(.includeAllSensitive)
        }
        a.excludeAllSensitive = {
            model.sendImport(.excludeAllSensitive)
        }
        a.changeCategories = {
            model.sendImport(.openChangeCategories)
        }
        a.cancelImport = {
            model.cancelStagedImport(inFirstRun: inFirstRun)
        }
        a.saveSelected = {
            Task { await model.commitStagedImport() }
        }
        a.addMorePasswords = {
            model.sendImport(.addMorePasswords)
        }
        a.finishStep = {
            if inFirstRun {
                model.sendImport(.reset)
                model.sendFirstRunEvent(.continueOn)
            } else {
                model.closePasswordsCopy()
            }
        }
        return a
    }
}

/// Which device sheet Ready has open: one value, and nil when none is.
private enum ReadySheet: String, Identifiable {
    case iPhone, computer
    var id: String { rawValue }
}

/// The window is first run's saved state, with the facts beside it: Touch ID or the Mac password,
/// the passwords, a copy in progress and the devices that have joined.
private struct FirstRunHome: View {
    let model: MacKeyringEngine
    let presentation: AgentKeyringPresentation
    @State private var sheet: ReadySheet?

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView().padding(40)
            } else {
                page
            }
        }
        .onContinueUserActivity(ASCredentialExchangeActivity) { model.receive($0) }
        // The first click on a button works even while another app is in front.
        .allowsWindowActivationEvents(true)
    }

    @ViewBuilder private var page: some View {
        switch model.firstRun.step {
        case .welcome:
            MacWelcomePage(iPhone: SetupScreens.welcomeIPhone(model), connect: { model.device?.connectToIPhone() },
                           cancel: { model.device?.cancelJoiningIPhone() }) { model.sendFirstRunEvent(.getStarted) }
                // Agent Keyring may be set up on his iPhone: its invitation and list can arrive at any moment.
                .task {
                    while !Task.isCancelled {
                        await model.device?.lookForIPhone()
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
        case .practice:
            MacPracticePage(SetupScreens.practicePageState(model.firstRun.practice), approver: MacApprover.shared.state, actions: practiceActions)
                // A Touch ID keyboard connected while this window stays in front sends no notification: look again.
                .task {
                    while !Task.isCancelled {
                        MacApprover.shared.refresh()
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
        case .privacy:
            MacPrivacyPage(actions: privacyActions)
        case .copy:
            CopyPasswordsPage(model: model, inFirstRun: true)
        case let .connectAgent(outcome):
            MacConnectAgentPage(SetupScreens.connectAgent(outcome), actions: connectActions)
        case .ready, .finished:
            MacReadyPage(copied: SetupScreens.readyCopied(model), devices: SetupScreens.readyDevices(model), actions: readyActions)
                .sheet(item: $sheet) { which in
                    switch which {
                    case .iPhone: AddIPhoneSheet(model: model) { sheet = nil }
                    case .computer: AddComputerSheet(model: model) { sheet = nil }
                    }
                }
        }
    }

    private var practiceActions: MacPracticePageActions {
        var actions = MacPracticePageActions()
        actions.send = model.sendFirstRunPractice
        actions.openTouchIDSettings = { NSWorkspace.shared.open(MacApprover.touchIDSettings) }
        actions.back = { model.sendFirstRunEvent(.back) }
        actions.continueOn = { model.sendFirstRunEvent(.continueOn) }
        return actions
    }

    private var privacyActions: MacPrivacyPageActions {
        var actions = MacPrivacyPageActions()
        actions.back = { model.sendFirstRunEvent(.back) }
        actions.continueOn = { model.sendFirstRunEvent(.continueOn) }
        return actions
    }

    private var connectActions: MacConnectAgentPageActions {
        var actions = MacConnectAgentPageActions()
        actions.skipTest = { model.sendFirstRunEvent(.skipTest) }
        actions.back = { model.sendFirstRunEvent(.back) }
        actions.continueOn = { model.sendFirstRunEvent(.continueOn) }
        return actions
    }

    private var readyActions: MacReadyPageActions {
        var actions = MacReadyPageActions()
        actions.addIPhone = { sheet = .iPhone }
        actions.addComputer = { sheet = .computer }
        // The same window becomes Passwords and Devices.
        actions.showPasswords = {
            model.sendFirstRunEvent(.showPasswords)
            presentation.showMenuBarTip()
        }
        return actions
    }
}

/// While he follows the steps in Passwords, the window moves beside the
/// Passwords window, so neither covers the other or Apple's own dialogs. It
/// never floats above other apps.
private struct BesidePasswords: NSViewRepresentable {
    let isOn: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard isOn, !context.coordinator.placed else {
            if !isOn { context.coordinator.placed = false }
            return
        }
        context.coordinator.placed = true
        Task { @MainActor [weak view] in
            // Passwords takes a moment to open its window.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let window = view?.window else { return }
                if let passwords = Self.passwordsFrame() {
                    window.setFrame(Self.frame(for: window.frame.size, beside: passwords), display: true, animate: true)
                    return
                }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var placed = false }

    /// The Passwords window's frame in screen coordinates, from the window server's list.
    static func passwordsFrame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Passwords").first,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
            let entry = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0 }),
            let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
            let top = CGRect(dictionaryRepresentation: bounds), let primary = NSScreen.screens.first
        else { return nil }
        // The window server counts down from the top of the main screen; AppKit up from its bottom.
        return CGRect(x: top.minX, y: primary.frame.maxY - top.maxY, width: top.width, height: top.height)
    }

    /// To the right of Passwords if it fits on that screen, else to its left,
    /// else the screen's right edge; level with its top.
    static func frame(for size: CGSize, beside passwords: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(passwords) }?.visibleFrame ?? passwords
        let gap: CGFloat = 16
        let x = passwords.maxX + gap + size.width <= screen.maxX ? passwords.maxX + gap
            : passwords.minX - gap - size.width >= screen.minX ? passwords.minX - gap - size.width
            : screen.maxX - size.width
        let y = min(max(passwords.maxY - size.height, screen.minY), screen.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

private struct SettingsWindowContent: View {
    let model: MacKeyringEngine
    @State private var main: MacMainModel?

    var body: some View {
        Group {
            if let main {
                MacSettingsView(model: main)
            } else {
                ProgressView().padding(40)
            }
        }
        .onAppear {
            if main == nil {
                let backend = AppMainWindowBackend(model: model)
                main = MacMainModel(backend: backend, initial: backend.snapshot())
            }
        }
    }
}

@main
struct AgentKeyringApp: App {
    @NSApplicationDelegateAdaptor(AgentKeyringAppDelegate.self)
    private var appDelegate

    private let updaterController: SPUStandardUpdaterController = {
        #if DEBUG
        let shouldStart = false
        #else
        let shouldStart = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        #endif
        return SPUStandardUpdaterController(
            startingUpdater: shouldStart,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()

    var body: some Scene {
        Window("Agent Keyring", id: "main") {
            HomeWindow(model: appDelegate.model, presentation: appDelegate.presentation)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsWindowContent(model: appDelegate.model)
        }

        MenuBarExtra {
            AgentKeyringMenuWindow(presentation: appDelegate.presentation, menuBar: appDelegate.menuBar,
                approvals: appDelegate.approvals, model: appDelegate.model,
                updater: updaterController.updater) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                updaterController.checkForUpdates(nil)
            }
        } label: {
            AgentKeyringMenuBarLabel(presentation: appDelegate.presentation, menuBar: appDelegate.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}
