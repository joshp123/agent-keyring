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
                    problem: model.notice.flatMap { $0.kind == .information ? nil : $0.text },
                    actions: copyActions(model))
            } else if model.firstRunFinished {
                if let main { MacMainWindowView(model: main) } else { ProgressView().padding(40) }
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
        .background(FloatingWhile(isOn: model.passwordsCopy == .waiting))
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
    @Environment(\.dismissWindow) private var dismissWindow
    /// When he last came back to the app: the agents' links are read again then.
    @State private var cameBack = Date.now

    /// The screen is first run's state, with the facts beside it: Touch ID, the passwords and the agents' links.
    private var screen: FirstRunScreen? {
        switch model.firstRun {
        case .welcome: .welcome
        case .practice:
            switch MacApprover.shared.state {
            case .ready: .practice
            case .lidClosed: .lidClosed
            case .needsFingerprint: .needsFingerprint
            }
        case let .practiceDenied(reply): .practiceDenied(reply: reply)
        case .copyPasswords: copyScreen(model.passwordsCopy ?? .steps, model: model, offerSample: true)
        case let .setUpAgents(.passwords(count)):
            .setUpAgents(copiedTitle: FirstRunCopy.copied(count), copiedDetail: FirstRunCopy.mustAskAny, sampleOnly: sampleOnly, agents: agents)
        case .setUpAgents(.sample):
            .setUpAgents(copiedTitle: FirstRunCopy.sampleAdded, copiedDetail: FirstRunCopy.sampleDetail, sampleOnly: sampleOnly, agents: agents)
        case .ready: .ready(phoneLater: model.device?.alwaysOnMachineID == nil, sampleOnly: sampleOnly)
        case .finished: nil
        }
    }

    /// The only password is the sample, so first run offers the way back to copying his own.
    private var sampleOnly: Bool { model.status?.sampleOnly == true }

    /// "Set Up Agents on This Mac": running, failed, or else whatever the links say now.
    private var agents: AgentsButton {
        _ = cameBack
        switch model.agentsSetUpClick {
        case .working: return .working
        case let .failed(message): return model.agentsSetUp ? .done : .failed(message)
        case .idle: return model.agentsSetUp ? .done : .notYet
        }
    }

    private var actions: FirstRunActions {
        var actions = copyActions(model)
        actions.getStarted = { model.send(.getStarted) }
        actions.tryAgain = { model.send(.tryAgain) }
        actions.openTouchIDSettings = { NSWorkspace.shared.open(MacApprover.touchIDSettings) }
        actions.useSample = { Task { await model.useSamplePassword() } }
        actions.copyOwn = { model.send(.copyOwn) }
        actions.setUpAgents = { Task { await model.setUpAgentsOnThisMac() } }
        actions.continueOn = { model.send(.continueOn) }
        actions.done = {
            dismissWindow(id: "main")
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
                MacFirstRunView(screen: screen, problem: model.notice.flatMap { $0.kind == .information ? nil : $0.text }, actions: actions)
            }
        }
        .task { await model.loadStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in cameBack = .now }
        .onContinueUserActivity(ASCredentialExchangeActivity) { model.receive($0) }
    }
}

/// Keeps the window above Passwords while he follows its menu path.
private struct FloatingWhile: NSViewRepresentable {
    let isOn: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.level = isOn ? .floating : .normal }
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
