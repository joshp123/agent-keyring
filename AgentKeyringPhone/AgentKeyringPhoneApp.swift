// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone app: Paper's screens, and the answers given from a held
// notification (Approve, Deny, Deny and Explain).

import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AgentKeyringDesign
import AgentKeyringEngine
import AgentKeyringSealing
import AgentKeyringSiteIcons
import AuthenticationServices
import SwiftUI
import UIKit
import UserNotifications

private struct PhoneSiteIconProvider: SiteIconProviding {
    func cachedIconData(forHost host: String, displayName: String) -> Data? {
        SiteIconStore.shared.cachedIconData(forHost: host, displayName: displayName)
    }

    func iconData(forHost host: String, displayName: String) async -> Data? {
        await SiteIconStore.shared.iconData(forHost: host, displayName: displayName)
    }
}

@main
struct AgentKeyringPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: delegate.model)
                .environment(\.siteIconProvider, PhoneSiteIconProvider())
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // In front: fetch what changed from the Mac, or until joined look for its join card.
                    if phase == .active {
                        if delegate.keyring != nil {
                            delegate.keyring?.startBackgroundWork()
                            KeyringDiagnosticLog.iPhone.collect()
                            Task { await delegate.model.recheckNotifications() }
                            Task {
                                let account = await CloudVault()?.fetchCloudUserRecordName()
                                await VersionCheck.checkIfDue(platform: "ios", accountSeed: account)
                            }
                        }
                    } else if phase == .background { delegate.keyring?.stopBackgroundWork() }
                }
                // Passwords' Export Data to Another App, with Agent Keyring chosen.
                .onContinueUserActivity(ASCredentialExchangeActivity) { delegate.receiveImport($0) }
                .onChange(of: delegate.model.snapshot.joined, initial: true) { _, joined in
                    // Joined: fetch the speech model so the first tap on the microphone works.
                    if joined { PhoneSpeechModel.shared.prepareSpeechModel() }
                }
        }
    }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let backend: any PhoneBackend
    /// The real backend; nil when the app runs on a sandbox world (`-Sandbox YES` or `-SandboxBundle <file>`).
    let keyring: PhoneKeyringEngine?
    let model: PhoneModel
    private(set) var watch: WatchLink?

    override init() {
        KeyringFont.configureNavigationAppearance()
        PhoneBackgroundTime.beginTask = { name in
            let id = UIApplication.shared.beginBackgroundTask(withName: name)
            return { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
        }
        if let relayURL = UserDefaults.standard.string(forKey: "AgentKeyringRelayURL") {
            RelayBoxClient.overrideURL = relayURL
        }
        // A sandbox world exists only in debug builds, for looking at the screens with no real keyring behind them.
        #if DEBUG
        let sandbox = Self.sandboxWorld()
        #else
        let sandbox: SandboxWorld? = nil
        #endif
        if let sandbox {
            backend = sandbox; keyring = nil
            model = PhoneModel(backend: sandbox, initial: sandbox.phoneSnapshot)
        } else {
            // A new install: removing the app cleared its own files but not its keychain. The keys stay.
            if !UserDefaults.standard.bool(forKey: "installed") {
                PhoneSharedContext(accessGroup: Self.keychainGroup).deleteSharedContext()
                UserDefaults.standard.set(true, forKey: "installed")
            }
            #if targetEnvironment(simulator)
            let keys: any PhoneDeviceKeys = PhoneSoftwareKeys()
            #else
            let keys: any PhoneDeviceKeys = PhoneEnclaveKeys(accessGroup: Self.keychainGroup)
            #endif
            let real = PhoneKeyringEngine(directory: .applicationSupportDirectory.appending(path: "AgentKeyring", directoryHint: .isDirectory),
                                    shared: PhoneSharedContext(accessGroup: Self.keychainGroup), keys: keys,
                                    identity: { try DeviceTLSIdentity.loadOrCreate(service: "com.joshpalmer.AgentKeyring.Phone.relay-tls.v2") })
            backend = real; keyring = real
            model = PhoneModel(backend: real, initial: real.snapshot)
        }
        super.init()
        PhoneSpeechModel.log = { event, fields in
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("speech", event, KeyValuePairs(dictionaryLiteral: ("detail", fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))))
        }
        if let keyring {
            keyring.onNeedPushAddress = { [weak self] in self?.askForPushAddress() }
            watch = WatchLink(keyring: keyring)
        }
        #if DEBUG
        // -SandboxExport <name>: this iPhone's keyring, every password "hunter2", into Documents/<name>.
        if let keyring, let name = UserDefaults.standard.string(forKey: "SandboxExport"), !name.isEmpty {
            do {
                try keyring.sandboxBundle().write(to: URL.documentsDirectory.appending(path: name), options: .atomic)
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Sandbox bundle written to Documents/\(name)"])
            } catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Sandbox bundle not written: \(error)"]) }
        }
        #endif
    }

    #if DEBUG
    /// -Sandbox YES: the built-in world. -SandboxBundle <file>: a keyring dumped with -SandboxExport.
    /// -SandboxStep <name>: a first-run or Apple Watch page (SandboxState.phoneFirstRunSteps, phoneWatchSteps).
    static func sandboxWorld() -> SandboxWorld? {
        let defaults = UserDefaults.standard
        var state: SandboxState
        if let path = defaults.string(forKey: "SandboxBundle"), !path.isEmpty {
            do { state = try PhoneKeyringEngine.sandboxState(from: Data(contentsOf: URL(fileURLWithPath: path))) } catch {
                fatalError("Couldn't read the sandbox bundle at \(path): \(error)")
            }
        } else if defaults.bool(forKey: "Sandbox") {
            state = .builtIn()
        } else {
            return nil
        }
        if let step = defaults.string(forKey: "SandboxStep") { state.showPhone(step: step) }
        return SandboxWorld(state)
    }
    #endif

    /// An export from Passwords: its token, for the keyring to fetch and seal.
    func receiveImport(_ activity: NSUserActivity) {
        guard activity.activityType == ASCredentialExchangeActivity,
              let token = (activity.userInfo?[ASCredentialImportToken] as? UUID) ?? (activity.userInfo?[ASCredentialImportToken] as? NSUUID).map({ $0 as UUID }) else {
            KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "An export from Passwords arrived with no token"])
            return
        }
        Task { await keyring?.receiveImport(token: token) }
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void) -> Bool {
        guard userActivity.activityType == ASCredentialExchangeActivity else { return false }
        receiveImport(userActivity)
        return true
    }

    /// Asks Apple for this iPhone's push address; first run says so if none has come 30 seconds later.
    func askForPushAddress() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let production = PushEnvironment.isProduction
        Task {
            do {
                try await keyring?.registerPush(token: deviceToken, topic: Bundle.main.bundleIdentifier ?? "", production: production)
                KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Push address registered with the Mac"])
            } catch { KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Could not register for pushes: \(error)"]) }
        }
    }

    /// A silent push: a request was answered or ended, so its notification goes wherever it was answered;
    /// or the Mac's lists changed ("rev"), so they are fetched.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if let id = PhoneNotification.ended(userInfo) { PhoneDeliveredNotifications.removeRequestNotification(id) }
        if CloudVault.isCloudNotification(userInfo) {
            await keyring?.cloudChanged()
            return .newData
        }
        // When the app is active and notifications are allowed, iOS runs the notification service
        // extension first and then delivers visible alert pushes to userNotificationCenter(_:willPresent:).
        // Returning here keeps in-app UI from reacting before the real iOS banner drops in.
        if application.applicationState == .active, Self.isVisibleAlertPush(userInfo) {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if status == .authorized || status == .provisional {
                return .noData
            }
        }
        guard userInfo["rev"] != nil || userInfo["akr"] != nil else { return .noData }
        await keyring?.received(userInfo)
        return .newData
    }

    private static func isVisibleAlertPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        if PhoneNotification.ended(userInfo) != nil { return false }
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return false }
        if aps["alert"] != nil { return true }
        if let mutable = aps["mutable-content"] as? Int, mutable != 0 { return true }
        if let mutable = aps["mutable-content"] as? Bool, mutable { return true }
        return false
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("app", "note", ["msg": "Apple refused a push address: \(error)"])
    }

    /// The keychain group the app shares with its notification service extension. None in the simulator.
    static var keychainGroup: String? {
        #if targetEnvironment(simulator)
        nil
        #else
        Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String
        #endif
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([requestCategory])
        return true
    }

    private var requestCategory: UNNotificationCategory {
        let approve = UNNotificationAction(
            identifier: PhoneNotification.approveAction, title: PhoneCopy.approve,
            // The app opens and Face ID finishes the approval, as Okta Verify does.
            options: [.authenticationRequired, .foreground],
            icon: UNNotificationActionIcon(systemImageName: "faceid"))
        let deny = UNNotificationAction(
            identifier: PhoneNotification.denyAction, title: PhoneCopy.deny,
            options: [.destructive], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        // Deny and Explain opens the app on the request, with the reply box and our microphone, so there is
        // one way to explain, wherever he starts.
        let explain = UNNotificationAction(
            identifier: PhoneNotification.denyAndExplainAction, title: PhoneCopy.denyAndExplain,
            options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "mic.fill"))
        return UNNotificationCategory(identifier: PhoneNotification.requestCategory, actions: [approve, deny, explain],
                                      intentIdentifiers: [], options: [])
    }

    /// The completion handler form: UIKit requires it to be called on the main
    /// thread, which the async form does not do, and the app was stopped for it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        // If the extension could not open the notice, the thread is still the request id.
        let thread = response.notification.request.content.threadIdentifier
        let id = PhoneNotification.requestID(userInfo) ?? (thread.isEmpty ? nil : thread)
        let done = UncheckedCompletion(completionHandler)
        let info = UncheckedUserInfo(userInfo)
        Task { @MainActor in
            if let id { await answer(id, userInfo: info.value, action: action) }
            done.call()
        }
    }

    private func answer(_ id: String, userInfo: [AnyHashable: Any], action: String) async {
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("notification", "action", ["request": id, "action": action])
        let keyring = self.keyring
        await model.handleNotification(id: id, action: action) {
            if action == PhoneNotification.denyAction {
                await keyring?.received(userInfo, pushDelivered: true)
            } else {
                await keyring?.notificationOpened(id, userInfo)
            }
            return keyring?.snapshot
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let info = UncheckedUserInfo(content.userInfo)
        // Passive outcome collapse notifications clear any waiting alert and update in-app state silently.
        if content.interruptionLevel == .passive || PhoneNotification.ended(content.userInfo) != nil {
            let id = PhoneNotification.requestID(content.userInfo) ?? (content.threadIdentifier.isEmpty ? nil : content.threadIdentifier)
            completionHandler([])
            Task { @MainActor in
                if let id { PhoneDeliveredNotifications.removeRequestNotification(id) }
                await keyring?.received(info.value, pushDelivered: true)
            }
            return
        }
        // With the app open, a request or rule change shows a banner; an outcome does not.
        // Present the native iOS banner first so in-app UI never jumps ahead of it.
        let options: UNNotificationPresentationOptions =
            content.categoryIdentifier == PhoneNotification.requestCategory || content.interruptionLevel == .timeSensitive
            ? [.banner, .list, .sound] : [.list]
        completionHandler(options)
        Task { @MainActor in await keyring?.received(info.value, pushDelivered: true) }
    }
}

/// A notification's user info, carried to the main actor.
struct UncheckedUserInfo: @unchecked Sendable {
    let value: [AnyHashable: Any]
    init(_ value: [AnyHashable: Any]) { self.value = value }
}

/// A completion handler carried to the main actor, where UIKit wants it called.
struct UncheckedCompletion: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
