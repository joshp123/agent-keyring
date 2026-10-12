import CloudKit
import Foundation

public enum ApprovalCloudRecords {
    public static let requestZone = CKRecordZone.ID(zoneName: "ApprovalRequests", ownerName: CKCurrentUserDefaultName)
    public static let decisionZone = CKRecordZone.ID(zoneName: "ApprovalDecisions", ownerName: CKCurrentUserDefaultName)

    public static func requestID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: requestZone)
    }

    public static func decisionID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: decisionZone)
    }

    public static func request(_ request: ApprovalRequest) -> CKRecord {
        let record = CKRecord(recordType: "ApprovalRequest", recordID: requestID(request.id))
        record["agentDisplayLabel"] = request.agentDisplayLabel as CKRecordValue
        record["field"] = request.field.rawValue as CKRecordValue
        record["action"] = request.action.rawValue as CKRecordValue
        record["oneTimeValue"] = request.oneTimeValue as CKRecordValue
        record["expiresAt"] = NSNumber(value: request.expiresAt)
        record.encryptedValues["site"] = request.site as CKRecordValue
        record.encryptedValues["account"] = request.account as CKRecordValue
        return record
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
