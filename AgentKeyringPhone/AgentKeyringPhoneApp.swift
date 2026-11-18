// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone app: Paper's screens, and the answers given from a held
// notification (Approve, Deny, Deny and Explain).

import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import AgentKeyringRelaySupport
import LocalAuthentication
import OSLog
import SwiftUI
import UIKit
import UserNotifications

@main
struct AgentKeyringPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if UserDefaults.standard.bool(forKey: "SampleCard"), let request = delegate.model.request(id: "r1") {
                // The held notification's layout alone, at Paper's 386 pt, for comparing with the board.
                PhoneNotificationCard(request: request)
                    .frame(width: 386).background(.background, in: .rect(cornerRadius: 28))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(white: 0.5))
            } else {
            PhoneRootView(model: delegate.model)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { delegate.relay?.start() } else if phase == .background { delegate.relay?.stop() }
                }
                // The code on the Mac is an agentkeyring://join link, so the Camera app opens it here too.
                .onOpenURL { url in Task { await delegate.model.join(scannedCode: url.absoluteString) } }
                .onChange(of: delegate.model.snapshot.setup, initial: true) { _, setup in
                    if setup != .scanCode { UIApplication.shared.registerForRemoteNotifications() }
                }
            }
        }
    }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let backend: any PhoneBackend
    /// The real backend; nil when the app runs on Paper's sample (`-Sample YES`).
    let relay: PhoneRelayBackend?
    let model: PhoneModel

    /// Approve on the Lock Screen either finishes there (Face ID unlocks the
    /// phone, and that unlock is reused for the approval) or opens the app
    /// first. Which one iOS allows is settled on a real iPhone; launch with
    /// `-ApproveOnLockScreen YES` to try the first.
    /// Kept in the app's own defaults, because iOS relaunches the app without its arguments to handle an action.
    private let approvesOnLockScreen: Bool = {
        let defaults = UserDefaults.standard
        if let given = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["ApproveOnLockScreen"] {
            defaults.set(given, forKey: "ApproveOnLockScreen")
        }
        return defaults.bool(forKey: "ApproveOnLockScreen")
    }()

    override init() {
        if UserDefaults.standard.bool(forKey: "Sample") {
            let sample = PhoneSampleBackend(setup: Self.sampleSetup)
            backend = sample; relay = nil
            model = PhoneModel(backend: sample, initial: sample.current)
        } else {
            #if targetEnvironment(simulator)
            let keys: any PhoneDeviceKeys = PhoneSoftwareKeys()
            #else
            let keys: any PhoneDeviceKeys = PhoneEnclaveKeys(accessGroup: Self.keychainGroup)
            #endif
            let real = PhoneRelayBackend(directory: .applicationSupportDirectory.appending(path: "AgentKeyring", directoryHint: .isDirectory),
                                         shared: PhoneSharedContext(accessGroup: Self.keychainGroup), keys: keys,
                                         identity: { try RelayTLSIdentity.loadOrCreate(service: "com.joshpalmer.AgentKeyring.Phone.relay-tls.v2") })
            backend = real; relay = real
            model = PhoneModel(backend: real, initial: real.snapshot)
        }
        super.init()
        // For comparing screens with Paper in the simulator: -SampleTab logins, -SampleShow r1.
        if let tab = UserDefaults.standard.string(forKey: "SampleTab").flatMap(PhoneTab.init(rawValue:)) { model.tab = tab }
        model.shownRequestID = UserDefaults.standard.string(forKey: "SampleShow")
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let production = (Bundle.main.object(forInfoDictionaryKey: "AgentKeyringAPNSEnvironment") as? String) == "production"
        Task {
            do {
                try await relay?.registerPush(token: deviceToken, topic: Bundle.main.bundleIdentifier ?? "", production: production)
                PhoneDiagnostics.note("Push address registered with the relay")
            } catch { PhoneDiagnostics.note("Could not register for pushes: \(error)") }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PhoneDiagnostics.note("Apple refused a push address: \(error)")
    }

    /// The keychain group the app shares with its notification service extension. None in the simulator.
    static var keychainGroup: String? {
        #if targetEnvironment(simulator)
        nil
        #else
        Bundle.main.object(forInfoDictionaryKey: "AgentKeyringKeychainGroup") as? String
        #endif
    }

    /// `-SampleSetup scanCode` starts the sample at that step of first run.
    private static var sampleSetup: PhoneSetup {
        switch UserDefaults.standard.string(forKey: "SampleSetup") {
        case "scanCode": .scanCode
        case "turnOnNotifications": .turnOnNotifications
        case "offerWatch": .offerWatch
        default: .ready
        }
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([requestCategory])
        // With -CheckNotices YES the app opens the relay's notices on the Lock Screen
        // itself, as the extension does, and notes what it read: the check for a
        // sitting, and in the simulator the only way, as its extension cannot reach the app's keys.
        if UserDefaults.standard.bool(forKey: "CheckNotices") {
            Task {
                for note in await center.deliveredNotifications() {
                    let words = PhoneRelayBackend.notifiedRequest(note.request.content.userInfo, shared: PhoneSharedContext(accessGroup: Self.keychainGroup)) {
                        #if targetEnvironment(simulator)
                        try PhoneSoftwareKeys().openNotice($0, deviceKeyID: $1)
                        #else
                        try PhoneEnclaveKeys(accessGroup: Self.keychainGroup).openNotice($0, deviceKeyID: $1)
                        #endif
                    }
                    PhoneDiagnostics.note("Notice check: \(words.map { "\($0.request.login.site) / \(PhoneCopy.notificationSubtitle($0.request.agent)) / \(PhoneCopy.notificationBody($0.request)) / outcome by \($0.answeredBy ?? "-")" } ?? "not opened")")
                }
            }
        }
        return true
    }

    private var requestCategory: UNNotificationCategory {
        let approve = UNNotificationAction(
            identifier: PhoneNotification.approveAction, title: PhoneCopy.approve,
            options: approvesOnLockScreen ? [.authenticationRequired] : [.authenticationRequired, .foreground],
            icon: UNNotificationActionIcon(systemImageName: "faceid"))
        let deny = UNNotificationAction(
            identifier: PhoneNotification.denyAction, title: PhoneCopy.deny,
            options: [.destructive], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let explain = UNTextInputNotificationAction(
            identifier: PhoneNotification.denyAndExplainAction, title: PhoneCopy.denyAndExplain,
            options: [.destructive, .authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "mic.fill"),
            textInputButtonTitle: PhoneCopy.deny, textInputPlaceholder: PhoneCopy.explainPlaceholder)
        return UNNotificationCategory(identifier: PhoneNotification.requestCategory, actions: [approve, deny, explain],
                                      intentIdentifiers: [], options: [])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        // If the extension could not open the notice, the thread is still the request id.
        let thread = response.notification.request.content.threadIdentifier
        guard let id = PhoneNotification.requestID(userInfo) ?? (thread.isEmpty ? nil : thread) else { return }
        await answer(id, action: action, reply: reply)
    }

    private func answer(_ id: String, action: String, reply: String?) async {
        switch action {
        case PhoneNotification.approveAction:
            if approvesOnLockScreen, let relay {
                do {
                    try await relay.approveFromLockScreen(id)
                    PhoneDiagnostics.note("Approve on the Lock Screen: approved, with the unlock's Face ID")
                } catch {
                    let code = (error as? LAError)?.code.rawValue ?? (error as NSError).code
                    PhoneDiagnostics.note("Approve on the Lock Screen: failed, \((error as NSError).domain) \(code); offered the app instead")
                    await askToOpen(id)
                }
            } else {
                model.shownRequestID = id
                await model.approve(id, reusingUnlock: true)
                PhoneDiagnostics.note("Approve opened the app; \(model.failure == nil ? "answered" : "failed: \(model.failure!)")")
            }
        case PhoneNotification.denyAction:
            do { try await backend.deny(id, reply: nil); PhoneDiagnostics.note("Deny from the notification: sent") }
            catch { PhoneDiagnostics.note("Deny from the notification: failed, \(error)") }
        case PhoneNotification.denyAndExplainAction:
            let words = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do { try await backend.deny(id, reply: words.isEmpty ? nil : words); PhoneDiagnostics.note("Deny and Explain: sent, \(words.count) characters") }
            catch { PhoneDiagnostics.note("Deny and Explain: failed, \(error)") }
        default:
            model.shownRequestID = id
        }
    }

    /// Approve could not finish on the Lock Screen: a notification for the same
    /// request whose tap opens it in the app.
    private func askToOpen(_ id: String) async {
        let content = UNMutableNotificationContent()
        content.title = model.request(id: id)?.login.site ?? PhoneCopy.appName
        content.body = PhoneCopy.openToApprove
        content.threadIdentifier = id
        content.userInfo = ["id": id]
        content.interruptionLevel = .timeSensitive
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "open-" + id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // With the app open, a request shows in the app; only its banner is needed, not the outcome's.
        notification.request.content.categoryIdentifier == PhoneNotification.requestCategory ? [.banner, .list, .sound] : [.list]
    }
}
