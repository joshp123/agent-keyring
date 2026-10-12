import AgentKeyringApprovalCore
import CloudKit
import Foundation
import OSLog
import UserNotifications

private let notificationLogger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "NotificationService")

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let completionLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallbackContent: UNMutableNotificationContent?
    private var fetchOperation: CKFetchRecordsOperation?

    override func didReceive(_ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard request.content.categoryIdentifier == ApprovalCloudRecords.notificationCategory,
            let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        content.title = "Login approval"
        content.body = "An agent is asking for a login. Open to review."
        content.subtitle = ""
        content.interruptionLevel = .timeSensitive
        completionLock.lock()
        self.contentHandler = contentHandler
        fallbackContent = content
        completionLock.unlock()

        guard let recordID = ApprovalCloudRecords.requestID(fromRemoteNotification: content.userInfo) else {
            finish()
            return
        }
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        // No desiredKeys restriction: the full record includes encryptedValues.
        operation.perRecordResultBlock = { [weak self] _, result in
            switch result {
            case .success(let record):
                guard let fields = ApprovalCloudRecords.signedFields(from: record),
                    Date().timeIntervalSince1970 < TimeInterval(fields.expiresAt) else {
                    notificationLogger.error("Notification request malformed or expired")
                    self?.finish()
                    return
                }
                self?.finish(fields: fields)
            case .failure(let error):
                Self.logFetchFailure(error)
                self?.finish()
            }
        }
        operation.fetchRecordsResultBlock = { [weak self] result in
            if case .failure(let error) = result {
                Self.logFetchFailure(error)
                self?.finish()
            }
        }
        completionLock.lock()
        fetchOperation = operation
        let pending = self.contentHandler != nil
        completionLock.unlock()
        if pending {
            CKContainer(identifier: ApprovalCloudRecords.containerIdentifier).privateCloudDatabase.add(operation)
        } else {
            operation.cancel()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        notificationLogger.error("Notification fetch timed out")
        finish()
    }

    private func finish(fields: ApprovalSignedFields? = nil) {
        completionLock.lock()
        guard let handler = contentHandler, let content = fallbackContent else {
            completionLock.unlock()
            return
        }
        if let fields {
            content.title = fields.notificationTitle
            content.body = fields.notificationBody
            content.subtitle = fields.notificationSubtitle
        }
        let operation = fetchOperation
        contentHandler = nil
        fallbackContent = nil
        fetchOperation = nil
        completionLock.unlock()
        handler(content)
        operation?.cancel()
    }

    private static func logFetchFailure(_ error: Error) {
        let error = error as NSError
        notificationLogger.error("Notification fetch failed domain=\(error.domain, privacy: .public) code=\(error.code)")
    }
}
