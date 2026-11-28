// Written by AI on 2026.11.28 by model claude opus 5.5.
//
// What a Mac or an iPhone gives the shared iCloud sync (CloudReplicaSyncCoordinator): its lists as a
// KeyringReplica, saved in one write; who it is; and the few things it does its own way. The Mac keeps every
// sealed copy in its vault files and folds other devices' vaults into its own list; the iPhone keeps only its
// own copies, passes copies for its Apple Watch on, and folds vaults into the one snapshot it keeps.

import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

/// Whether this device's lists are in iCloud. Settings and Home show it.
public enum CloudSyncState: Equatable, Sendable {
    case starting
    case syncing
    /// No iCloud account on this device: its other devices cannot reach it, and its lists stay on it.
    case signedOut
    case failed(String)
}

/// What a device made of a signed document another device sent.
public enum PeerIntakeOutcome: Equatable, Sendable {
    case taken
    case refused(String)
    /// Good, but not saved here: to be taken again.
    case notSaved(String)
}

/// Why a device could not take a signed document it needed, for callers that stop on it.
struct PeerIntakeFailure: Error, Equatable, CustomStringConvertible {
    let description: String
}

extension PeerIntakeOutcome {
    /// Throws unless the document was taken.
    func requireTaken() throws {
        switch self {
        case .taken: return
        case let .refused(reason), let .notSaved(reason): throw PeerIntakeFailure(description: reason)
        }
    }
}

/// What a device did with copies from iCloud sealed to a device it takes copies for.
public enum CloudCopiesIntake: Equatable, Sendable { case kept, notSaved }

/// Whether iCloud holds this keyring's Members, checked before anything else is written there.
public enum CloudMembersOwnership: Equatable, Sendable { case owned, conflict, unreachable }

/// How a write of a record every device shares went: written; iCloud holds one that must stay; or unreachable.
public enum CloudSharedWrite: Equatable, Sendable { case written, theirs(Data), unreachable }

/// How a write of the shared catalogue went. `theirs`: iCloud kept its own, opened when this device can.
public enum CloudCatalogueWrite: Equatable, Sendable { case written, theirs(OpenedCloudEnvelope?), unreachable }

@MainActor
package protocol CloudReplicaHost: AnyObject {
    associatedtype Replica: KeyringReplica & Equatable

    var replica: Replica { get }
    /// Saves `change` made to the lists held now, in one write. False, with nothing changed, when it is not saved.
    @discardableResult func updateReplica(_ change: (inout Replica) -> Void) -> Bool
    /// Every save that failed since launch: a pull during which one failed leaves its checkpoint where it was.
    var replicaSaveFailures: UInt64 { get }
    /// False while the operating system keeps the saved lists locked: nothing syncs until they are read.
    var replicaReadable: Bool { get }

    /// This device's key ID, while it is in a keyring.
    var replicaDeviceID: String? { get }
    /// This device's own signing key, which a Members list must name before a device with none takes it.
    var replicaSigningPublicKey: Data? { get }
    /// The computer this device's own agents run on, if it is one.
    var replicaMachineID: String? { get }
    var replicaKeyOpener: CloudEnvelope.KeyOpener? { get }
    var replicaReplySigner: PayloadReplySigner { get }
    var replicaLog: KeyringDiagnosticLog { get }

    // MARK: Taking from iCloud

    func receiveSignedMembers(_ signed: Data) async -> PeerIntakeOutcome
    func receiveSignedCatalogue(_ signed: Data) async -> PeerIntakeOutcome
    /// Another device's vault, checked: false when it could not be saved.
    func receivePeerVault(_ vault: CredentialVault) async -> Bool
    /// Whether this device keeps copies sealed to `recipient`: its own, or ones it passes on.
    func takesCloudCopies(for recipient: String) -> Bool
    /// Copies for `recipient`, each checked against its signer and the catalogue's version.
    func receiveCheckedCloudCopies(_ copies: [SealedLogin], for recipient: String) async -> CloudCopiesIntake
    /// Requests to join through iCloud in one pull, and ones it finds gone.
    func receiveCloudJoins(from pull: ReplicaPull) async
    /// One pull took catalogues, vaults or copies: what depends on all three together is worked out again.
    func cloudSealedRecordsTaken() async
    /// A pull was taken in and saved; `peerChanges` of its records were written by other devices.
    func cloudPullFinished(peerChanges: Int)

    // MARK: Writing to iCloud

    /// This device's own vault, to share.
    func ownCloudVault() async -> CredentialVault?
    /// The devices whose push addresses this device writes to iCloud: itself, and an iPhone its Apple Watch.
    func pushRegistrationsWrittenHere(in members: Members) -> [String]
    /// The copies this device sealed for each other device and computer, by recipient, to share.
    func cloudCopiesToShare(in members: Members) async throws -> [(recipient: String, copies: [SealedLogin])]
    /// Requests to join that are over, to take out of iCloud.
    func endedCloudJoinNames(in members: Members) -> [String]
    /// What this device writes into each computer's mailbox slot.
    func mailboxSlotWrite() async -> MailboxSlotWrite?
    func cloudSyncStateChanged(from previous: CloudSyncState)
}
