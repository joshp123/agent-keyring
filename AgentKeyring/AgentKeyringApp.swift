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

/// First run until Josh clicks its Done, then the Passwords and Devices tabs.
private struct HomeWindow: View {
    let model: MirrorAppModel
    let presentation: AgentKeyringPresentation
    @State private var main: MacMainModel?

    var body: some View {
        Group {
            if model.firstRunFinished, let copy = model.passwordsCopy {
                // Copy from Passwords: the same "Copy your passwords" as first run.
                MacFirstRunView(screen: copyScreen(copy, model: model, offerSample: false),
                    problem: model.problem,
                    actions: copyActions(model))
            } else if model.firstRunFinished {
                if let main {
                    MacMainWindowView(model: main) { sheet, close in AnyView(SetupSheet(sheet, model: model, close: close)) }
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

/// "Copy your passwords" as either window shows it.
@MainActor private func copyScreen(_ copy: PasswordsCopy, model: MirrorAppModel, offerSample: Bool) -> FirstRunScreen {
    switch copy {
    case .copying: .copying
    case let .allowExport(asking): .allowExport(asking: asking)
    case .steps, .waiting, .noneArrived:
        .copyPasswords(waiting: copy != .steps, noneArrived: copy == .noneArrived, offerSample: offerSample,
            earlierVersion: MirrorAppModel.earlierVersionInstalled)
    }
}

@MainActor private func copyActions(_ model: MirrorAppModel) -> FirstRunActions {
    var actions = FirstRunActions()
    actions.openPasswords = model.openPasswordsExport
    actions.cancelCopy = model.closePasswordsCopy
    actions.notInList = model.explainAllowExport
    actions.allowExport = model.askToAllowExport
    return actions
}

private struct FirstRunHome: View {
    let model: MirrorAppModel
    let presentation: AgentKeyringPresentation
    /// Connect on the window for a computer that stays on: waiting for Touch ID, or why it failed.
    @State private var connect: ConnectFlow?
    /// "Add other computers": the one-time command, made when that window opens.
    @State private var command: String?

    /// The window is first run's state, with the facts beside it: Touch ID,
    /// the passwords, the devices and computers that have joined, the leases
    /// and the last practice results.
    private var screen: FirstRunScreen? {
        switch model.firstRun {
        case .welcome: .welcome
        case .chooseDevices: .chooseDevices
        case .finished: nil
        case let .journey(_, page):
            switch page {
            case .practice:
                switch MacApprover.shared.state {
                case .ready: .practice
                case .lidClosed: .lidClosed
                case .needsFingerprint: .needsFingerprint
                }
            case let .practiceDenied(reply): .practiceDenied(reply: reply)
            case .copyPasswords: copyScreen(model.passwordsCopy ?? .steps, model: model, offerSample: true)
            case let .tellAgents(copied): SetupScreens.tellAgents(model, copied: copied)
            case .stayingOn: (connect ?? ConnectFlow(model: model)).screen
            case .addPhone: SetupScreens.addPhone(model)
            case .addWatch: SetupScreens.addWatch(model)
            case .addComputers: SetupScreens.addComputers(model, command: command)
            case .tryDevices: .tryDevices(SetupScreens.practiceRows(model))
            case .ready: SetupScreens.ready(model)
            }
        }
    }

    private var actions: FirstRunActions {
        var actions = copyActions(model)
        actions.getStarted = { model.send(.getStarted) }
        actions.chooseDevices = { iPhone, watch, computers in
            model.send(.chose(FirstRun.Devices(iPhone: iPhone, watch: watch, computers: computers)))
        }
        actions.tryAgain = { model.send(.tryAgain) }
        actions.openTouchIDSettings = { NSWorkspace.shared.open(MacApprover.touchIDSettings) }
        actions.useSample = { Task { await model.useSamplePassword() } }
        actions.copyOwn = { model.send(.copyOwn) }
        actions.continueOn = { model.send(.continueOn) }
        actions.skip = { model.send(.skip) }
        actions.useThisMacAlone = { model.send(.useThisMacAlone) }
        actions.connect = { address in
            let flow = connect ?? ConnectFlow(model: model)
            connect = flow
            flow.connect(address) { model.send(.connected) }
        }
        actions.connectOffered = {
            let flow = connect ?? ConnectFlow(model: model)
            connect = flow
            flow.connectOffered { model.send(.connected) }
        }
        actions.sendPractice = { key in Task { await model.sendPractice(to: key) } }
        // He lands on the main window, in the same window: Passwords and Devices.
        actions.done = {
            model.finishFirstRun()
            presentation.showMenuBarTip()
        }
        return actions
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView().padding(40)
            } else if let screen {
                MacFirstRunView(screen: screen, problem: model.problem, actions: actions)
            }
        }
        .task { await model.loadStatus() }
        .onChange(of: model.firstRun.step == .computers, initial: true) { _, now in
            if now, command == nil { command = SetupScreens.enrolCommand(model) }
        }
        .onContinueUserActivity(ASCredentialExchangeActivity) { model.receive($0) }
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
                approvals: appDelegate.approvals)
        } label: {
            AgentKeyringMenuBarLabel(presentation: appDelegate.presentation, menuBar: appDelegate.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}
