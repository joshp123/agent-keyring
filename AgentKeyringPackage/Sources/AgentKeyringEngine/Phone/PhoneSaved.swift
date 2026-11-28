// Written by AI on 2026.11.18 by model Claude Opus 5.5; for the direct protocol on 2026.11.21;
// protobuf persistence on 2026.11.27; the lists as a KeyringReplica, with the iCloud checkpoint, on 2026.11.27 by model claude opus 5.5.
//
// What the iPhone keeps between launches, and what it shares with its
// notification service extension.

import AgentKeyringApprovalCore
import AgentKeyringProtocol
import AgentKeyringSealing
import Foundation
import Security
import UserNotifications

/// Why this iPhone could not do what was asked.
enum PhoneApprovalError: Error, Equatable, CustomStringConvertible {
    case notJoined
    case passwordsMissing
    case notAllowed(String)
    var description: String {
        switch self {
        case .notJoined: "this iPhone has not joined"
        case .passwordsMissing: "Some passwords are not on this iPhone yet."
        case let .notAllowed(words): words
        }
    }
}

/// Persisted iPhone state, stored as `"AKRPHN02"` + `StoredPhoneState` protobuf: the lists as every device
/// keeps them (KeyringReplica), with the iCloud checkpoint, in one file written whole.
package struct PhoneSavedState: Equatable, KeyringReplica {
    static let protobufMagic = Data("AKRPHN02".utf8)

    enum StorageError: Error {
        case invalidMagic
    }

    package var members: Data?
    /// Last signed Members confirmed in iCloud: kept even if more than 20 offline edits roll `membersHistory`.
    package var cloudAcceptedMembers: Data?
    package var catalogue: Data?
    /// Other devices' signed catalogues of the held one's revision.
    package var contestedCatalogues: [Data] = []
    /// Last signed Catalogue confirmed in iCloud.
    package var cloudAcceptedCatalogue: Data?
    /// This iPhone's own copy of every password that is not Blocked, as the Mac sent them: serialized SealedLogins.
    var copies: Data?
    /// The most recent serialized request envelope for each request ID.
    var requestEnvelopes: [String: Data] = [:]
    /// request id -> what this iPhone answered, until the outcome arrives.
    var answered: [String: Bool] = [:]
    /// This iPhone's Device.key_id, once joined; the extension needs it to open a notice.
    var deviceKeyID: String?
    /// Where first run stands; an unrecognized stage from an earlier or newer build reads as nil.
    var firstRun: PhoneFirstRun?
    /// A push reached this iPhone since it joined.
    var pushSeen = false
    /// What the Watch found when it tested itself, as its app sent it (serialized WatchSelfTest).
    var watchSelfTest: Data?
    /// The Watch's Device and PushRegistration, serialized, as its app sent them after Add, until it is listed.
    var watchDevice: Data?
    var watchPush: Data?
    /// The notification settings; nil means the defaults.
    var settings: NotificationSettings?
    /// Reply sent with the last denied practice request, kept across relaunches for the result screen.
    var lastPracticeReply: String?
    /// Watch key ID that is listed in Members whose encrypted password copies have not yet been acknowledged by the Mac.
    var watchCopiesPending: String?
    /// Every Members revision taken since joining, oldest first, and every device's signed push registration,
    /// by device key ID: sent with answers in a box (AnswerUpload.bundle).
    package var membersHistory: [Data] = []
    package var pushRegistrations: [String: Data] = [:]
    /// This iPhone's own vault: every login without its secret (a StoredVaultSnapshot), other devices' folded in.
    var ownVaultSnapshot: Data?
    /// Copies this iPhone sealed for its other devices and computers: serialized SealedLogins.
    var sealedForOthers: Data?
    /// When this iPhone last copied from Passwords.
    var copiedAt: Date?
    /// "Remind Me to Update Passwords": off until he turns it on.
    var remindToUpdate: Bool?
    /// The invitation this iPhone left in iCloud Keychain for a new Mac or iPhone: serialized JoinInvite.
    var invitation: Data?
    /// A Mac or iPhone asking through iCloud to join, until he answers or it runs out.
    var deviceJoin: PendingDeviceJoin?
    /// Each computer's update mailbox, with its write token, by machine ID: serialized UpdateMailbox.
    package var mailboxes: [String: Data] = [:]
    /// Apple Watch's copies: the last generation sent to it, the one it says it holds, and the copies the
    /// Mac sealed for it, from iCloud, to pass on (serialized SealedLogins).
    var watchCopiesSent: UInt64?
    var watchCopiesHeld: UInt64?
    var watchCopiesFromOthers: Data?
    /// An approved computer join whose `JoinStatus` has not yet been delivered to the relay response box.
    var pendingComputerDelivery: PendingComputerDelivery?
    /// Where this iPhone has read iCloud up to.
    package var cloudCheckpoint = CloudCheckpoint()

    package init() {}

    func encodeProtobuf() throws -> Data {
        Self.protobufMagic + (try storedProto().serializedData())
    }

    static func decodeProtobuf(_ data: Data) throws -> PhoneSavedState {
        guard data.starts(with: protobufMagic) else {
            throw StorageError.invalidMagic
        }
        let proto = try Agentkeyring_V2_StoredPhoneState(serializedBytes: Data(data.dropFirst(protobufMagic.count)))
        return PhoneSavedState(storedProto: proto)
    }

    init(storedProto proto: Agentkeyring_V2_StoredPhoneState) {
        members = proto.hasMembers ? proto.members : nil
        cloudAcceptedMembers = proto.hasCloudAcceptedMembers ? proto.cloudAcceptedMembers : nil
        catalogue = proto.hasCatalogue ? proto.catalogue : nil
        contestedCatalogues = proto.contestedCatalogues
        cloudAcceptedCatalogue = proto.hasCloudAcceptedCatalogue ? proto.cloudAcceptedCatalogue : nil
        copies = proto.hasCopies ? proto.copies : nil
        requestEnvelopes = proto.requestEnvelopes
        answered = proto.answered
        deviceKeyID = proto.hasDeviceKeyID ? proto.deviceKeyID : nil
        firstRun = proto.hasFirstRun ? PhoneFirstRun(storedProto: proto.firstRun) : nil
        pushSeen = proto.pushSeen
        watchSelfTest = proto.hasWatchSelfTest ? proto.watchSelfTest : nil
        watchDevice = proto.hasWatchDevice ? proto.watchDevice : nil
        watchPush = proto.hasWatchPush ? proto.watchPush : nil
        if proto.hasSettings {
            var decoded = NotificationSettings()
            decoded.timeSensitive = proto.settings.timeSensitive
            decoded.quietHours = proto.settings.quietHours
            decoded.quietFrom = Int(proto.settings.quietFromMinutes)
            decoded.quietTo = Int(proto.settings.quietToMinutes)
            settings = decoded
        } else {
            settings = nil
        }
        lastPracticeReply = proto.hasLastPracticeReply ? proto.lastPracticeReply : nil
        watchCopiesPending = proto.hasWatchCopiesPending ? proto.watchCopiesPending : nil
        membersHistory = proto.membersHistory
        pushRegistrations = proto.pushRegistrations
        ownVaultSnapshot = proto.hasOwnVaultSnapshot ? proto.ownVaultSnapshot : nil
        sealedForOthers = proto.hasSealedForOthers ? proto.sealedForOthers : nil
        copiedAt = proto.hasCopiedAtUnixSeconds ? Date(timeIntervalSince1970: proto.copiedAtUnixSeconds) : nil
        remindToUpdate = proto.hasRemindToUpdate ? proto.remindToUpdate : nil
        invitation = proto.hasInvitation ? proto.invitation : nil
        deviceJoin = proto.hasDeviceJoin ? PendingDeviceJoin(storedProto: proto.deviceJoin) : nil
        mailboxes = proto.mailboxes
        watchCopiesSent = proto.hasWatchCopiesSent ? proto.watchCopiesSent : nil
        watchCopiesHeld = proto.hasWatchCopiesHeld ? proto.watchCopiesHeld : nil
        watchCopiesFromOthers = proto.hasWatchCopiesFromOthers ? proto.watchCopiesFromOthers : nil
        pendingComputerDelivery = proto.hasPendingComputerDelivery
            ? PendingComputerDelivery(storedProto: proto.pendingComputerDelivery)
            : nil
        cloudCheckpoint = CloudCheckpoint(stored: proto.cloudCheckpoint)
    }

    func storedProto() -> Agentkeyring_V2_StoredPhoneState {
        var proto = Agentkeyring_V2_StoredPhoneState()
        storeKeyringLists(in: &proto)
        storeWatchState(in: &proto)
        proto.requestEnvelopes = requestEnvelopes
        proto.answered = answered
        if let deviceKeyID { proto.deviceKeyID = deviceKeyID }
        if let firstRun { proto.firstRun = firstRun.storedProto() }
        proto.pushSeen = pushSeen
        if let lastPracticeReply { proto.lastPracticeReply = lastPracticeReply }
        proto.pushRegistrations = pushRegistrations
        if let remindToUpdate { proto.remindToUpdate = remindToUpdate }
        if let invitation { proto.invitation = invitation }
        if let deviceJoin { proto.deviceJoin = deviceJoin.storedProto() }
        proto.mailboxes = mailboxes
        if let pendingComputerDelivery { proto.pendingComputerDelivery = pendingComputerDelivery.storedProto() }
        return proto
    }

    /// The signed lists, this iPhone's copies, and how far iCloud has been read.
    private func storeKeyringLists(in proto: inout Agentkeyring_V2_StoredPhoneState) {
        if let members { proto.members = members }
        if let cloudAcceptedMembers { proto.cloudAcceptedMembers = cloudAcceptedMembers }
        if let catalogue { proto.catalogue = catalogue }
        proto.contestedCatalogues = contestedCatalogues
        if let cloudAcceptedCatalogue { proto.cloudAcceptedCatalogue = cloudAcceptedCatalogue }
        if let copies { proto.copies = copies }
        proto.membersHistory = membersHistory
        if let ownVaultSnapshot { proto.ownVaultSnapshot = ownVaultSnapshot }
        if let sealedForOthers { proto.sealedForOthers = sealedForOthers }
        if let copiedAt { proto.copiedAtUnixSeconds = copiedAt.timeIntervalSince1970 }
        proto.cloudCheckpoint = cloudCheckpoint.stored
    }

    /// Apple Watch: the device, its push address and settings, and its copies.
    private func storeWatchState(in proto: inout Agentkeyring_V2_StoredPhoneState) {
        if let watchSelfTest { proto.watchSelfTest = watchSelfTest }
        if let watchDevice { proto.watchDevice = watchDevice }
        if let watchPush { proto.watchPush = watchPush }
        if let settings {
            var stored = Agentkeyring_V2_WatchNotificationSettings()
            stored.timeSensitive = settings.timeSensitive
            stored.quietHours = settings.quietHours
            stored.quietFromMinutes = Int32(settings.quietFrom)
            stored.quietToMinutes = Int32(settings.quietTo)
            proto.settings = stored
        }
        if let watchCopiesPending { proto.watchCopiesPending = watchCopiesPending }
        if let watchCopiesSent { proto.watchCopiesSent = watchCopiesSent }
        if let watchCopiesHeld { proto.watchCopiesHeld = watchCopiesHeld }
        if let watchCopiesFromOthers { proto.watchCopiesFromOthers = watchCopiesFromOthers }
    }
}

/// A device's request to join through iCloud, kept so a request heard in the background is shown when the app opens.
struct PendingDeviceJoin: Equatable {
    /// Serialized JoinRequest naming the device.
    var device: Data
    /// A Mac's second JoinRequest, naming it as the computer its own agents run on.
    var machine: Data?
    var asked: Date

    init(device: Data, machine: Data?, asked: Date) {
        self.device = device
        self.machine = machine
        self.asked = asked
    }

    init(storedProto proto: Agentkeyring_V2_StoredPendingDeviceJoin) {
        device = proto.device
        machine = proto.hasMachine ? proto.machine : nil
        asked = Date(timeIntervalSince1970: proto.askedUnixSeconds)
    }

    func storedProto() -> Agentkeyring_V2_StoredPendingDeviceJoin {
        var proto = Agentkeyring_V2_StoredPendingDeviceJoin()
        proto.device = device
        if let machine { proto.machine = machine }
        proto.askedUnixSeconds = asked.timeIntervalSince1970
        return proto
    }
}

/// An approved computer join whose `JoinStatus` is persisted until `ComputerJoinCoordinator.sendJoinStatus(...)` delivers it.
struct PendingComputerDelivery: Equatable, Sendable {
    var joinRequest: Data
    var joinSecret: Data
    var relayURL: String
    var machineID: String
    var machineLabel: String
    var statusPayload: Data
    var expiresAt: Date
    /// The computer's whole mailbox, write token included: the status sent holds only its read side.
    var mailbox: Data

    init(joinRequest: Data, joinSecret: Data, relayURL: String, machineID: String,
         machineLabel: String, statusPayload: Data, expiresAt: Date, mailbox: Data) {
        self.joinRequest = joinRequest
        self.joinSecret = joinSecret
        self.relayURL = relayURL
        self.machineID = machineID
        self.machineLabel = machineLabel
        self.statusPayload = statusPayload
        self.expiresAt = expiresAt
        self.mailbox = mailbox
    }

    init(storedProto proto: Agentkeyring_V2_StoredPhonePendingComputerDelivery) {
        joinRequest = proto.joinRequest
        joinSecret = proto.joinSecret
        relayURL = proto.relayURL
        machineID = proto.machineID
        machineLabel = proto.machineLabel
        statusPayload = proto.statusPayload
        expiresAt = Date(timeIntervalSince1970: proto.expiresAtUnixSeconds)
        mailbox = proto.mailbox
    }

    func storedProto() -> Agentkeyring_V2_StoredPhonePendingComputerDelivery {
        var proto = Agentkeyring_V2_StoredPhonePendingComputerDelivery()
        proto.joinRequest = joinRequest
        proto.joinSecret = joinSecret
        proto.relayURL = relayURL
        proto.machineID = machineID
        proto.machineLabel = machineLabel
        proto.statusPayload = statusPayload
        proto.expiresAtUnixSeconds = expiresAt.timeIntervalSince1970
        proto.mailbox = mailbox
        return proto
    }
}

extension PhoneFirstRun {
    init?(storedProto proto: Agentkeyring_V2_StoredPhoneFirstRun) {
        let macName = proto.hasMacName ? proto.macName : nil
        switch proto.stage {
        case .searching: self = .searching
        case .welcome: self = .welcome
        case .trouble: self = .trouble
        case .foundMac: self = .foundMac(name: macName)
        case .waitingForMac: self = .waitingForMac(name: macName)
        case .deniedByMac: self = .deniedByMac(name: macName)
        case .cantReachMac: self = .cantReachMac(name: macName)
        case .expired: self = .expired(name: macName)
        case .receivingPasswords: self = .receivingPasswords
        case .importPasswords: self = .importPasswords
        case .notifications: self = .notifications
        case .askingNotifications: self = .askingNotifications
        case .notificationsOff: self = .notificationsOff
        case .practiceOffer: self = .practiceOffer
        case .practiceWaiting: self = .practiceWaiting(id: proto.practiceID, arrived: proto.practiceArrived)
        case .settingUpNotifications: self = .settingUpNotifications(id: proto.practiceID)
        case .practiceNotArrived: self = .practiceNotArrived(id: proto.practiceID)
        case .practiceMacUnreachable: self = .practiceMacUnreachable(id: proto.practiceID)
        case .practice: self = .practice(id: proto.practiceID)
        case .practiceResult:
            switch proto.practiceOutcome {
            case .approved: self = .practiceResult(.approved)
            case .denied: self = .practiceResult(.denied)
            case .noAnswer: self = .practiceResult(.noAnswer)
            default: return nil
            }
        case .readyOfferWatch: self = .readyOfferWatch(watchToAdd: proto.watchToAdd)
        case .addWatch: self = .addWatch
        case .addComputer: self = .addComputer
        case .finished: self = .finished
        default: return nil
        }
    }

    func storedProto() -> Agentkeyring_V2_StoredPhoneFirstRun {
        var proto = Agentkeyring_V2_StoredPhoneFirstRun()
        switch self {
        case .searching:
            proto.stage = .searching
        case .welcome:
            proto.stage = .welcome
        case .trouble:
            proto.stage = .trouble
        case let .foundMac(name):
            proto.stage = .foundMac
            if let name { proto.macName = name }
        case let .waitingForMac(name):
            proto.stage = .waitingForMac
            if let name { proto.macName = name }
        case let .deniedByMac(name):
            proto.stage = .deniedByMac
            if let name { proto.macName = name }
        case let .cantReachMac(name):
            proto.stage = .cantReachMac
            if let name { proto.macName = name }
        case let .expired(name):
            proto.stage = .expired
            if let name { proto.macName = name }
        case .receivingPasswords:
            proto.stage = .receivingPasswords
        case .importPasswords:
            proto.stage = .importPasswords
        case .notifications:
            proto.stage = .notifications
        case .askingNotifications:
            proto.stage = .askingNotifications
        case .notificationsOff:
            proto.stage = .notificationsOff
        case .practiceOffer:
            proto.stage = .practiceOffer
        case let .practiceWaiting(id, arrived):
            proto.stage = .practiceWaiting
            proto.practiceID = id
            proto.practiceArrived = arrived
        case let .settingUpNotifications(id):
            proto.stage = .settingUpNotifications
            proto.practiceID = id
        case let .practiceNotArrived(id):
            proto.stage = .practiceNotArrived
            proto.practiceID = id
        case let .practiceMacUnreachable(id):
            proto.stage = .practiceMacUnreachable
            proto.practiceID = id
        case let .practice(id):
            proto.stage = .practice
            proto.practiceID = id
        case let .practiceResult(outcome):
            proto.stage = .practiceResult
            proto.practiceOutcome = switch outcome {
            case .approved: .approved
            case .denied: .denied
            case .noAnswer: .noAnswer
            }
        case let .readyOfferWatch(watchToAdd):
            proto.stage = .readyOfferWatch
            proto.watchToAdd = watchToAdd
        case .addWatch:
            proto.stage = .addWatch
        case .addComputer:
            proto.stage = .addComputer
        case .finished:
            proto.stage = .finished
        }
        return proto
    }
}

/// Time asked of iOS to finish one call after the app leaves the screen.
/// The iOS app wires UIApplication background tasks here at launch so PhoneApprover never imports UIKit.
@MainActor
public enum PhoneBackgroundTime {
    public static var beginTask: @MainActor (String) -> (@MainActor () -> Void) = { _ in {} }

    static func begin(_ name: String) -> (@MainActor () -> Void) { beginTask(name) }
}

/// The notifications this app has shown for a request.
public enum PhoneDeliveredNotifications {
    /// Removes a request's notification once it is answered or has ended, so none is left behind.
    public static func removeRequestNotification(_ requestID: String) {
        KeyringDiagnosticLog.iPhone.noteDeviceEvent("notification", "removed", ["request": requestID])
        #if os(iOS)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [requestID])
        center.getDeliveredNotifications { delivered in
            let same = delivered.filter { $0.request.content.threadIdentifier == requestID }.map(\.request.identifier)
            if !same.isEmpty { center.removeDeliveredNotifications(withIdentifiers: same) }
        }
        #endif
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
