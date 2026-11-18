// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// The iPhone app: Paper's screens, and the answers given from a held
// notification (Approve, Deny, Deny and Explain).

import AgentKeyringApprovalUI
import SwiftUI
import UIKit
import UserNotifications

@main
struct AgentKeyringPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: delegate.model)
        }
    }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let backend: any PhoneBackend
    let model: PhoneModel

    /// Approve on the Lock Screen either finishes there (Face ID unlocks the
    /// phone, and that unlock is reused for the approval) or opens the app
    /// first. Which one iOS allows is settled on a real iPhone; launch with
    /// `-ApproveOnLockScreen YES` to try the first.
    private let approvesOnLockScreen = UserDefaults.standard.bool(forKey: "ApproveOnLockScreen")

    override init() {
        let sample = PhoneSampleBackend(setup: Self.sampleSetup)
        backend = sample
        model = PhoneModel(backend: sample, initial: sample.current)
        super.init()
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
