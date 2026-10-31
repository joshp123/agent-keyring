import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AuthenticationServices
import CloudKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct AgentKeyringPhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    private let designScenario = PhoneDesignScenario.fromLaunchArguments()
    private let importBackend: PhoneImportBackend?
    @State private var keyringModel: PhoneKeyringModel

    init() {
        let model: PhoneKeyringModel
        if let scenario = PhoneDesignScenario.fromLaunchArguments() {
            importBackend = nil
            model = scenario.makeModel()
        } else {
            let backend = PhoneImportBackend()
            importBackend = backend
            model = PhoneKeyringModel(backend: backend, initial: backend.snapshot)
        }
        _keyringModel = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: keyringModel, openRequestID: designScenario?.pushedRequestID)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { importBackend?.start() }
                    else if phase == .background { importBackend?.stop() }
                }
                .task {
                    appDelegate.wake = { importBackend?.start() }
                    appDelegate.receivedToken = { importBackend?.receivedPushToken($0) }
                    appDelegate.registrationFailed = { importBackend?.pushRegistrationFailed($0) }
                }
                .onContinueUserActivity(ASCredentialExchangeActivity) { activity in
                    importBackend?.receive(activity)
                }
        }
    }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var wake: (() -> Void)?
    var receivedToken: ((Data) -> Void)?
    var registrationFailed: ((Error) -> Void)?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Old CloudKit actions must never authorize in the background. R4.4's
        // notification is only a wake-up; every answer comes from the open app.
        UNUserNotificationCenter.current().setNotificationCategories([])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        receivedToken?(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        registrationFailed?(error)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        await MainActor.run { wake?() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { wake?() }
        return [.banner, .list, .sound]
    }
}
