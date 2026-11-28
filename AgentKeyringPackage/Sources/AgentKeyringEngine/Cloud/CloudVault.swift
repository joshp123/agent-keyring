// Written by AI on 2026.11.23 by model claude opus 5.5; hardened batching, zone-reset propagation, and single-flight pull on 2026.11.27 by model gemini-4-hydrogen;
// stateless between launches (CloudPipe, CloudCheckpoint) on 2026.11.27 by model claude opus 5.5.
//
// The user's own iCloud private database, as a pipe between his Macs and
// iPhones: one record type, VaultBlob, in one zone, AgentKeyringVault. Each
// record carries one document the devices already exchange (signed Members,
// the signed catalogue, a device's push address, a device's vault, copies
// sealed to one device) in an encrypted field. Nothing in it is trusted for
// being there: every device checks each document by its signatures.
//
// VaultBlob fields:
//   kind      String          what the payload is (CloudRecordKind)
//   writer    String          the key ID of the device that wrote it
//   updatedAt Date/Time
//   payload   Encrypted Bytes the document
//
// A record with one writer (a device's vault, push address, join and copies)
// is simply overwritten. Members and the catalogue are shared: a device writes
// its own only if it is newer than the one there, and otherwise takes that one.

import CloudKit
import CryptoKit
import Foundation
import os

public enum CloudRecordKind {
    static let recordType = "VaultBlob"
    public static let zone = "AgentKeyringVault"
    /// Signed Members, with every revision since the first (a Bundle with `members` and `members_since`).
    public static let members = "members"
    /// The signed catalogue.
    public static let catalogue = "catalogue"
    /// A device's vault: its logins and imports without secrets, signed with its reply key.
    public static func vault(_ writer: String) -> String { "vault-" + writer }
    /// Passwords sealed to one device, from one writer (record name `copies-<recipient>-<writer>-<part>`).
    public static func copies(_ recipient: String) -> String { "copies-" + recipient }
    /// A device's signed push address.
    public static func push(_ device: String) -> String { "push-" + device }
    /// An iPhone asking to join a Mac through iCloud: its JoinRequest.
    public static func join(_ device: String) -> String { "join-" + device }
    /// A computer's update mailbox, with its write token, for every device that writes to it.
    public static func mailbox(_ machine: String) -> String { "mailbox-" + machine }
    /// A device's own side of a contest: the latest catalogue it signed, while `catalogue` holds one it has not merged.
    public static func contested(_ writer: String) -> String { "contested-" + writer }
}

public struct CloudRecord: Sendable, Equatable {
    public let name: String
    public let kind: String
    public let writer: String
    public let payload: Data
    let updatedAt: Date

    public init(name: String, kind: String, writer: String, payload: Data, updatedAt: Date = .now) {
        self.name = name; self.kind = kind; self.writer = writer; self.payload = payload; self.updatedAt = updatedAt
    }

    public init(kind: String, writer: String, payload: Data) {
        self.init(name: kind, kind: kind, writer: writer, payload: payload)
    }
}

/// Single-flight pull coordinator shared by Mac and iPhone iCloud sync:
/// runs at most one pull at a time and triggers one trailing pass whenever
/// a new request arrives while a pull is already running.
@MainActor
public final class CloudPullGate {
    private var inFlight: Task<Void, Never>?
    private var runID: UInt64 = 0
    private var pullAgain = false
    private var currentWaiters: [CheckedContinuation<Bool, Never>] = []
    private var nextWaiters: [CheckedContinuation<Bool, Never>] = []

    public init() {}

    /// Starts a pull if idle, or marks a trailing pass if one is already running.
    public func trigger(_ pull: @escaping @MainActor () async -> Bool) {
        if inFlight != nil {
            pullAgain = true
            return
        }
        start(pull)
    }

    /// Runs a pull (or coalesces onto a trailing pass if one is already running) and returns its result.
    @discardableResult
    public func runPull(_ pull: @escaping @MainActor () async -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            if inFlight != nil {
                pullAgain = true
                nextWaiters.append(continuation)
            } else {
                currentWaiters.append(continuation)
                start(pull)
            }
        }
    }

    /// Cancels any active pull and resumes waiting callers with false.
    public func cancelPulls() {
        runID &+= 1
        inFlight?.cancel()
        inFlight = nil
        pullAgain = false
        let pending = currentWaiters + nextWaiters
        currentWaiters.removeAll()
        nextWaiters.removeAll()
        for waiter in pending { waiter.resume(returning: false) }
    }

    private func start(_ pull: @escaping @MainActor () async -> Bool) {
        runID &+= 1
        let myRun = runID
        inFlight = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.runID == myRun {
                self.pullAgain = false
                let ok = await pull()
                guard self.runID == myRun else { return }
                let resolved = self.currentWaiters
                self.currentWaiters = self.nextWaiters
                self.nextWaiters.removeAll()
                for waiter in resolved { waiter.resume(returning: ok) }
                if !self.pullAgain && self.currentWaiters.isEmpty { break }
            }
            guard self.runID == myRun else { return }
            self.inFlight = nil
            let leftover = self.currentWaiters + self.nextWaiters
            self.currentWaiters.removeAll()
            self.nextWaiters.removeAll()
            for waiter in leftover { waiter.resume(returning: false) }
        }
    }
}

public final class CloudVault: CloudPipe {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: CloudRecordKind.zone, ownerName: CKCurrentUserDefaultName)
    /// Whether the zone and subscription are made, and what this device last wrote to each record, by hash,
    /// so an unchanged record is not written again. Both are forgotten if the zone goes. Nothing here outlives
    /// the launch: the device's CloudCheckpoint holds what must.
    private struct Held: Sendable {
        var prepared = false
        var written: [String: Data] = [:]
        /// The zone was made again: every token from before it is void until the caller saves one from after it.
        var zoneReset = false
        var tokenAfterReset: Data?
    }
    private let held = OSAllocatedUnfairLock(initialState: Held())
    /// CloudKit refuses a record over 1 MB; copies are split well under it.
    static let partBytes = 700_000
    /// CloudKit refuses a request over about 2 MB; writes are sent in batches under it.
    public static let batchBytes = 900_000

    /// The container the app names in its Info.plist (AgentKeyringCloudContainer); nil when it names none.
    public init?(bundle: Bundle = .main) {
        guard let identifier = bundle.object(forInfoDictionaryKey: "AgentKeyringCloudContainer") as? String,
              identifier.hasPrefix("iCloud."), !identifier.contains("$(") else { return nil }
        container = CKContainer(identifier: identifier)
    }

    public func availability() async -> CloudAvailability {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount, .restricted: return .signedOut
            case .temporarilyUnavailable: return .unavailable("iCloud is not available right now.")
            case .couldNotDetermine: return .unavailable("iCloud could not say whether it is signed in.")
            @unknown default: return .unavailable("iCloud could not say whether it is signed in.")
            }
        } catch { return .unavailable("\(error)") }
    }

    /// Opaque, container-scoped CloudKit user record name (identical across this Apple Account's
    /// devices for Agent Keyring only; contains no name, email, or Apple ID). Nil if unavailable.
    public func fetchCloudUserRecordName() async -> String? {
        try? await container.userRecordID().recordName
    }

    /// Makes the zone and the subscription that wakes the app when anything in it changes, once per launch,
    /// and again if the zone goes.
    private func prepare() async throws {
        guard !held.withLock({ $0.prepared }) else { return }
        let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        for result in zones.saveResults.values { if case let .failure(error) = result { throw error } }
        let subscription = CKDatabaseSubscription(subscriptionID: "agent-keyring-vault")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        let subscriptions = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        for result in subscriptions.saveResults.values { if case let .failure(error) = result { throw error } }
        held.withLock { $0.prepared = true }
    }

    /// Runs `work` with the zone made. If the zone is gone (deleted from Settings, or iCloud reset), everything
    /// remembered about it is forgotten, the zone made again, and `work` run once more.
    private func inZone<T>(_ work: () async throws -> T) async throws -> T {
        try await prepare()
        do { return try await work() } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            held.withLock { $0 = Held(zoneReset: true) }
            try await prepare()
            return try await work()
        }
    }

    /// Forgets what this launch remembers of the zone without touching iCloud.
    public func forgetLocalCloudState() {
        held.withLock { $0 = Held() }
    }

    /// Deletes the entire AgentKeyringVault zone from this Apple Account's private iCloud database
    /// and forgets what this launch remembers of it. Missing zones are treated as already deleted.
    public func deleteCloudZone() async throws {
        do {
            let results = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
            for result in results.deleteResults.values {
                guard case let .failure(error) = result else { continue }
                if let ck = error as? CKError, ck.code == .zoneNotFound || ck.code == .userDeletedZone { continue }
                throw error
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // Already deleted.
        }
        forgetLocalCloudState()
    }

    // MARK: Reading

    /// Every record changed since `token`, all of them when there is none, and the names deleted. A record that
    /// could not be fetched fails the whole fetch, so no token moves past it. An expired token starts again from
    /// nothing, and so does any token from before the zone was made again (`zoneReset`).
    public func fetchCloudChanges(since token: Data?) async throws -> CloudChanges {
        try await inZone {
            var latestRecords: [String: CloudRecord] = [:]
            var latestDeleted: Set<String> = []
            let reset = held.withLock { held -> Bool in
                if held.zoneReset, token != nil, token == held.tokenAfterReset { held.zoneReset = false }
                return held.zoneReset
            }
            var cursor = reset ? nil : token.flatMap(Self.unarchive)
            var fullRescan = cursor == nil
            var more = true
            while more {
                let batch: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                            deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
                do {
                    batch = try await database.recordZoneChanges(inZoneWith: zoneID, since: cursor)
                } catch let error as CKError where error.code == .changeTokenExpired && cursor != nil {
                    cursor = nil
                    fullRescan = true
                    latestRecords = [:]
                    latestDeleted = []
                    held.withLock { $0.written = [:] }
                    continue
                }
                // Only the latest state per record name counts: a later deletion or unreadable record
                // supersedes an earlier modification of the same record.
                for result in batch.modificationResultsByID.values {
                    let modification = try result.get()
                    let name = modification.record.recordID.recordName
                    if let record = Self.read(modification.record) {
                        latestRecords[name] = record
                        latestDeleted.remove(name)
                    } else {
                        latestRecords.removeValue(forKey: name)
                        latestDeleted.insert(name)
                    }
                }
                for deletion in batch.deletions {
                    let name = deletion.recordID.recordName
                    latestRecords.removeValue(forKey: name)
                    latestDeleted.insert(name)
                }
                cursor = batch.changeToken
                more = batch.moreComing
            }
            let records = latestRecords
            let deleted = latestDeleted
            let next = cursor.flatMap(Self.archive)
            let readAll = fullRescan
            held.withLock { held in
                // A full read names every record there: one this device wrote that is missing goes up again.
                if readAll { held.written = held.written.filter { records[$0.key] != nil } }
                for name in deleted { held.written[name] = nil }
                for (name, record) in records where held.written[name] != Data(SHA256.hash(data: record.payload)) {
                    held.written[name] = nil
                }
                if held.zoneReset { held.tokenAfterReset = next }
            }
            return CloudChanges(records: Array(records.values), deleted: deleted.sorted(), token: next,
                                fullRescan: fullRescan, zoneReset: reset)
        }
    }

    private static func archive(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func unarchive(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    /// One record, or nil if there is none.
    public func fetchCloudRecord(named name: String) async throws -> CloudRecord? {
        try await inZone {
            do { return Self.read(try await database.record(for: CKRecord.ID(recordName: name, zoneID: zoneID))) }
            catch let error as CKError where error.code == .unknownItem { return nil }
        }
    }

    func fetchCloudPayload(named name: String) async throws -> Data? { try await fetchCloudRecord(named: name)?.payload }

    // MARK: Writing

    /// Splits records into CloudKit write batches bounded by `maxBatchBytes`, safely handling 0-byte payloads.
    public static func batch(_ records: [CloudRecord], maxBatchBytes: Int = batchBytes) -> [[CloudRecord]] {
        var batches: [[CloudRecord]] = []
        var size = 0
        for record in records {
            if batches.isEmpty || size + record.payload.count > maxBatchBytes {
                batches.append([])
                size = 0
            }
            batches[batches.count - 1].append(record)
            size += record.payload.count
        }
        return batches
    }

    /// Writes records only one device ever writes, replacing what is there, in batches CloudKit takes. One
    /// unchanged since this device last wrote it is left as it is.
    public func writeCloudRecords(_ records: [CloudRecord]) async throws {
        let written = held.withLock { $0.written }
        let changed = records.filter { written[$0.name] != Data(SHA256.hash(data: $0.payload)) }
        let batches = Self.batch(changed)
        for batch in batches {
            try await inZone {
                let saving = batch.map { record -> CKRecord in
                    let made = CKRecord(recordType: CloudRecordKind.recordType, recordID: CKRecord.ID(recordName: record.name, zoneID: zoneID))
                    Self.write(record, into: made)
                    return made
                }
                let results = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .allKeys, atomically: false)
                for result in results.saveResults.values { if case let .failure(error) = result { throw error } }
            }
            held.withLock { held in for record in batch { held.written[record.name] = Data(SHA256.hash(data: record.payload)) } }
        }
    }

    /// Deletes records; one already gone is not an error, and never stops the rest going.
    public func deleteCloudRecords(_ names: [String]) async throws {
        guard !names.isEmpty else { return }
        held.withLock { held in for name in names { held.written[name] = nil } }
        try await inZone {
            let results = try await database.modifyRecords(saving: [], deleting: names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) },
                                                           atomically: false)
            for result in results.deleteResults.values {
                if case let .failure(error) = result, (error as? CKError)?.code != .unknownItem { throw error }
            }
        }
    }

    /// Writes a shared record (Members, the catalogue) unless the one there is this same document, or one
    /// `isNewer` says is not older than this device's. `isNewer` must check the one there is signed by one of
    /// his devices before its revision counts: a forged record with a huge revision is simply written over.
    /// Returns the one there when it wins, for this device to take instead.
    public func writeCloudRecordIfNewer(_ record: CloudRecord, isNewer: @escaping @Sendable (Data) -> Bool) async throws -> Data? {
        let id = CKRecord.ID(recordName: record.name, zoneID: zoneID)
        return try await inZone {
            for _ in 0..<3 {
                let current: CKRecord?
                do { current = try await database.record(for: id) } catch let error as CKError where error.code == .unknownItem { current = nil }
                if let current, let held = Self.read(current), held.kind == record.kind {
                    if held.payload == record.payload { return nil }
                    if !isNewer(held.payload) { return held.payload }
                }
                let saving = current ?? CKRecord(recordType: CloudRecordKind.recordType, recordID: id)
                Self.write(record, into: saving)
                let results = try await database.modifyRecords(saving: [saving], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                switch results.saveResults[id] {
                case .success?: return nil
                case let .failure(error)? where (error as? CKError)?.code == .serverRecordChanged: continue
                case let .failure(error)?: throw error
                case nil: return nil
                }
            }
            throw CKError(.serverRecordChanged)
        }
    }

    /// Atomically commits `members` and `catalogue` in one CloudKit transaction
    /// (`savePolicy: .ifServerRecordUnchanged, atomically: true`). Fetches both current records first;
    /// if either record fails its guard or changes on the server before commit (including first creation
    /// of `catalogue`), neither record is written.
    public func putMembersAndCatalogueAtomically(
        members: CloudRecord,
        mayReplaceMembers: @escaping @Sendable (Data) -> Bool,
        catalogue: CloudRecord,
        mayReplaceCatalogue: @escaping @Sendable (Data) -> Bool
    ) async throws -> CloudAtomicOutcome {
        let membersID = CKRecord.ID(recordName: members.name, zoneID: zoneID)
        let catalogueID = CKRecord.ID(recordName: catalogue.name, zoneID: zoneID)
        return try await inZone {
            for _ in 0..<3 {
                let currentMembers: CKRecord?
                do { currentMembers = try await database.record(for: membersID) }
                catch let error as CKError where error.code == .unknownItem { currentMembers = nil }
                if let currentMembers, let held = Self.read(currentMembers),
                   held.kind == members.kind,
                   held.payload != members.payload, !mayReplaceMembers(held.payload) {
                    return .membersConflict(held.payload)
                }

                let currentCatalogue: CKRecord?
                do { currentCatalogue = try await database.record(for: catalogueID) }
                catch let error as CKError where error.code == .unknownItem { currentCatalogue = nil }
                if let currentCatalogue, let held = Self.read(currentCatalogue),
                   held.kind == catalogue.kind,
                   held.payload != catalogue.payload, !mayReplaceCatalogue(held.payload) {
                    return .catalogueConflict(held.payload)
                }

                let savingMembers = currentMembers ?? CKRecord(recordType: CloudRecordKind.recordType, recordID: membersID)
                Self.write(members, into: savingMembers)
                let savingCatalogue = currentCatalogue ?? CKRecord(recordType: CloudRecordKind.recordType, recordID: catalogueID)
                Self.write(catalogue, into: savingCatalogue)
                let saving = [savingMembers, savingCatalogue]

                let results = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                var retry = false
                for record in saving {
                    switch results.saveResults[record.recordID] {
                    case .success?, nil:
                        break
                    case let .failure(error)? where (error as? CKError)?.code == .serverRecordChanged
                        || (error as? CKError)?.code == .batchRequestFailed:
                        retry = true
                    case let .failure(error)?:
                        throw error
                    }
                }
                if retry { continue }
                return .committed
            }
            throw CKError(.serverRecordChanged)
        }
    }

    private static func write(_ record: CloudRecord, into made: CKRecord) {
        made["kind"] = record.kind as NSString
        made["writer"] = record.writer as NSString
        made["updatedAt"] = record.updatedAt as NSDate
        made.encryptedValues["payload"] = record.payload as NSData
    }

    private static func read(_ record: CKRecord) -> CloudRecord? {
        guard record.recordType == CloudRecordKind.recordType, let kind = record["kind"] as? String,
              let payload = record.encryptedValues["payload"] as? Data else { return nil }
        return CloudRecord(name: record.recordID.recordName, kind: kind, writer: record["writer"] as? String ?? "",
                           payload: payload, updatedAt: record["updatedAt"] as? Date ?? .distantPast)
    }

    /// Whether a remote notification is CloudKit's: something in the zone changed.
    public static func isCloudNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo) != nil
    }
}
