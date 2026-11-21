import AppKit
import OSLog
import AuthenticationServices
import LocalAuthentication
import SwiftUI
import AgentKeyringApprovalUI
import AgentKeyringFeature
import AgentKeyringScreenBackends

@MainActor
final class AgentKeyringAppDelegate: NSObject, NSApplicationDelegate {
    let presentation: AgentKeyringPresentation
    let model: MirrorAppModel
    private var syncNotifier: SystemMirrorSyncNotifier?
    private var syncTask: Task<Void, Never>?
    private(set) lazy var approvals = ApprovalPresenter(model: model)
    private(set) lazy var menuBar: MacMenuBarModel = {
        let backend = LeaseMenuBarBackend(model: model)
        return MacMenuBarModel(backend: backend, initial: backend.snapshot())
    }()

    override init() {
        let presentation = AgentKeyringPresentation()
        self.presentation = presentation
        MirrorAppModel.forgetPreviousInstall()
        self.model = MirrorAppModel()
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
        do {
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
        do {
            Task { @MainActor in
                await model.loadStatus()
                if !model.firstRunFinished { presentation.requestMainWindow() }
            }
        }

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else { return }
        NSApplication.shared.applicationIconImage = icon

    }

    /// Back from System Settings: if Agent Keyring is now on in AutoFill, the AutoFill sheet closes.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.recheckAutoFill()
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

/// First run until Josh clicks Show Passwords, then the Passwords and Devices tabs.
private struct HomeWindow: View {
    let model: MirrorAppModel
    let presentation: AgentKeyringPresentation
    @State private var main: MacMainModel?

    var body: some View {
        Group {
            if model.firstRunFinished, model.passwordsCopy != nil {
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
        .background(BesidePasswords(isOn: model.passwordsCopy == .waiting))
    }
}

/// "Copy your passwords", with the AutoFill sheet over it while it is open.
private struct CopyPasswordsPage: View {
    let model: MirrorAppModel
    let inFirstRun: Bool

    var body: some View {
        var actions = MacCopyPage.Actions()
        actions.openPasswords = model.openPasswordsExport
        actions.showGuideStep = { model.copyGuideStep = $0 }
        actions.notInList = model.explainAllowExport
        actions.useTestPasswordOnly = { Task { await model.useTestPassword() } }
        actions.back = { model.send(.back) }
        actions.continueOn = { model.send(.continueOn) }
        actions.cancel = model.closePasswordsCopy
        return MacCopyPage(SetupScreens.copy(model, inFirstRun: inFirstRun), guideStep: model.copyGuideStep,
                           earlierVersion: MirrorAppModel.earlierVersionInstalled, inFirstRun: inFirstRun,
                           items: SetupScreens.copiedCount(model), actions: actions)
            .sheet(isPresented: Binding(get: { model.passwordsCopy == .allowExport }, set: { if !$0 { model.closeAllowExport() } })) {
                MacAllowExportSheet(openSettings: model.openAutoFillSettings, cancel: model.closeAllowExport)
            }
    }
}

/// Which device sheet Ready has open: one value, and nil when none is.
private enum ReadySheet: String, Identifiable {
    case iPhone, computer
    var id: String { rawValue }
}

/// The window is first run's saved state, with the facts beside it: Touch ID,
/// the passwords, a copy in progress and the devices that have joined.
private struct FirstRunHome: View {
    let model: MirrorAppModel
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
        .task { await model.loadStatus() }
        .onContinueUserActivity(ASCredentialExchangeActivity) { model.receive($0) }
        // The first click on a button works even while another app is in front.
        .allowsWindowActivationEvents(true)
    }

    @ViewBuilder private var page: some View {
        switch model.firstRun.step {
        case .welcome:
            MacWelcomePage { model.send(.getStarted) }
        case .practice:
            MacPracticePage(SetupScreens.practice(model.firstRun.practice), approver: MacApprover.shared.state, actions: practiceActions)
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

    private var practiceActions: MacPracticePage.Actions {
        var actions = MacPracticePage.Actions()
        actions.send = model.sendFirstRunPractice
        actions.openTouchIDSettings = { NSWorkspace.shared.open(MacApprover.touchIDSettings) }
        actions.back = { model.send(.back) }
        actions.continueOn = { model.send(.continueOn) }
        return actions
    }

    private var connectActions: MacConnectAgentPage.Actions {
        var actions = MacConnectAgentPage.Actions()
        actions.skipTest = { model.send(.skipTest) }
        actions.back = { model.send(.back) }
        actions.continueOn = { model.send(.continueOn) }
        return actions
    }

    private var readyActions: MacReadyPage.Actions {
        var actions = MacReadyPage.Actions()
        actions.addIPhone = { sheet = .iPhone }
        actions.addComputer = { sheet = .computer }
        // The same window becomes Passwords and Devices.
        actions.showPasswords = {
            model.send(.showPasswords)
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

@main
struct AgentKeyringApp: App {
    @NSApplicationDelegateAdaptor(AgentKeyringAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Window("Agent Keyring", id: "main") {
            HomeWindow(model: appDelegate.model, presentation: appDelegate.presentation)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            AgentKeyringMenuWindow(presentation: appDelegate.presentation, menuBar: appDelegate.menuBar,
                approvals: appDelegate.approvals, model: appDelegate.model)
        } label: {
            AgentKeyringMenuBarLabel(presentation: appDelegate.presentation, menuBar: appDelegate.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}
