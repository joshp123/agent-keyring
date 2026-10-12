import AgentKeyringFeature
import CloudKit

@MainActor
public final class InMemoryApprovalCloudDatabase: ApprovalCloudDatabase {
    public enum Operation: Hashable, Sendable { case saveRecord, fetchRecord, deleteRecord, saveSubscription }
    public private(set) var records: [CKRecord.ID: CKRecord] = [:]
    public private(set) var subscriptions: [String: CKSubscription] = [:]
    public private(set) var fetchedRecordIDs: [CKRecord.ID] = []
    public private(set) var deletedRecordIDs: [CKRecord.ID] = []
    public var failures: [Operation: [any Error]] = [:]
    public var beforeSave: ((CKRecord) async -> Void)?

    public init() {}

    private func failIfRequested(_ operation: Operation) throws {
        guard var errors = failures[operation], !errors.isEmpty else { return }
        let error = errors.removeFirst()
        failures[operation] = errors
        throw error
    }

    public func save(_ record: CKRecord) async throws {
        try failIfRequested(.saveRecord)
        await beforeSave?(record)
        records[record.recordID] = record.copy() as? CKRecord
    }

    public func fetch(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        fetchedRecordIDs.append(recordID)
        try failIfRequested(.fetchRecord)
        return records[recordID]?.copy() as? CKRecord
    }

    public func delete(_ recordID: CKRecord.ID) async throws {
        try Task.checkCancellation()
        deletedRecordIDs.append(recordID)
        try failIfRequested(.deleteRecord)
        records.removeValue(forKey: recordID)
    }

    public func save(_ subscription: CKSubscription) async throws {
        try failIfRequested(.saveSubscription)
        subscriptions[subscription.subscriptionID] = subscription.copy() as? CKSubscription
    }
}
