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
                    if phase == .active { delegate.relay?.start() } else if phase == .background { delegate.relay?.stop() }
                }
                .onChange(of: delegate.model.snapshot.setup) { _, setup in
                    if setup != .scanCode { UIApplication.shared.registerForRemoteNotifications() }
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
    private let approvesOnLockScreen = UserDefaults.standard.bool(forKey: "ApproveOnLockScreen")

    override init() {
        if UserDefaults.standard.bool(forKey: "Sample") {
            let sample = PhoneSampleBackend(setup: Self.sampleSetup)
            backend = sample; relay = nil
            model = PhoneModel(backend: sample, initial: sample.current)
        } else {
            #if targetEnvironment(simulator)
            let keys: any PhoneDeviceKeys = PhoneSoftwareKeys()
            #else
            let keys: any PhoneDeviceKeys = PhoneEnclaveKeys()
            #endif
            let real = PhoneRelayBackend(directory: Self.sharedDirectory, keys: keys,
                                         identity: { try RelayTLSIdentity.loadOrCreate(service: "com.joshpalmer.AgentKeyring.Phone.relay-tls.v2") })
            backend = real; relay = real
            model = PhoneModel(backend: real, initial: real.snapshot)
        }
        super.init()
        // For comparing screens with Paper in the simulator: -SampleTab logins, -SampleShow r1.
        if let tab = UserDefaults.standard.string(forKey: "SampleTab").flatMap(PhoneTab.init(rawValue:)) { model.tab = tab }
        model.shownRequestID = UserDefaults.standard.string(forKey: "SampleShow")
    }

    /// Shared with the notification service extension when the app group is signed in; else the app's own.
    private static var sharedDirectory: URL {
        let group = "group." + (Bundle.main.bundleIdentifier ?? "")
        return (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) ?? .applicationSupportDirectory)
            .appending(path: "AgentKeyring", directoryHint: .isDirectory)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let production = (Bundle.main.object(forInfoDictionaryKey: "AgentKeyringAPNSEnvironment") as? String) == "production"
        Task { try? await relay?.registerPush(token: deviceToken, topic: Bundle.main.bundleIdentifier ?? "", production: production) }
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
        guard let id = PhoneNotification.requestID(userInfo) else { return }
        await answer(id, action: action, reply: reply)
    }

    private func answer(_ id: String, action: String, reply: String?) async {
        switch action {
        case PhoneNotification.approveAction:
            if approvesOnLockScreen {
                do { try await backend.approve(id, reusingUnlock: true) }
                catch { model.shownRequestID = id }
            } else {
                model.shownRequestID = id
                await model.approve(id, reusingUnlock: true)
            }
        case PhoneNotification.denyAction:
            try? await backend.deny(id, reply: nil)
        case PhoneNotification.denyAndExplainAction:
            let words = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? await backend.deny(id, reply: words.isEmpty ? nil : words)
        default:
            model.shownRequestID = id
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
