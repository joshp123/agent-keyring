// Written by AI on 2026.11.24 by model claude opus 5.5.
//
// Update mailboxes (keyring.proto, "Update mailboxes"), shared by the Mac and
// the iPhone: each computer has one, from its join, and each of them writes
// its own slot there whenever it signs or takes a newer Members or Catalogue,
// and once a day while awake, so the computer learns every rule and device
// change without reaching either. The computer reads them in Go
// (internal/remote/remote_update_mailbox.go).

import AgentKeyringProtocol
import Foundation

public enum UpdateMailboxWriter {
    /// How long a Freshness vouches for a computer's lists.
    static let freshFor: TimeInterval = 7 * 86_400
    /// A slot older than this is written again even if nothing changed, so a quiet week never pauses Automatic.
    public static let rewriteAfter: TimeInterval = 86_400

    /// A new mailbox for a computer joining now through `relay`, where its mailbox lives: the computer is
    /// given it without `writeAuth`.
    public static func makeUpdateMailbox(for machineID: String, at relay: RelayBoxClient) -> Agentkeyring_V2_UpdateMailbox {
        var mailbox = Agentkeyring_V2_UpdateMailbox()
        mailbox.machineID = machineID
        mailbox.relayURL = relay.url
        mailbox.seed = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        mailbox.readAuth = RelayBoxProtocol.newToken()
        mailbox.writeAuth = RelayBoxProtocol.newToken()
        return mailbox
    }

    /// The mailbox as the computer is given it: no write token.
    public static func mailboxGivenToComputer(_ mailbox: Agentkeyring_V2_UpdateMailbox) -> Agentkeyring_V2_UpdateMailbox {
        var given = mailbox
        given.writeAuth = ""
        return given
    }

    /// A Freshness for a computer, signed with this device's reply key: it vouches for these revisions for a week.
    public static func signFreshness(for machineID: String, members: UInt64, catalogue: UInt64, signerKeyID: String,
                                 sign: (Data) throws -> Data) throws -> SignedDocument {
        var fresh = Agentkeyring_V2_Freshness()
        fresh.domain = "agentkeyring.fresh.v2"
        fresh.machineID = machineID
        fresh.membersRevision = members
        fresh.catalogueRevision = catalogue
        fresh.validUntilUnixSeconds = Int64(Date().addingTimeInterval(freshFor).timeIntervalSince1970)
        return try CredentialSealing.signedDocument(fresh.serializedData(), by: signerKeyID, sign: sign)
    }

    /// The relay a mailbox names: nil for one that names none (it lives at the relay this device uses), and
    /// for one that names a relay no device may use.
    public static func mailboxRelay(of mailbox: Agentkeyring_V2_UpdateMailbox) -> RelayBoxClient? {
        mailbox.relayURL.isEmpty ? nil : RelayBoxClient(checking: mailbox.relayURL)
    }

    /// Writes this device's slot in a computer's mailbox, in place of what it wrote before, at the relay the
    /// computer joined through, never another.
    public static func writeMailboxSlot(_ bundle: Agentkeyring_V2_Bundle, to mailbox: Agentkeyring_V2_UpdateMailbox, from deviceKeyID: String,
                             at relay: RelayBoxClient = .configured) async throws {
        if !mailbox.relayURL.isEmpty, Self.mailboxRelay(of: mailbox)?.url != relay.url { throw RelayBoxError.refused(0) }
        try await relay.putRelayBox(bundle.serializedData(), box: RelayBoxProtocol.mailboxSlot(seed: mailbox.seed, deviceKeyID: deviceKeyID),
                            key: RelayBoxProtocol.mailboxKey(seed: mailbox.seed),
                            options: RelayBoxPutOptions(ttl: .update, mode: .replace, readAuth: mailbox.readAuth, writeAuth: mailbox.writeAuth))
    }

    /// The bundle a computer is sent: the lists, every revision of Members, the push registrations, its own
    /// copies of the passwords Automatic for it, and a Freshness. For a computer no longer in `members`, only
    /// the Members that leaves it out, and nothing else.
    public static func computerUpdateBundle(for machineID: String, lists: MailboxSignedLists, copies: [SealedLogin],
                              freshness: () throws -> SignedDocument?) rethrows -> Agentkeyring_V2_Bundle {
        var bundle = Agentkeyring_V2_Bundle()
        bundle.members = lists.members
        bundle.membersSince = lists.membersHistory
        let members = try? Members(serializedBytes: lists.members.payload)
        guard members?.machines.contains(where: { $0.machineID == machineID }) == true else { return bundle }
        if let catalogue = lists.catalogue { bundle.catalogue = catalogue }
        bundle.pushRegistrations = lists.pushRegistrations
        let listed = lists.catalogue.flatMap { try? Catalogue(serializedBytes: $0.payload) }.map { catalogue in
            Dictionary(catalogue.logins.map { ($0.loginID, $0) }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        bundle.copies = copies.filter { copy in
            guard copy.openerID == machineID, let login = listed[copy.loginID] else { return false }
            return login.rule == .automatic && login.version == copy.version && login.version != 0
        }
        if let signedFreshness = try freshness() { bundle.freshness = signedFreshness }
        return bundle
    }
}

/// The signed lists every listed computer's bundle carries: the current Members, every revision of it,
/// the catalogue, and the push registrations.
public struct MailboxSignedLists: Sendable {
    public var members: SignedDocument
    public var membersHistory: [SignedDocument]
    public var catalogue: SignedDocument?
    public var pushRegistrations: [SignedDocument]

    public init(members: SignedDocument, membersHistory: [SignedDocument], catalogue: SignedDocument?,
                pushRegistrations: [SignedDocument]) {
        self.members = members
        self.membersHistory = membersHistory
        self.catalogue = catalogue
        self.pushRegistrations = pushRegistrations
    }
}
