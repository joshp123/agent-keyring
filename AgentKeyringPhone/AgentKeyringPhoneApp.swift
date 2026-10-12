import AgentKeyringApprovalCore
import CloudKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct AgentKeyringPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PhoneApprovalView(model: .shared)
                .task { await PhoneApprovalModel.shared.prepare() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await PhoneApprovalModel.shared.prepare() }
                    }
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
        let requestID: CKRecord.ID?
        if response.notification.request.content.categoryIdentifier == ApprovalCloudRecords.notificationCategory,
            let notification = CKNotification(fromRemoteNotificationDictionary:
                response.notification.request.content.userInfo) as? CKQueryNotification,
            notification.containerIdentifier == ApprovalCloudRecords.containerIdentifier,
            notification.subscriptionID == ApprovalCloudRecords.requestSubscriptionIdentifier,
            notification.databaseScope == .private,
            notification.queryNotificationReason == .recordCreated,
            let recordID = notification.recordID, recordID.zoneID == ApprovalCloudRecords.requestZone {
            requestID = recordID
        } else {
            requestID = nil
        }
        await PhoneApprovalModel.shared.respond(to: requestID, choice: choice)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
