// Written by AI on 2026.11.27 by model claude opus 5.5.

#if os(macOS)
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import OSLog

/// The record of agents' leases: a private file in the app's container. It
/// holds no secrets, and editing it gains nothing: an approved login lives
/// only in memory, and an Automatic one opens only from its sealed copy.
@MainActor
public final class LeasePersistence {
    private let file: URL

    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "AgentKeyring/leases")) {
        file = directory.appending(path: "leases.pb")
    }

    /// The saved record: nil if none was saved, or if this build cannot decode it, so a new one is started.
    /// Throws only if the file is there and cannot be read.
    func load() throws -> CredentialLeaseStore.Snapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes = try Data(contentsOf: file)
        do { return try CredentialLeaseStore.Snapshot.decodeProtobuf(bytes) } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Leases").error(
                "The record of agents' leases could not be decoded and starts again: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save(_ snapshot: CredentialLeaseStore.Snapshot) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try snapshot.encodeProtobuf().write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func clearSavedLeases() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }
}

extension CredentialLeaseStore {
    struct RequestRecord {
        var request: Agentkeyring_V2_RequestLeaseRequest
        var leaseID: String
    }

    struct SavedLease {
        var lease: Agentkeyring_V2_Lease
        var requester: CredentialLeaseRequester? = nil
    }

    /// Everything the lease store saves, as one protobuf (`AKRLSE03`).
    struct Snapshot {
        nonisolated static let protobufMagic = Data("AKRLSE03".utf8)

        var version = 1
        var recipient: Agentkeyring_V2_Recipient
        var leases: [String: SavedLease] = [:]
        var requests: [String: RequestRecord] = [:]
        var suppressions: [String: Suppression] = [:]
        /// Each waiting or approved lease this Mac also pushed to the iPhone and
        /// Apple Watch: lease ID to the signed request (Signed, serialized), so a
        /// restart takes their answers again.
        var pushed: [String: Data] = [:]
        /// The pushed leases whose grant is at the relay: after a restart one is only read, never put again,
        /// so a relay that lost a stopped grant can never have it made anew.
        var grantsPut: Set<String> = []

        init(recipient: Agentkeyring_V2_Recipient) {
            self.recipient = recipient
        }

        init(storedProto proto: Agentkeyring_V2_StoredLeaseSnapshot) {
            version = Int(proto.version)
            recipient = proto.recipient
            leases = proto.leases.mapValues { entry in
                SavedLease(lease: entry.lease,
                    requester: entry.hasRequester ? CredentialLeaseRequester(storedProto: entry.requester) : nil)
            }
            requests = proto.requests.mapValues { RequestRecord(request: $0.request, leaseID: $0.leaseID) }
            suppressions = proto.suppressions.mapValues {
                Suppression(until: $0.untilUnixSeconds, reply: $0.reply, inARow: Int($0.inARow))
            }
            pushed = proto.pushed
            grantsPut = Set(proto.grantsPut)
        }

        func storedProto() -> Agentkeyring_V2_StoredLeaseSnapshot {
            var proto = Agentkeyring_V2_StoredLeaseSnapshot()
            proto.version = UInt32(version)
            proto.recipient = recipient
            proto.leases = leases.mapValues { saved in
                var entry = Agentkeyring_V2_StoredSavedLease()
                entry.lease = saved.lease
                if let requester = saved.requester {
                    entry.requester = requester.storedProto()
                }
                return entry
            }
            proto.requests = requests.mapValues { record in
                var stored = Agentkeyring_V2_StoredRequestRecord()
                stored.request = record.request
                stored.leaseID = record.leaseID
                return stored
            }
            proto.suppressions = suppressions.mapValues { suppression in
                var stored = Agentkeyring_V2_StoredSuppression()
                stored.untilUnixSeconds = suppression.until
                stored.reply = suppression.reply
                stored.inARow = Int32(suppression.inARow)
                return stored
            }
            proto.pushed = pushed
            proto.grantsPut = grantsPut.sorted()
            return proto
        }

        func encodeProtobuf() throws -> Data {
            Self.protobufMagic + (try storedProto().serializedData())
        }

        static func decodeProtobuf(_ bytes: Data) throws -> Snapshot {
            guard bytes.starts(with: protobufMagic) else {
                throw AgentRPCError(.invalidArgument, "The record of agents' leases is not a lease snapshot.")
            }
            let decoded = Snapshot(storedProto: try Agentkeyring_V2_StoredLeaseSnapshot(
                serializedBytes: Data(bytes.dropFirst(protobufMagic.count))))
            guard decoded.version == 1 else {
                throw AgentRPCError(.invalidArgument, "Unsupported lease snapshot version.")
            }
            return decoded
        }
    }
}
#endif
