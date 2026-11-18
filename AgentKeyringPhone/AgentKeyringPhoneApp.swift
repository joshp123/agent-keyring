// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone app: Paper's screens, and the answers given from a held
// notification (Approve, Deny, Deny and Explain).

import AgentKeyringApprovalUI
import AgentKeyringPhoneApprover
import AgentKeyringRelaySupport
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
                    if phase == .active {
                        delegate.relay?.start()
                        // Not admitted yet: the Mac may have issued a fresh invitation since.
                        if !delegate.model.snapshot.joined, let link = delegate.relay?.invitation() {
                            Task { await delegate.model.join(invitation: link) }
                        }
                    } else if phase == .background { delegate.relay?.stop() }
                }
                // The code on the Mac is an agentkeyring://join link, so the Camera app opens it here too.
                .onOpenURL { url in Task { await delegate.model.join(invitation: url.absoluteString) } }
                .onChange(of: delegate.model.snapshot.joined, initial: true) { _, joined in
                    // Joins by itself from the invitation the Mac left in iCloud Keychain.
                    if !joined, let link = delegate.relay?.invitation() { Task { await delegate.model.join(invitation: link) } }
                    if joined { delegate.askForPushAddress(); delegate.watch?.sendMembers() }
                }
                // Straight after joining, iOS's own question: the one tap iOS requires.
                .onChange(of: delegate.model.snapshot.asksAboutNotifications, initial: true) { _, asks in
                    if asks { Task { await delegate.model.askAboutNotifications(); await delegate.noteNotificationSettings() } }
                }
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
        if UserDefaults.standard.bool(forKey: "Sample") {
            let sample = PhoneSampleBackend(step: UserDefaults.standard.string(forKey: "SampleStep"))
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
        if let relay { watch = WatchLink(relay: relay) }
        // For comparing screens with Paper in the simulator: -SampleTab logins, -SampleShow r1.
        if let tab = UserDefaults.standard.string(forKey: "SampleTab").flatMap(PhoneTab.init(rawValue:)) { model.tab = tab }
        model.shownRequestID = UserDefaults.standard.string(forKey: "SampleShow")
    }

    private var pushAddress: Data?

    /// Asks Apple for this iPhone's push address, and notes if none has come 30 seconds later.
    func askForPushAddress() {
        UIApplication.shared.registerForRemoteNotifications()
        Task {
            try? await Task.sleep(for: .seconds(30))
            if pushAddress == nil { PhoneDiagnostics.note("Apple has not given a push address after 30 seconds") }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        pushAddress = deviceToken
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await MainActor.run { relay?.pushArrived() }
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        // If the extension could not open the notice, the thread is still the request id.
        let thread = response.notification.request.content.threadIdentifier
        guard let id = PhoneNotification.requestID(userInfo) ?? (thread.isEmpty ? nil : thread) else { return }
        await answer(id, action: action, reply: reply)
    }

    private func answer(_ id: String, action: String, reply: String?) async {
        switch action {
        case PhoneNotification.approveAction:
            // The Face ID that unlocked the phone a moment ago counts, so it is one look, not two.
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
        // With the app open, a request shows in the app; only its banner is needed, not the outcome's.
        return notification.request.content.categoryIdentifier == PhoneNotification.requestCategory ? [.banner, .list, .sound] : [.list]
    }
}
