// Written by AI on 2026.11.27 by model gpt-6.2-sol.

#if os(macOS) && DEBUG
import AgentKeyringApprovalCore
import AgentKeyringEngine
import AgentKeyringProtocol
import AgentKeyringSealing
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
final class PeerInvitation {
    var card: Agentkeyring_V2_JoinInvite?
}

enum RuleContestOrder: String {
    case tie, macNewer = "mac-newer", phoneNewer = "phone-newer"

    var macOffsetMs: Int64 {
        switch self {
        case .tie: 0
        case .macNewer: 1
        case .phoneNewer: -1
        }
    }

    var winner: Agentkeyring_V2_Rule { self == .macNewer ? .automatic : .blocked }
}

@MainActor
private final class SoftwarePhoneKeys: PhoneDeviceKeys {
    private let signing = P256.Signing.PrivateKey()
    private let opening = P256.KeyAgreement.PrivateKey()
    private let reply = P256.Signing.PrivateKey()
    private let notice = P256.KeyAgreement.PrivateKey()

    func signingPublicKey() throws -> Data { signing.publicKey.x963Representation }
    func openingPublicKey() throws -> Data { opening.publicKey.x963Representation }
    func replyPublicKey() throws -> Data { reply.publicKey.x963Representation }
    func noticePublicKey() throws -> Data { notice.publicKey.x963Representation }
    func authorize(_ context: LAContext, reason: String) async throws {}
    func signWithDeviceKey(_ bytes: Data, context: LAContext) throws -> Data { try signing.signature(for: bytes).derRepresentation }
    func openSealedLogin(_ sealed: SealedLogin, context: LAContext) throws -> LoginSecret { try CredentialSealing.openSealedLogin(sealed, with: opening) }
    func signReply(_ bytes: Data) throws -> Data { try reply.signature(for: bytes).derRepresentation }
    func replySigner() throws -> @Sendable (Data) throws -> Data {
        { [reply] in try reply.signature(for: $0).derRepresentation }
    }
    func opener(context: LAContext) throws -> @Sendable (SealedLogin) throws -> LoginSecret {
        { [opening] in try CredentialSealing.openSealedLogin($0, with: opening) }
    }
    func openNotice(_ notice: Agentkeyring_V2_Notice, deviceKeyID: String) throws -> Agentkeyring_V2_SignedRequestEnvelope {
        try CredentialSealing.openNotice(notice, deviceKeyID: deviceKeyID, with: self.notice)
    }
    func cloudKeyOpener() throws -> CloudEnvelope.KeyOpener {
        { [notice] in try CloudEnvelope.hpkeOpen(encapsulatedKey: $0, ciphertext: $1, info: $2, authenticating: $3, with: notice) }
    }
}

@MainActor
extension TestPeer {
    func enrolPhone() async throws {
        guard phone == nil else { throw PeerError("The phone is already running") }
        let keys = SoftwarePhoneKeys()
        let tls = try DeviceTLSIdentity.ephemeral()
        let phone = PhoneKeyringEngine(directory: directory.appending(path: "phone"), shared: .memory(),
                                 keys: keys, identity: { tls }, cloud: cloud)
        self.phone = phone
        phone.invitationStore = .followingInvite { [invitation] in invitation.card }
        device.leaveInvitationForIPhone()
        phone.startBackgroundWork()
        _ = try await waitFor("phone to discover Mac") { phone.snapshot.macName }
        await phone.sendFirstRunEvent(.connect)
        let keyID = CredentialSealing.keyID(try keys.signingPublicKey())
        let join = try await waitFor("iPhone join on the Mac") {
            device.cloudChanged()
            return device.joins.first { MacSyncCoordinator.joinID($0) == keyID }
        }
        try await device.approveJoin(MacSyncCoordinator.joinID(join), context: LAContext(), onAuthenticated: {})
        try await waitForPhone("iPhone catalogue and copies", phone: phone) {
            $0.joined && !$0.logins.isEmpty && $0.filling == nil
        }
        try await phone.registerPush(token: RecordedPushes.phoneToken, topic: RecordedPushes.topic, production: false)
        _ = try await waitFor("iPhone push registration on the Mac") {
            device.cloudChanged()
            return device.hasPushRegistration(for: keyID) ? true : nil
        }
    }

    func waitForPhone(_ label: String, phone: PhoneKeyringEngine, until ready: (PhoneSnapshot) -> Bool) async throws {
        var observed: [String: CloudRecord]?
        _ = try await waitFor(label) {
            let records = cloud.records
            if records != observed {
                observed = records
                await phone.received(["rev": true])
            }
            return ready(phone.snapshot) ? true : nil
        }
    }

    func removePhone() async throws -> String {
        guard let member = device.members?.devices.first(where: { $0.kind == .iphone }) else {
            throw PeerError("Enrol the phone first")
        }
        try await device.removeConfirmed(member.keyID, context: LAContext())
        guard let members = device.members, !members.devices.contains(where: { $0.keyID == member.keyID }) else {
            throw PeerError("The phone is still a member")
        }
        return String(members.revision)
    }

    func contestRule(for id: UUID, order: RuleContestOrder) async throws {
        guard let phone else { throw PeerError("Enrol the phone first") }
        let loginID = id.uuidString
        try await waitForPhone("common Ask rule", phone: phone) {
            $0.logins.contains { $0.id == loginID && $0.rule == .ask }
        }
        guard let revision = device.catalogue?.revision,
              try phoneCatalogue().revision == revision,
              device.catalogue?.logins.first(where: { $0.loginID == loginID })?.rule == .ask else {
            throw PeerError("Both peers must start from the same Ask revision")
        }
        // Partition the pipe so each peer signs its own next revision from the shared Ask state.
        cloud.setAvailability(.unavailable("Test partition"))
        defer {
            ruleClock.date = nil
            cloud.setAvailability(.available)
        }
        try await phone.setLoginRule(.blocked, forLogin: loginID)
        let phoneEdit = try phoneCatalogue()
        guard phoneEdit.revision == revision + 1,
              let phoneLogin = phoneEdit.logins.first(where: { $0.loginID == loginID }),
              phoneLogin.rule == .blocked else {
            throw PeerError("The phone did not sign its offline Block")
        }
        // Anchor the Mac clock to the phone's signed timestamp, so even a slow test
        // produces the chosen ordering at the same catalogue revision.
        let macTimestamp = phoneLogin.ruleUpdatedUnixMs + order.macOffsetMs
        ruleClock.date = Date(timeIntervalSince1970: Double(macTimestamp) / 1000)
        try await setRule(.automatic, for: id)
        guard device.catalogue?.revision == revision + 1,
              let macLogin = device.catalogue?.logins.first(where: { $0.loginID == loginID }),
              macLogin.rule == .automatic, macLogin.ruleUpdatedUnixMs == macTimestamp else {
            throw PeerError("The Mac did not sign its offline Automatic edit at the expected millisecond")
        }
        cloud.setAvailability(.available)
        let winningTimestamp = max(macTimestamp, phoneLogin.ruleUpdatedUnixMs)
        let phoneWinner: LoginRule = order.winner == .automatic ? .automatic : .blocked
        let macContest = CloudRecordKind.contested(device.ownDeviceID)
        var observed: [String: CloudRecord]?
        _ = try await waitFor("both peers to converge on \(order.winner) for \(order.rawValue)") { () async -> Bool? in
            let records = cloud.records
            if records != observed {
                observed = records
                device.cloudChanged()
                await phone.received(["rev": true])
            }
            let macLogin = device.catalogue?.logins.first { $0.loginID == loginID }
            let phoneAgrees = phone.snapshot.logins.contains { $0.id == loginID && $0.rule == phoneWinner }
            // When Automatic wins, the Mac already shows that rule before it sees the phone's edit.
            guard records[macContest] != nil, let macLogin,
                  macLogin.rule == order.winner, macLogin.ruleUpdatedUnixMs == winningTimestamp,
                  (macLogin.version == 0) == (order.winner == .blocked), phoneAgrees else { return nil }
            return true
        }
        // The conflict withholds mailbox updates until the owner sends the merged catalogue.
        try await model.publishChangesThrowing()
        let merged = device.catalogue?.revision
        guard let merged, merged > revision + 1 else {
            throw PeerError("The merged catalogue was not signed (unsent changes: \(model.unsentChanges.total))")
        }
        try await waitForPhone("iPhone to take the signed merge", phone: phone) { snapshot in
            (try? phoneCatalogue().revision) == merged
                && snapshot.logins.contains { $0.id == loginID && $0.rule == phoneWinner }
        }
    }

    // The phone's UI snapshot has a presentation revision. Read the persisted signed catalogue
    // to verify the peers actually produced conflicting documents at the same protocol revision.
    private func phoneCatalogue() throws -> Catalogue {
        let file = directory.appending(path: "phone/phone-v2.pb")
        let bytes = try Data(contentsOf: file)
        let magic = Data("AKRPHN02".utf8)
        guard bytes.starts(with: magic) else { throw PeerError("Unrecognised phone state") }
        let state = try Agentkeyring_V2_StoredPhoneState(serializedBytes: Data(bytes.dropFirst(magic.count)))
        let signed = try SignedDocument(serializedBytes: state.catalogue)
        return try Catalogue(serializedBytes: signed.payload)
    }
}
#endif
