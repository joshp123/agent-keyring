import CloudKit
import Foundation

@MainActor
public protocol ApprovalCloudDatabase {
    func save(_ record: CKRecord) async throws
    func fetch(_ recordID: CKRecord.ID) async throws -> CKRecord?
    func delete(_ recordID: CKRecord.ID) async throws
    func save(_ subscription: CKSubscription) async throws
}

@MainActor
public final class PrivateApprovalCloudDatabase: ApprovalCloudDatabase {
    public static let containerIdentifier = "iCloud.com.joshpalmer.AgentKeyring"
    private lazy var database = CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase
    private var preparedZones: Set<CKRecordZone.ID> = []

    public init() {}

    // Request and decision use the same record name in different zones. Provisioning
    // stays here so callers only need record and subscription operations.
    private func prepare(_ zoneID: CKRecordZone.ID) async throws {
        guard !preparedZones.contains(zoneID) else { return }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        preparedZones.insert(zoneID)
    }

    public func save(_ record: CKRecord) async throws {
        try await prepare(record.recordID.zoneID)
        _ = try await database.save(record)
    }

    public func fetch(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        try await prepare(recordID.zoneID)
        do { return try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    public func delete(_ recordID: CKRecord.ID) async throws {
        do { _ = try await database.deleteRecord(withID: recordID) }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound { return }
    }

    public func save(_ subscription: CKSubscription) async throws {
        if let query = subscription as? CKQuerySubscription, let zoneID = query.zoneID {
            try await prepare(zoneID)
        }
        _ = try await database.save(subscription)
    }
}
