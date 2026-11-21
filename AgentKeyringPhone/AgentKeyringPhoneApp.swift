// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone app: Paper's screens, and the answers given from a held
// notification (Approve, Deny, Deny and Explain).

import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import AgentKeyringRelaySupport
import AgentKeyringSealing
import SwiftUI
import UIKit
import UserNotifications

@main
struct AgentKeyringPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: delegate.model)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // In front: fetch what changed from the Mac, or until joined look for its join card.
                    if phase == .active {
                        delegate.keyring?.start()
                        PhoneDiagnostics.log.collect()
                        Task { await delegate.model.recheckNotifications() }
                    } else if phase == .background { delegate.keyring?.stop() }
                }
                // The code on the Mac is an agentkeyring://join link, so the Camera app opens it here too.
                .onOpenURL { url in Task { await delegate.model.join(invitation: url.absoluteString) } }
                .onChange(of: delegate.model.snapshot.joined, initial: true) { _, joined in
                    // Joined: ask Apple for a push address, and fetch the speech model so the first tap on the microphone works.
                    if joined { delegate.askForPushAddress(); PhoneSpeechModel.shared.prepare() }
                }
                // The Watch learns of every change to the list of devices, its own admission first of all.
                .onChange(of: delegate.model.snapshot.devices, initial: true) { delegate.watch?.sendMembers() }
                // Apple Watch follows the iPhone's notification settings.
                .onChange(of: delegate.model.snapshot.settings) { delegate.watch?.sendMembers() }
                .onChange(of: delegate.model.snapshot.logins) { delegate.watch?.sendMembers() }
        }
    }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let backend: any PhoneBackend
    /// The real backend; nil when the app runs on Paper's sample (`-Sample YES`).
    let keyring: PhoneKeyring?
    let model: PhoneModel
    private(set) var watch: WatchLink?

    override init() {
        // Paper's sample exists only in debug builds, for comparing screens in the simulator.
        #if DEBUG
        let sampled = UserDefaults.standard.bool(forKey: "Sample")
        #else
        let sampled = false
        #endif
        if sampled {
            let sample = PhoneSampleBackend(step: UserDefaults.standard.string(forKey: "SampleStep"))
            backend = sample; keyring = nil
            model = PhoneModel(backend: sample, initial: sample.current)
        } else {
            // A new install: removing the app cleared its own files but not its keychain. The keys stay.
            if !UserDefaults.standard.bool(forKey: "installed") {
                PhoneSharedContext(accessGroup: Self.keychainGroup).delete()
                UserDefaults.standard.set(true, forKey: "installed")
            }
            #if targetEnvironment(simulator)
            let keys: any PhoneDeviceKeys = PhoneSoftwareKeys()
            #else
            let keys: any PhoneDeviceKeys = PhoneEnclaveKeys(accessGroup: Self.keychainGroup)
            #endif
            let real = PhoneKeyring(directory: .applicationSupportDirectory.appending(path: "AgentKeyring", directoryHint: .isDirectory),
                                    shared: PhoneSharedContext(accessGroup: Self.keychainGroup), keys: keys,
                                    identity: { try RelayTLSIdentity.loadOrCreate(service: "com.joshpalmer.AgentKeyring.Phone.relay-tls.v2") })
            backend = real; keyring = real
            model = PhoneModel(backend: real, initial: real.snapshot)
        }
        super.init()
        PhoneSpeechModel.log = { event, fields in
            PhoneDiagnostics.log.note("speech", event, KeyValuePairs(dictionaryLiteral: ("detail", fields.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))))
        }
        if let keyring { watch = WatchLink(keyring: keyring) }
        #if DEBUG
        // For comparing screens with Paper in the simulator: -SampleTab logins, -SampleShow r1.
        if let tab = UserDefaults.standard.string(forKey: "SampleTab").flatMap(PhoneTab.init(rawValue:)) { model.tab = tab }
        model.shownRequestID = UserDefaults.standard.string(forKey: "SampleShow")
        #endif
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
                PhoneDiagnostics.note("Push address registered with the Mac")
            } catch { PhoneDiagnostics.note("Could not register for pushes: \(error)") }
        }
    }

    /// A silent push: a request was answered or ended, so its notification goes wherever it was answered;
    /// or the Mac's lists changed ("rev"), so they are fetched.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if let id = PhoneNotification.ended(userInfo) { PhoneNotifications.remove(id) }
        guard userInfo["rev"] != nil || userInfo["akr"] != nil else { return .noData }
        await keyring?.received(userInfo)
        return .newData
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
            if let id { await keyring?.notificationOpened(id, info.value); await answer(id, action: action) }
            done.call()
        }
    }

    private func answer(_ id: String, action: String) async {
        PhoneDiagnostics.log.note("notification", "action", ["request": id, "action": action])
        switch action {
        case PhoneNotification.approveAction:
            // The Face ID that unlocked the phone a moment ago counts, so it is one look, not two.
            model.shownRequestID = id
            await model.approve(id, reusingUnlock: true)
        case PhoneNotification.denyAction:
            do { try await backend.deny(id, reply: nil); PhoneDiagnostics.note("Deny from the notification: sent") }
            catch { PhoneDiagnostics.note("Deny from the notification: failed, \(error)") }
        case PhoneNotification.denyAndExplainAction:
            model.explain(id)
        default:
            model.shownRequestID = id
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = UncheckedUserInfo(notification.request.content.userInfo)
        await keyring?.received(info.value)
        // With the app open, a request or rule change shows a banner; an outcome does not.
        let content = notification.request.content
        return content.categoryIdentifier == PhoneNotification.requestCategory || content.interruptionLevel == .timeSensitive
            ? [.banner, .list, .sound] : [.list]
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
