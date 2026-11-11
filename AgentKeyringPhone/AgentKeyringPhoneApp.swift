import AgentKeyringApprovalUI
import SwiftUI
import UIKit
import UserNotifications

@main
struct AgentKeyringPhoneApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    private let importBackend: PhoneImportBackend
    @State private var keyringModel: PhoneKeyringModel

    init() {
        let backend = PhoneImportBackend()
        importBackend = backend
        _keyringModel = State(initialValue: PhoneKeyringModel(backend: backend, initial: backend.snapshot))
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView(model: keyringModel)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { importBackend.start() }
                    else if phase == .background { importBackend.stop() }
                }
                .task {
                    appDelegate.wake = { importBackend.start() }
                    appDelegate.receivedToken = { importBackend.receivedPushToken($0) }
                    appDelegate.registrationFailed = { importBackend.pushRegistrationFailed($0) }
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
        // Notifications open the app; every answer is checked and signed there.
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
        PhonePushReceipt.record(response.notification)
        await MainActor.run { wake?() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        PhonePushReceipt.record(notification)
        await MainActor.run { wake?() }
        return [.banner, .list, .sound]
    }
}
