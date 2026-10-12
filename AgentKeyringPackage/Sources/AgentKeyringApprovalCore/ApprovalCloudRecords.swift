import CloudKit
import Foundation

public enum ApprovalCloudRecords {
    public static let containerIdentifier = "iCloud.com.joshpalmer.AgentKeyring"
    public static let requestSubscriptionIdentifier = "agent-keyring-approval-requests-v1"
    public static let notificationCategory = "AGENT_KEYRING_APPROVAL"
    public static let approveActionIdentifier = "APPROVE"
    public static let denyActionIdentifier = "DENY"
    public static let blockActionIdentifier = "BLOCK_THIS_LOGIN"
    public static let requestZone = CKRecordZone.ID(zoneName: "ApprovalRequests", ownerName: CKCurrentUserDefaultName)
    public static let decisionZone = CKRecordZone.ID(zoneName: "ApprovalDecisions", ownerName: CKCurrentUserDefaultName)

    public static func requestID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: requestZone)
    }

    public static func decisionID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: decisionZone)
    }

    /// Both the service extension and action handler resolve the same CloudKit ID.
    public static func requestID(fromRemoteNotification userInfo: [AnyHashable: Any]) -> CKRecord.ID? {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
            notification.containerIdentifier == containerIdentifier,
            notification.subscriptionID == requestSubscriptionIdentifier,
            notification.databaseScope == .private,
            notification.queryNotificationReason == .recordCreated,
            let recordID = notification.recordID, recordID.zoneID == requestZone else { return nil }
        return recordID
    }

    public static func request(_ request: ApprovalRequest) -> CKRecord {
        let record = CKRecord(recordType: "ApprovalRequest", recordID: requestID(request.id))
        record["agentDisplayLabel"] = request.agentDisplayLabel as CKRecordValue
        record["field"] = request.field.rawValue as CKRecordValue
        record["action"] = request.action.rawValue as CKRecordValue
        record["oneTimeValue"] = request.oneTimeValue as CKRecordValue
        record["expiresAt"] = NSNumber(value: request.expiresAt)
        if let context = request.requesterContext {
            record["hasRequesterContext"] = NSNumber(value: true)
            if let session = context.session {
                record.encryptedValues["harnessPID"] = NSNumber(value: session.processIdentifier)
                record.encryptedValues["harnessStartSeconds"] = NSNumber(value: session.processStartTime.seconds)
                record.encryptedValues["harnessStartMicroseconds"] = NSNumber(value: session.processStartTime.microseconds)
            }
            record.encryptedValues["workingDirectory"] = context.workingDirectory as CKRecordValue?
        }
        record.encryptedValues["site"] = request.site as CKRecordValue
        record.encryptedValues["account"] = request.account as CKRecordValue
        return record
    }

    /// Decodes the full fetched record, including encrypted fields. Push fields alone
    /// are not sufficient to sign an approval.
    public static func signedFields(from record: CKRecord) -> ApprovalSignedFields? {
        guard record.recordType == "ApprovalRequest",
            let id = UUID(uuidString: record.recordID.recordName), record.recordID == requestID(id),
            let agentLabel = record["agentDisplayLabel"] as? String,
            let site = record.encryptedValues["site"] as? String,
            let account = record.encryptedValues["account"] as? String,
            let fieldText = record["field"] as? String, let field = AgentCredentialField(rawValue: fieldText),
            let actionText = record["action"] as? String, let action = ApprovalAction(rawValue: actionText),
            let nonce = record["oneTimeValue"] as? Data, nonce.count == 32,
            let expiry = record["expiresAt"] as? NSNumber,
            CFGetTypeID(expiry) != CFBooleanGetTypeID(),
            expiry == NSNumber(value: expiry.int64Value)
        else { return nil }
        let context: ApprovalRequesterContext?
        if (record["hasRequesterContext"] as? NSNumber)?.boolValue == true {
            let session: HarnessSession?
            if let pid = record.encryptedValues["harnessPID"] as? NSNumber,
                let seconds = record.encryptedValues["harnessStartSeconds"] as? NSNumber,
                let microseconds = record.encryptedValues["harnessStartMicroseconds"] as? NSNumber {
                guard pid.int32Value > 0, pid == NSNumber(value: pid.int32Value),
                    seconds == NSNumber(value: seconds.uint64Value),
                    microseconds.uint64Value < 1_000_000 else { return nil }
                session = HarnessSession(processIdentifier: pid.int32Value,
                    processStartTime: HarnessProcessStartTime(seconds: seconds.uint64Value, microseconds: microseconds.uint64Value))
            } else {
                guard record.encryptedValues["harnessPID"] == nil,
                    record.encryptedValues["harnessStartSeconds"] == nil,
                    record.encryptedValues["harnessStartMicroseconds"] == nil else { return nil }
                session = nil
            }
            context = ApprovalRequesterContext(session: session,
                workingDirectory: record.encryptedValues["workingDirectory"] as? String)
        } else { context = nil }
        return ApprovalSignedFields(requestID: id, agentDisplayLabel: agentLabel, site: site,
            account: account, field: field, action: action, oneTimeValue: nonce, expiresAt: expiry.int64Value, requesterContext: context)
    }

    /// Saved by the iPhone, whose notification service extension fetches the record
    /// to decode encrypted fields and set the time-sensitive interruption level.
    public static func requestSubscription() -> CKQuerySubscription {
        let subscription = CKQuerySubscription(recordType: "ApprovalRequest", predicate: NSPredicate(value: true),
            subscriptionID: requestSubscriptionIdentifier, options: .firesOnRecordCreation)
        subscription.zoneID = requestZone
        let notification = CKSubscription.NotificationInfo()
        notification.title = "Login approval"
        notification.alertBody = "An agent is asking for a login. Open to review."
        notification.category = notificationCategory
        notification.shouldSendMutableContent = true
        notification.shouldSendContentAvailable = false
        notification.desiredKeys = []
        subscription.notificationInfo = notification
        return subscription
    }

    public static func decision(_ decision: ApprovalDecision) -> CKRecord {
        let record = CKRecord(recordType: "ApprovalDecision", recordID: decisionID(decision.requestID))
        record["choice"] = decision.choice.rawValue as CKRecordValue
        record["devicePublicKey"] = decision.devicePublicKey as CKRecordValue
        record["signature"] = decision.signature as CKRecordValue
        return record
    }

    public static func decision(from record: CKRecord, for request: ApprovalRequest) -> ApprovalDecision? {
        guard record.recordType == "ApprovalDecision", record.recordID == decisionID(request.id),
            let choiceText = record["choice"] as? String, let choice = ApprovalChoice(rawValue: choiceText),
            let publicKey = record["devicePublicKey"] as? Data, let signature = record["signature"] as? Data
        else { return nil }
        return ApprovalDecision(requestID: request.id, choice: choice, devicePublicKey: publicKey, signature: signature)
    }
}
