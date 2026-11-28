// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The lists every approving device keeps, and the one way a Mac or an iPhone
// takes them in from iCloud: the signed Members with its history, the signed
// catalogue and any other device's kept beside it while contested, every
// device's push address, every computer's mailbox, what iCloud last accepted,
// and where the device has read iCloud up to. Everything here is synchronous
// and pure; each device saves the result in one write with its own state.
//
// Two devices can sign catalogues while apart, say the iPhone blocking a
// password at one revision while the Mac makes two other changes and reaches
// the next. Neither can sign again without Touch ID or Face ID, so a document
// that sets a rule the other has not seen is never thrown away: each device
// keeps it (`contestedCatalogues`), shares its own in a `contested-<writer>`
// record, and goes by their merge, the later change to each rule winning and
// Block winning a tie, until one of them signs the merged list as the next
// revision. Which logins there are is the vault's to say, with its deletions:
// an earlier revision brings back only rules, never a login the later one
// left out.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation

public protocol KeyringReplica {
    var members: Data? { get set }
    /// The latest signed Members revisions taken, oldest first (`historyKept` of them).
    var membersHistory: [Data] { get set }
    /// The signed catalogue this device holds and serves.
    var catalogue: Data? { get set }
    /// Signed catalogues kept beside the held one, sorted: another device's of the same revision, or one of an
    /// earlier revision that sets a rule the held one has not seen.
    var contestedCatalogues: [Data] { get set }
    /// Device key ID: its signed PushRegistration.
    var pushRegistrations: [String: Data] { get set }
    /// Machine ID: its UpdateMailbox, with the write token.
    var mailboxes: [String: Data] { get set }
    /// Exact signed bytes iCloud last accepted.
    var cloudAcceptedMembers: Data? { get set }
    var cloudAcceptedCatalogue: Data? { get set }
    var cloudCheckpoint: CloudCheckpoint { get set }
}

/// What taking in a signed catalogue did.
public enum CatalogueIntake: Equatable, Sendable {
    /// A later revision that has seen every rule held: now the one held, and any contest is over.
    case newer
    /// Kept beside the held one and merged: the held revision signed elsewhere, or a document that sets a rule
    /// the other has not seen (a later revision is then the one held, with the earlier one beside it).
    case contested
    /// The held document, or one already kept.
    case unchanged
    case older
}

extension KeyringReplica {
    /// The members list held, as signed; checked when it was taken.
    public var currentMembers: Members? { Self.parsedMembers(members) }

    /// Lists iCloud has not accepted yet: computers are sent none of them until it has.
    var cloudListsPending: Bool { members != cloudAcceptedMembers || catalogue != cloudAcceptedCatalogue }

    /// Another device signed a catalogue this one has not seen all of, and neither has signed the next.
    public var catalogueContested: Bool { !contestedCatalogues.isEmpty }

    /// Something a push could still put in iCloud: lists it has not accepted, or this device's side of a
    /// contest. While contested, with Members accepted and `contested-<device>` written, nothing is left to
    /// write until one of the two devices signs the next revision.
    public func cloudPushPending(by deviceID: String) -> Bool {
        guard cloudListsPending || catalogueContested else { return false }
        return !(catalogueContested && members == cloudAcceptedMembers
            && cloudCheckpoint.knownNames.contains(CloudRecordKind.contested(deviceID)))
    }

    /// What iCloud accepted before, forgotten for a shared record this pull finds gone.
    mutating func forgetLost(in pull: ReplicaPull) {
        if pull.isRecordGoneFromCloud(CloudRecordKind.members) { cloudAcceptedMembers = nil }
        if pull.isRecordGoneFromCloud(CloudRecordKind.catalogue) { cloudAcceptedCatalogue = nil }
    }

    // MARK: Members

    /// A newer members list, already checked against the one before. A device it leaves out keeps no push
    /// address here.
    public mutating func adoptMembers(_ next: Members, signed: Data) {
        members = signed
        membersHistory = Array((membersHistory.filter { $0 != signed } + [signed]).suffix(Self.historyKept))
        let devices = Set(next.devices.map(\.keyID))
        pushRegistrations = pushRegistrations.filter { devices.contains($0.key) }
    }

    /// Revisions kept to send with lists: enough for a computer to follow, small enough for a 256 KiB box.
    static var historyKept: Int { 20 }

    /// Every signed Members this device keeps, with the last one iCloud accepted.
    var membersAncestry: [Data] {
        (cloudAcceptedMembers.map { [$0] } ?? []) + membersHistory + (members.map { [$0] } ?? [])
    }

    /// The revisions in an iCloud Members payload newer than `current`, oldest first.
    static func newerRevisions(_ payload: Data, than current: Members?) -> [SignedDocument] {
        CloudMembers.revisions(payload).filter { CloudMembers.revision($0) > (current?.revision ?? 0) }
    }

    /// iCloud's Members record: accepted when its newest revision is the one held.
    mutating func noteCloudMembers(_ payload: Data) {
        let latest = CloudMembers.revisions(payload).last.flatMap { try? $0.serializedData() }
        cloudAcceptedMembers = latest != nil && latest == members ? latest : nil
    }

    /// Whether a device is listed: true now; false when an earlier Members listed it and a later one removed
    /// it, so its documents never count again; nil when not listed yet, as its Members may still be coming.
    public func lists(device keyID: String) -> Bool? {
        if currentMembers?.devices.contains(where: { $0.keyID == keyID }) == true { return true }
        let before = membersAncestry.contains { bytes in
            Self.parsedMembers(bytes)?.devices.contains { $0.keyID == keyID } == true
        }
        return before ? false : nil
    }

    static func parsedMembers(_ bytes: Data?) -> Members? {
        bytes.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Members(serializedBytes: $0.payload) }
    }

    // MARK: The catalogue

    /// The held catalogue, merged with every contested one: what this device enforces and signs from next. One of
    /// the held revision is merged login by login; one of an earlier revision gives only the rules it set later.
    public var effectiveCatalogue: Catalogue? {
        guard let own = Self.parsedCatalogue(catalogue) else { return nil }
        let others = contestedCatalogues.compactMap(Self.parsedCatalogue).filter { $0.revision <= own.revision }
        guard !others.isEmpty else { return own }
        var merged = others.filter { $0.revision == own.revision }.reduce(own, CatalogueMerge.mergeCatalogues)
        for earlier in others where earlier.revision < own.revision { merged = CatalogueMerge.fold(earlier, into: merged) }
        for index in merged.logins.indices where merged.logins[index].rule == .blocked { merged.logins[index].version = 0 }
        return merged
    }

    /// A catalogue from another device or iCloud, signed by a device in `members`. A later one is held, with
    /// every document held before that sets a rule it has not seen kept beside it; an earlier one is kept only
    /// if it sets such a rule itself.
    @discardableResult
    public mutating func intakeCatalogue(_ signed: Data, members: Members) throws -> CatalogueIntake {
        let document = try SignedDocument(serializedBytes: signed)
        let incoming = try CredentialSealing.verifySignedCatalogue(document, members: members, current: nil)
        guard let heldBytes = catalogue, let held = try? SignedDocument(serializedBytes: heldBytes),
              let current = try? Catalogue(serializedBytes: held.payload) else {
            signCatalogue(signed)
            return .newer
        }
        let kept = [held] + contestedCatalogues.compactMap { try? SignedDocument(serializedBytes: $0) }
        if kept.contains(where: { $0.payload == document.payload }) { return .unchanged }
        if incoming.revision > current.revision {
            let unseen = ([heldBytes] + contestedCatalogues).filter { bytes in
                Self.parsedCatalogue(bytes).map { !CatalogueMerge.isDominated($0, by: incoming) } ?? false
            }
            catalogue = signed
            contestedCatalogues = unseen.sorted { $0.lexicographicallyPrecedes($1) }
            return unseen.isEmpty ? .newer : .contested
        }
        if incoming.revision < current.revision {
            guard let effective = effectiveCatalogue, !CatalogueMerge.isDominated(incoming, by: effective) else { return .older }
        }
        contestedCatalogues = (contestedCatalogues + [signed]).sorted { $0.lexicographicallyPrecedes($1) }
        return .contested
    }

    /// What this device writes as its `contested-<device>` record: the latest catalogue it signed among the held
    /// one and those kept beside it, or the held one if it signed none of them.
    public func ownContestedCatalogue(signedBy deviceID: String) -> Data? {
        let own = ([catalogue].compactMap { $0 } + contestedCatalogues).filter { bytes in
            (try? SignedDocument(serializedBytes: bytes))?.signerKeyID == deviceID
        }
        return own.max { (Self.parsedCatalogue($0)?.revision ?? 0) < (Self.parsedCatalogue($1)?.revision ?? 0) } ?? catalogue
    }

    /// A catalogue this device signed, or a later one taken: the one held, and any contest over.
    public mutating func signCatalogue(_ signed: Data) {
        catalogue = signed
        contestedCatalogues = []
    }

    /// iCloud's catalogue record, opened: accepted when it is the one held, sealed to every device listed now.
    mutating func noteCloudCatalogue(_ opened: OpenedCloudEnvelope?) {
        guard let opened, let members = currentMembers, catalogue == opened.plaintext,
              CloudCatalogue.isSealCurrent(opened, members: members, recipients: CloudEnvelope.recipients(for: members)) else {
            cloudAcceptedCatalogue = nil
            return
        }
        cloudAcceptedCatalogue = opened.plaintext
    }

    static func parsedCatalogue(_ bytes: Data?) -> Catalogue? {
        bytes.flatMap { try? SignedDocument(serializedBytes: $0) }.flatMap { try? Catalogue(serializedBytes: $0.payload) }
    }

    // MARK: Push addresses and mailboxes

    /// A device's signed push address: kept if it is newer than the one held. Nil when the held one stays.
    public mutating func takePushRegistration(_ payload: Data, members: Members) throws -> VerifiedPushRegistration? {
        let verified = try CloudPushRegistration.verified(payload, members: members)
        guard CloudPushRegistration.isNewer(verified.registration, than: pushRegistrations[verified.target.keyID]) else { return nil }
        pushRegistrations[verified.target.keyID] = payload
        return verified
    }

    /// Records the members list says should be in iCloud and this device lacks: other devices' push addresses
    /// and computers' mailboxes. Fetched by name after Members changes, as one written before the Members that
    /// lists its writer was passed over then and is not changed since.
    func missingPeerRecords(ownDeviceID: String, ownMachineID: String?) -> [String] {
        guard let members = currentMembers else { return [] }
        let pushes = members.devices.filter { $0.keyID != ownDeviceID && pushRegistrations[$0.keyID] == nil }
            .map { CloudRecordKind.push($0.keyID) }
        let boxes = members.machines.filter { $0.machineID != ownMachineID && mailboxes[$0.machineID] == nil }
            .map { CloudRecordKind.mailbox($0.machineID) }
        return pushes + boxes
    }
}

/// One iCloud pull being taken in: the changes, the records fetched again by name, and which records must be
/// fetched again next time. Its checkpoint is saved only once everything it changed is saved.
public final class ReplicaPull {
    public let changes: CloudChanges
    /// Names gone from iCloud: deleted, or absent from a full read though seen before.
    public let deleted: Set<String>
    public private(set) var again: [CloudRecord] = []
    private var knownNames: Set<String>
    private var retrying: Set<String>

    public init(_ changes: CloudChanges, after checkpoint: CloudCheckpoint) {
        self.changes = changes
        let present = Set(changes.records.map(\.name))
        var gone = Set(changes.deleted)
        if changes.fullRescan { gone.formUnion(checkpoint.knownNames.subtracting(present)) }
        deleted = gone
        knownNames = changes.fullRescan ? present : checkpoint.knownNames.union(present).subtracting(gone)
        retrying = checkpoint.retrying.subtracting(gone)
    }

    /// Records to fetch by name before taking the changes in: every one still to retry, not in the changes.
    var namesToRetry: [String] {
        let present = Set(changes.records.map(\.name))
        return retrying.subtracting(present).sorted()
    }

    /// The changes and the records fetched again, each once, the changed one first.
    public var records: [CloudRecord] {
        let present = Set(changes.records.map(\.name))
        return changes.records + again.filter { !present.contains($0.name) }
    }

    /// A record fetched by name; nil when it is gone.
    func takeRefetchedRecord(_ name: String, _ record: CloudRecord?) {
        guard let record else { return clearRecordRetry(name) }
        if !again.contains(where: { $0.name == name }) { again.append(record) }
        knownNames.insert(name)
    }

    /// A shared record iCloud no longer holds: deleted, gone with its zone, or missing from a full read.
    func isRecordGoneFromCloud(_ name: String) -> Bool {
        changes.zoneReset || deleted.contains(name) || (changes.fullRescan && !changes.records.contains { $0.name == name })
    }

    /// A record taken in, or one that will never be.
    public func clearRecordRetry(_ name: String) { retrying.remove(name) }

    /// A record that cannot be taken in yet: fetched again on the next pull.
    func markRecordForRetry(_ name: String) { retrying.insert(name) }

    /// Records written by other devices, of a kind.
    func peerRecords(_ prefix: String, notBy writer: String) -> [CloudRecord] {
        records.filter { $0.writer != writer && $0.kind.hasPrefix(prefix) }
    }

    /// Where the next pull starts: after this one, unless a full read was asked for while it ran.
    public func nextCheckpoint(readAllAgain: Bool) -> CloudCheckpoint {
        var next = CloudCheckpoint()
        next.changeToken = readAllAgain ? nil : changes.token
        next.knownNames = knownNames
        next.retrying = retrying
        return next
    }
}

/// Two catalogues of one revision, merged login by login: commutative, associative and idempotent, so every
/// device that holds the same documents goes by the same list.
public enum CatalogueMerge {
    public static func mergeCatalogues(_ a: Catalogue, _ b: Catalogue) -> Catalogue {
        var byID: [String: Agentkeyring_V2_Login] = [:]
        for login in a.logins + b.logins {
            byID[login.loginID] = byID[login.loginID].map { mergeLogins($0, login) } ?? login
        }
        var merged = Catalogue()
        merged.domain = a.domain
        merged.revision = max(a.revision, b.revision)
        merged.importedUnixSeconds = max(a.importedUnixSeconds, b.importedUnixSeconds)
        merged.logins = byID.keys.sorted().compactMap { byID[$0] }
        return merged
    }

    /// A catalogue of an earlier revision folded into a later one: for each login the later one lists, the rule
    /// set later wins. Details, and which logins there are, stay the later one's.
    public static func fold(_ earlier: Catalogue, into later: Catalogue) -> Catalogue {
        let rules = Dictionary(earlier.logins.map { ($0.loginID, entry($0)) }, uniquingKeysWith: { first, _ in first })
        var folded = later
        for index in folded.logins.indices {
            let ours = entry(folded.logins[index])
            guard let theirs = rules[folded.logins[index].loginID], let later = LoginRuleTimestampEntry.latest(ours, theirs), later != ours else { continue }
            folded.logins[index].rule = later.rule.storedRule
            folded.logins[index].ruleUpdatedUnixMs = later.updatedAtMs
            folded.logins[index].ruleActor = later.actor
        }
        return folded
    }

    /// True when `catalogue` sets no rule later than `later` does for a login both list. A later stamp on the same
    /// rule changes nothing enforced, so it counts as seen, whichever device stamped it and when.
    static func isDominated(_ catalogue: Catalogue, by later: Catalogue) -> Bool {
        let rules = Dictionary(later.logins.map { ($0.loginID, entry($0)) }, uniquingKeysWith: { first, _ in first })
        return catalogue.logins.allSatisfy { login in
            guard let theirs = rules[login.loginID], let winner = LoginRuleTimestampEntry.latest(theirs, entry(login)) else { return true }
            return winner.rule == theirs.rule
        }
    }

    /// One login: the later rule (Block on a tie), and the details of the newer version.
    static func mergeLogins(_ a: Agentkeyring_V2_Login, _ b: Agentkeyring_V2_Login) -> Agentkeyring_V2_Login {
        var merged = detailsOrder(a, b) ? b : a
        let later = LoginRuleTimestampEntry.latest(entry(a), entry(b)) ?? entry(a)
        merged.rule = later.rule.storedRule
        merged.ruleUpdatedUnixMs = later.updatedAtMs
        merged.ruleActor = later.actor
        return merged
    }

    private static func entry(_ login: Agentkeyring_V2_Login) -> LoginRuleTimestampEntry {
        LoginRuleTimestampEntry(LoginRule(storedRule: login.rule), updatedAtMs: login.ruleUpdatedUnixMs, actor: login.ruleActor)
    }

    /// True when `a`'s details come before `b`'s: by version, then by their bytes, so a tie ends the same everywhere.
    private static func detailsOrder(_ a: Agentkeyring_V2_Login, _ b: Agentkeyring_V2_Login) -> Bool {
        if a.version != b.version { return a.version < b.version }
        return detailsBytes(a).lexicographicallyPrecedes(detailsBytes(b))
    }

    private static func detailsBytes(_ login: Agentkeyring_V2_Login) -> Data {
        var details = login
        details.rule = .ask
        details.ruleUpdatedUnixMs = 0
        details.ruleActor = ""
        return (try? details.serializedData()) ?? Data()
    }
}
