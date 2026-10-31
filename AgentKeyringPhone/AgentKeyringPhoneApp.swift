import AgentKeyringApprovalCore
import AgentKeyringApprovalUI
import AuthenticationServices
import CloudKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct AgentKeyringPhoneApp: App {
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
                .onContinueUserActivity(ASCredentialExchangeActivity) { activity in
                    importBackend?.receive(activity)
                }
        }
    }
}

@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: ApprovalCloudRecords.notificationCategory,
                actions: [
                    UNNotificationAction(identifier: ApprovalCloudRecords.approveActionIdentifier,
                        title: "Approve", options: [.authenticationRequired]),
                    UNNotificationAction(identifier: ApprovalCloudRecords.denyActionIdentifier,
                        title: "Deny", options: [.authenticationRequired]),
                    UNNotificationAction(identifier: ApprovalCloudRecords.blockActionIdentifier,
                        title: "Block this login", options: [.authenticationRequired])
                ],
                intentIdentifiers: [], options: []
            )
        ])
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        logPhoneFailure(error, operation: "Push registration")
        PhoneApprovalModel.shared.notificationStatus = "Push registration failed"
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let choice: ApprovalChoice
        switch response.actionIdentifier {
        case ApprovalCloudRecords.approveActionIdentifier: choice = .approve
        case ApprovalCloudRecords.denyActionIdentifier: choice = .deny
        case ApprovalCloudRecords.blockActionIdentifier: choice = .blockThisLogin
        default:
            return
        }
        let content = response.notification.request.content
        let requestID = content.categoryIdentifier == ApprovalCloudRecords.notificationCategory
            ? ApprovalCloudRecords.requestID(fromRemoteNotification: content.userInfo) : nil
        await PhoneApprovalModel.shared.respond(to: requestID, choice: choice)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
