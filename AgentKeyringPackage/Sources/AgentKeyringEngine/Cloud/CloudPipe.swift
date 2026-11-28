// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The pipe a Mac or iPhone syncs through, as the replica uses it: CloudVault
// over the user's iCloud private database, or InMemoryCloudPipe in tests. The
// pipe keeps nothing between launches. Where a device has read up to (the
// change token), which record names it has seen and which it must fetch
// again live in its CloudCheckpoint, saved in one write with the state those
// records changed, so a failed save never moves the cursor past them.

import AgentKeyringProtocol
import Foundation
import os

public enum CloudAvailability: Equatable, Sendable {
    case available
    /// No iCloud account on this device, or iCloud Drive's data is restricted: the vault stays on this device.
    case signedOut
    case unavailable(String)
}

/// Every record changed since a token, all of them when there is none, and the names deleted.
public struct CloudChanges: Sendable {
    public let records: [CloudRecord]
    public let deleted: [String]
    /// The token to save once these changes are taken in; opaque to the caller.
    public let token: Data?
    /// The fetch read the whole zone: names not in it are gone.
    let fullRescan: Bool
    /// The zone was made again since the last fetch: lists iCloud accepted before are gone with it.
    let zoneReset: Bool

    public init(records: [CloudRecord], deleted: [String], token: Data?, fullRescan: Bool, zoneReset: Bool) {
        self.records = records; self.deleted = deleted; self.token = token; self.fullRescan = fullRescan; self.zoneReset = zoneReset
    }
}

/// Result of an atomic two-record commit of `Members` and `Catalogue`.
public enum CloudAtomicOutcome: Sendable {
    case committed
    case membersConflict(Data)
    case catalogueConflict(Data)
}

public protocol CloudPipe: AnyObject, Sendable {
    func availability() async -> CloudAvailability
    func fetchCloudChanges(since token: Data?) async throws -> CloudChanges
    func fetchCloudRecord(named name: String) async throws -> CloudRecord?
    /// Writes records only one device ever writes, replacing what is there.
    func writeCloudRecords(_ records: [CloudRecord]) async throws
    /// Deletes records; one already gone is not an error.
    func deleteCloudRecords(_ names: [String]) async throws
    /// Writes a shared record unless the one there is the same document or `isNewer` says it must stay;
    /// returns the one there when it wins.
    func writeCloudRecordIfNewer(_ record: CloudRecord, isNewer: @escaping @Sendable (Data) -> Bool) async throws -> Data?
    /// Writes both records in one transaction, or neither if either guard refuses.
    func putMembersAndCatalogueAtomically(members: CloudRecord, mayReplaceMembers: @escaping @Sendable (Data) -> Bool,
                                          catalogue: CloudRecord, mayReplaceCatalogue: @escaping @Sendable (Data) -> Bool)
        async throws -> CloudAtomicOutcome
    /// Deletes the whole zone, every device's records with it; one already gone is not an error.
    func deleteCloudZone() async throws
    /// Forgets what this launch remembers of the zone, without touching iCloud.
    func forgetLocalCloudState()
}

extension CloudPipe {
    func fetchCloudPayload(named name: String) async throws -> Data? { try await fetchCloudRecord(named: name)?.payload }
}

/// Where a device has read the pipe up to, kept with its lists.
public struct CloudCheckpoint: Equatable, Sendable {
    public var changeToken: Data?
    /// Record names seen in the zone, for orphan cleanup and to find deletions after a full read.
    public var knownNames: Set<String> = []
    /// Records not taken in yet, fetched again by name on every pull until taken.
    public var retrying: Set<String> = []

    public init() {}

    public init(stored proto: Agentkeyring_V2_StoredCloudCheckpoint) {
        changeToken = proto.changeToken.isEmpty ? nil : proto.changeToken
        knownNames = Set(proto.knownNames)
        retrying = Set(proto.retryingNames)
    }

    public var stored: Agentkeyring_V2_StoredCloudCheckpoint {
        var proto = Agentkeyring_V2_StoredCloudCheckpoint()
        if let changeToken { proto.changeToken = changeToken }
        proto.knownNames = knownNames.sorted()
        proto.retryingNames = retrying.sorted()
        return proto
    }

    /// Records this device just wrote or deleted.
    mutating func noteWritten(_ names: [String]) { knownNames.formUnion(names) }
    mutating func noteDeleted(_ names: [String]) {
        knownNames.subtract(names)
        retrying.subtract(names)
    }
}

/// A pipe held in memory, for tests of several devices syncing: a log of changes, each with its own token.
public final class InMemoryCloudPipe: CloudPipe, @unchecked Sendable {
    private struct Held {
        var records: [String: CloudRecord] = [:]
        var log: [(sequence: Int, name: String)] = []
        var sequence = 0
        /// Which making of the zone a token is from: a token from before a reset reads everything again.
        var zone = 0
        var availability = CloudAvailability.available
    }
    private let held = OSAllocatedUnfairLock(initialState: Held())

    public init() {}

    public func setAvailability(_ availability: CloudAvailability) { held.withLock { $0.availability = availability } }
    public var records: [String: CloudRecord] { held.withLock { $0.records } }

    public func availability() async -> CloudAvailability { held.withLock { $0.availability } }

    /// The zone deleted, as from Settings or by another device's Reset: every record goes, and every token with it.
    public func simulateZoneReset() {
        held.withLock { held in
            held = Held(zone: held.zone + 1, availability: held.availability)
        }
    }

    public func deleteCloudZone() async throws { simulateZoneReset() }

    /// Nothing to forget: the pipe keeps nothing for one device.
    public func forgetLocalCloudState() {}

    public func fetchCloudChanges(since token: Data?) async throws -> CloudChanges {
        try held.withLock { held in
            guard held.availability == .available else { throw CocoaError(.featureUnsupported) }
            let parts = token.map { String(decoding: $0, as: UTF8.self).split(separator: ":").compactMap { Int($0) } }
            let reset = parts != nil && parts?.first != held.zone
            let since = reset ? nil : parts?.last
            let names = Set(held.log.filter { $0.sequence > since ?? 0 }.map(\.name))
            let records = names.compactMap { held.records[$0] }.sorted { $0.name < $1.name }
            let deleted = names.filter { held.records[$0] == nil }.sorted()
            return CloudChanges(records: records, deleted: since == nil ? [] : deleted, token: Data("\(held.zone):\(held.sequence)".utf8),
                                fullRescan: since == nil, zoneReset: reset)
        }
    }

    public func fetchCloudRecord(named name: String) async throws -> CloudRecord? { held.withLock { $0.records[name] } }

    public func writeCloudRecords(_ records: [CloudRecord]) async throws {
        held.withLock { held in for record in records { Self.write(record, into: &held) } }
    }

    public func deleteCloudRecords(_ names: [String]) async throws {
        held.withLock { held in
            for name in names where held.records.removeValue(forKey: name) != nil {
                held.sequence += 1
                held.log.append((held.sequence, name))
            }
        }
    }

    public func writeCloudRecordIfNewer(_ record: CloudRecord, isNewer: @escaping @Sendable (Data) -> Bool) async throws -> Data? {
        held.withLock { held in
            if let current = held.records[record.name], current.kind == record.kind {
                if current.payload == record.payload { return nil }
                if !isNewer(current.payload) { return current.payload }
            }
            Self.write(record, into: &held)
            return nil
        }
    }

    public func putMembersAndCatalogueAtomically(members: CloudRecord, mayReplaceMembers: @escaping @Sendable (Data) -> Bool,
                                                 catalogue: CloudRecord, mayReplaceCatalogue: @escaping @Sendable (Data) -> Bool)
        async throws -> CloudAtomicOutcome {
        held.withLock { held in
            if let current = held.records[members.name], current.payload != members.payload, !mayReplaceMembers(current.payload) {
                return .membersConflict(current.payload)
            }
            if let current = held.records[catalogue.name], current.payload != catalogue.payload, !mayReplaceCatalogue(current.payload) {
                return .catalogueConflict(current.payload)
            }
            Self.write(members, into: &held)
            Self.write(catalogue, into: &held)
            return .committed
        }
    }

    private static func write(_ record: CloudRecord, into held: inout Held) {
        held.records[record.name] = record
        held.sequence += 1
        held.log.append((held.sequence, record.name))
    }
}
