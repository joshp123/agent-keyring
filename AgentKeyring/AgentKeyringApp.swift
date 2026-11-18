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
        // At launch, not when the window opens: the icon shows the waiting count.
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
                if model.status == nil { presentation.requestMainWindow() }
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

/// First run until this Mac has passed its test, then the Logins and Devices tabs.
private struct HomeWindow: View {
    let model: MirrorAppModel
    let presentation: AgentKeyringPresentation
    @State private var main: MacMainModel?

    private var setUp: Bool {
        if model.status == nil { return false }
        if case .passed = model.selfTest { return true }
        return false
    }

    var body: some View {
        Group {
            if setUp {
                if let main { MacMainWindowView(model: main) } else { ProgressView().padding(40) }
            } else {
                FirstRunHome(model: model)
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

    private var state: FirstRunState {
        let imported: FirstRunState.Import
        if model.isImporting || model.providerState == .requesting { imported = .importing }
        else if let status = model.status { imported = .done(logins: status.credentialItemCount) }
        else {
            switch model.providerState {
            case .unknown: imported = .needsAllow
            case .enabled: imported = .needsExport
            case .denied: imported = .blocked
            case .requesting: imported = .importing
            }
        }
        let test: FirstRunState.Test = switch model.selfTest {
        case let .passed(at): .passed(at)
        case let .failed(message): .failed(message)
        case .declined: .declined
        case .waiting, .notRun: .waiting
        }
        return FirstRunState(imported: imported, test: test, alwaysOnReady: model.device?.isJoined == true)
    }

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView().padding(40)
            } else {
                VStack(alignment: .leading) {
                    MacFirstRunView(state: state, allow: model.requestProviderEnablement, openPasswords: model.openPasswordsExport,
                        sendTestAgain: model.sendSelfTestAgain)
                    if let notice = model.notice, notice.kind != .information {
                        Text(notice.text).font(.callout).padding(.horizontal, 28).padding(.bottom, 20)
                    }
                }
            }
        }
        .task { await model.loadStatus() }
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
