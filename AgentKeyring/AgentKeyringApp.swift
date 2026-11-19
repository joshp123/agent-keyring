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
                await model.importMadeUpLoginsIfAsked()
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
            if model.firstRunFinished {
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
        .background(FloatingWhile(isOn: model.awaitingExport))
    }
}

private struct FirstRunHome: View {
    let model: MirrorAppModel
    let presentation: AgentKeyringPresentation
    @Environment(\.dismissWindow) private var dismissWindow
    /// Read again when the screens change (the lid) and when he comes back (a fingerprint added).
    @State private var lidClosed = MacApprover.lidIsClosed
    @State private var needsFingerprint = MacApprover.needsFingerprint

    private var step: FirstRunStep {
        if model.isImporting { return .copying }
        if let status = model.status {
            if case .passed = model.selfTest {} else if lidClosed {
                return .lidClosed
            } else if needsFingerprint {
                return .needsFingerprint
            }
            return switch model.selfTest {
            case .passed: .setUp(agentLine: FirstRunCopy.agentLine)
            case .declined: .practice(passwords: status.credentialItemCount, denied: true)
            case .waiting, .notRun: .practice(passwords: status.credentialItemCount, denied: false)
            }
        }
        if model.showsAutoFillHelp {
            return model.providerState == .notNow ? .autoFillNotNow(canAsk: model.canAskAgain) : .autoFill(canAsk: model.canAskAgain)
        }
        return model.exportTimedOut ? .noneArrived : .export
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView().padding(40)
            } else {
                MacFirstRunView(step: step, problem: model.notice.flatMap { $0.kind == .information ? nil : $0.text },
                    openPasswords: model.openPasswordsExport, showAutoFill: model.showAutoFillHelp,
                    askForAutoFill: model.askToTurnOnAutoFill, tryAgain: model.sendSelfTestAgain,
                    openTouchIDSettings: { NSWorkspace.shared.open(MacApprover.touchIDSettings) },
                    done: {
                        dismissWindow(id: "main")
                        model.finishFirstRun()
                        presentation.showMenuBarTip()
                    })
            }
        }
        .task { await model.loadStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            lidClosed = MacApprover.lidIsClosed
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            lidClosed = MacApprover.lidIsClosed
            needsFingerprint = MacApprover.needsFingerprint
        }
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
