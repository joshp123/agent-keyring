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
                    // In front: follow the relay, or until joined keep looking for the Mac's invitation.
                    if phase == .active {
                        delegate.relay?.start()
                        PhoneDiagnostics.log.collect()
                        Task { await delegate.model.recheckNotifications() }
                    } else if phase == .background { delegate.relay?.stop() }
                }
                // The code on the Mac is an agentkeyring://join link, so the Camera app opens it here too.
                .onOpenURL { url in Task { await delegate.model.join(invitation: url.absoluteString) } }
                .onChange(of: delegate.model.snapshot.joined, initial: true) { _, joined in
                    if joined { delegate.askForPushAddress() }
                }
                // The Watch learns of every change to the list of devices, its own admission first of all.
                .onChange(of: delegate.model.snapshot.devices, initial: true) { delegate.watch?.sendMembers() }
                // Apple Watch follows the iPhone's notification settings.
                .onChange(of: delegate.model.snapshot.settings) { delegate.watch?.sendMembers() }
                .onChange(of: delegate.model.snapshot.logins) { delegate.watch?.sendMembers() }
                .task { await delegate.noteNotificationSettings() }
        }
    }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let backend: any PhoneBackend
    /// The real backend; nil when the app runs on Paper's sample (`-Sample YES`).
    let relay: PhoneRelayBackend?
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
            backend = sample; relay = nil
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
            let real = PhoneRelayBackend(directory: .applicationSupportDirectory.appending(path: "AgentKeyring", directoryHint: .isDirectory),
                                         shared: PhoneSharedContext(accessGroup: Self.keychainGroup), keys: keys,
                                         identity: { try RelayTLSIdentity.loadOrCreate(service: "com.joshpalmer.AgentKeyring.Phone.relay-tls.v2") })
            backend = real; relay = real
            model = PhoneModel(backend: real, initial: real.snapshot)
        }
        super.init()
        if let relay { watch = WatchLink(relay: relay) }
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
                try await relay?.registerPush(token: deviceToken, topic: Bundle.main.bundleIdentifier ?? "", production: production)
                PhoneDiagnostics.note("Push address registered with the relay")
            } catch { PhoneDiagnostics.note("Could not register for pushes: \(error)") }
        }
    }

    /// A silent push: a request was answered or ended. Its notification goes, wherever it was answered.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let id = PhoneNotification.ended(userInfo) else { return .noData }
        PhoneNotifications.remove(id)
        relay?.notificationOpened(id)  // fetches the request's outcome, if this iPhone has joined
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
        let explain = UNTextInputNotificationAction(
            identifier: PhoneNotification.denyAndExplainAction, title: PhoneCopy.denyAndExplain,
            options: [.destructive, .authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "mic.fill"),
            textInputButtonTitle: PhoneCopy.deny, textInputPlaceholder: PhoneCopy.explainPlaceholder)
        return UNNotificationCategory(identifier: PhoneNotification.requestCategory, actions: [approve, deny, explain],
                                      intentIdentifiers: [], options: [])
    }

    /// The completion handler form: UIKit requires it to be called on the main
    /// thread, which the async form does not do, and the app was stopped for it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        // If the extension could not open the notice, the thread is still the request id.
        let thread = response.notification.request.content.threadIdentifier
        let id = PhoneNotification.requestID(userInfo) ?? (thread.isEmpty ? nil : thread)
        let done = UncheckedCompletion(completionHandler)
        Task { @MainActor in
            relay?.pushArrived()
            if let id { await answer(id, action: action, reply: reply) }
            done.call()
        }
    }

    private func answer(_ id: String, action: String, reply: String?) async {
        switch action {
        case PhoneNotification.approveAction:
            // The Face ID that unlocked the phone a moment ago counts, so it is one look, not two.
            relay?.notificationOpened(id)
            model.shownRequestID = id
            await model.approve(id, reusingUnlock: true)
        case PhoneNotification.denyAction:
            do { try await backend.deny(id, reply: nil); PhoneDiagnostics.note("Deny from the notification: sent") }
            catch { PhoneDiagnostics.note("Deny from the notification: failed, \(error)") }
        case PhoneNotification.denyAndExplainAction:
            let words = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            do { try await backend.deny(id, reply: words.isEmpty ? nil : words); PhoneDiagnostics.note("Deny and Explain: sent, \(words.count) characters") }
            catch { PhoneDiagnostics.note("Deny and Explain: failed, \(error)") }
        default:
            relay?.notificationOpened(id)
            model.shownRequestID = id
        }
    }

    /// What iOS allows this app, read from the phone so nobody has to look in Settings.
    func noteNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        func word(_ setting: UNNotificationSetting) -> String {
            switch setting { case .enabled: "on"; case .disabled: "off"; default: "not supported" }
        }
        PhoneDiagnostics.note("Notifications: allowed \(settings.authorizationStatus == .authorized ? "yes" : "no (\(settings.authorizationStatus.rawValue))"), Lock Screen \(word(settings.lockScreenSetting)), banners \(word(settings.alertSetting)), sound \(word(settings.soundSetting)), Time Sensitive \(word(settings.timeSensitiveSetting)), previews \(settings.showPreviewsSetting == .always ? "always" : settings.showPreviewsSetting == .whenAuthenticated ? "when unlocked" : "never")")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if notification.request.trigger is UNPushNotificationTrigger { await MainActor.run { relay?.pushArrived() } }
        // With the app open, a request or rule change shows a banner; an outcome does not.
        let content = notification.request.content
        return content.categoryIdentifier == PhoneNotification.requestCategory || content.interruptionLevel == .timeSensitive
            ? [.banner, .list, .sound] : [.list]
    }
}

/// A completion handler carried to the main actor, where UIKit wants it called.
struct UncheckedCompletion: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
