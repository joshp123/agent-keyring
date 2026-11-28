// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// What the iPhone app shows and what it can ask for, as plain values, and the
// one protocol the screens call. Everything real (iCloud, the relay, push, the
// Secure Enclave and Face ID) sits behind PhoneBackend.

import Foundation

/// A saved login as the iPhone lists it. Site and account are readable;
/// the password stays sealed.
public struct PhoneLogin: Identifiable, Hashable, Sendable {

    public let id: String
    public var site: String
    public var account: String
    public var rule: LoginRule
    /// Category ID matching Mac categories (e.g. "codingCloud", "aiTools", "sensitive").
    public var categoryID: String?
    /// How often agents asked for this password.
    public var asked: Int
    /// Its password was deleted when it was Blocked; a new export from Passwords brings it back.
    public var secretDeleted: Bool
    /// Requests for it an agent is using now.
    public var activeLeases: Int

    public init(id: String, site: String, account: String, rule: LoginRule, categoryID: String? = nil, asked: Int = 0, secretDeleted: Bool = false,
                activeLeases: Int = 0) {
        self.id = id; self.site = site; self.account = account; self.rule = rule; self.categoryID = categoryID; self.asked = asked; self.secretDeleted = secretDeleted
        self.activeLeases = activeLeases
    }

    /// As a rule change sees it. The iPhone is not told which grants Always Allowed gave.
    public var planned: RuleChangePlanLogin<String> {
        .init(id: id, rule: rule, holdsSecret: rule != .blocked && !secretDeleted, activeLeases: activeLeases)
    }
}

public enum PhoneDeviceRole: Hashable, Sendable {
    /// A device that approves: this iPhone, a Watch, a MacBook.
    case approves
    /// A machine whose agents ask.
    case asks
}

public enum PhoneDeviceKind: Hashable, Sendable {
    case iPhone
    case watch
    case mac
    case computer
}

public struct PhoneDevice: Identifiable, Hashable, Sendable {

    public typealias PracticeStatus = DevicePracticeStatus

    public let id: String
    public var name: String
    public var kind: PhoneDeviceKind
    /// How it approves, or what it does: "Face ID", "Always on. Passes requests…".
    public var detail: String?
    public var role: PhoneDeviceRole
    public var isThisIPhone: Bool
    /// Practice on its row: a device he answers on, other than this iPhone.
    public var canPractice: Bool
    /// Remove on its row: not this iPhone, and not a Mac's computer row (its device row removes both).
    public var canRemove: Bool
    /// A Mac both approves and has agents that ask: one Remove takes both.
    public var alsoAsks: Bool
    public var readiness: DeviceReadiness
    public var practice: PracticeStatus?

    public init(
        id: String,
        name: String,
        kind: PhoneDeviceKind? = nil,
        detail: String? = nil,
        role: PhoneDeviceRole,
        isThisIPhone: Bool = false,
        canPractice: Bool = false,
        canRemove: Bool = true,
        alsoAsks: Bool = false,
        readiness: DeviceReadiness = .ready,
        practice: PracticeStatus? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind ?? (role == .asks ? .computer : .iPhone)
        self.detail = detail
        self.role = role
        self.isThisIPhone = isThisIPhone
        self.canPractice = canPractice
        self.canRemove = canRemove
        self.alsoAsks = alsoAsks
        self.readiness = readiness
        self.practice = practice
    }
}

public enum PhoneTab: String, Hashable, Sendable {
    case home, logins, devices, settings
}

/// One sentence in Activity when something needs him.
public enum PhoneNotice: Hashable, Sendable, Identifiable {
    /// Apple has not yet given this iPhone a push address.
    case stillConnecting
    /// Not signed in to iCloud: the other devices don't get changes made here.
    case iCloudSignedOut

    public var id: String {
        switch self {
        case .stillConnecting: "stillConnecting"
        case .iCloudSignedOut: "iCloudSignedOut"
        }
    }
}

public struct PhoneFill: Hashable, Sendable {
    public var copied: Int
    public var of: Int
    public init(copied: Int, of: Int) { self.copied = copied; self.of = of }
}

/// What the iPhone can see of its Apple Watch, each a fact the Apple Watch step ticks. The iPhone cannot
/// open or install the Watch app; it can only see these.
public struct PhoneWatchFacts: Hashable, Sendable {
    /// An Apple Watch is paired with this iPhone (WatchConnectivity).
    public var paired = false
    /// Agent Keyring's Watch app is installed on it.
    public var installed = false
    /// The Watch app has run and sent this iPhone its keys.
    public var opened = false
    /// It is in the list of devices.
    public var added = false
    /// It is listed in Members, but its encrypted password copies have not yet been acknowledged by the Mac.
    public var copiesPending = false
    public var notificationsAllowed = false
    /// Apple has given it a push address.
    public var pushAddress = false
    /// It has answered a practice request.
    public var practiceAnswered = false

    public init() {}

    /// Paired and either not added or still missing its encrypted password copies:
    /// keeps the Add Apple Watch flow reachable until copying completes.
    public var toAdd: Bool { paired && (!added || copiesPending) }
}

/// What iOS lets the app see of its notification settings: the facts the notifications checklist ticks.
/// Whether a Focus such as Sleep lets requests through is not among them: no app can read it.
public struct PhoneNotificationFacts: Hashable, Sendable {
    public var allowed = false
    public var banners = false
    public var lockScreen = false
    public var timeSensitive = false
    /// Delivered in a Scheduled Summary, which would hold requests back.
    public var inScheduledSummary = false

    public init() {}
}

/// What iOS says of notifications for the app: whether it has asked him yet, and what he allows.
public struct PhoneNotificationStatus: Hashable, Sendable {
    public var asked: Bool
    public var facts: PhoneNotificationFacts

    public init(asked: Bool, facts: PhoneNotificationFacts) {
        self.asked = asked; self.facts = facts
    }
}

/// The two notification settings (Paper, "On iPhone and Apple Watch", Settings).
public struct PhoneSettings: Hashable, Sendable {
    public var timeSensitive: Bool
    public var quietHours: Bool
    /// Minutes after midnight.
    public var quietFrom: Int
    public var quietTo: Int

    /// One notification once the copy from Passwords is a week old, and none for a week after: off until he turns it on.
    public var remindToUpdate: Bool
    /// The daily anonymous version check (VersionCheck) may count this iPhone.
    public var anonymousTelemetry: Bool

    public init(timeSensitive: Bool = true, quietHours: Bool = false, quietFrom: Int = 23 * 60, quietTo: Int = 7 * 60,
                remindToUpdate: Bool = false, anonymousTelemetry: Bool = true) {
        self.timeSensitive = timeSensitive; self.quietHours = quietHours; self.quietFrom = quietFrom; self.quietTo = quietTo
        self.remindToUpdate = remindToUpdate
        self.anonymousTelemetry = anonymousTelemetry
    }
}

public struct PhoneSnapshot: Hashable, Sendable {
    /// Monotonic revision set by the backend so delayed AsyncStream snapshots never overwrite newer state.
    public var revision: UInt64 = 0
    public var requests: [AccessRequest]
    public var logins: [PhoneLogin]
    public var devices: [PhoneDevice]
    public var firstRun: PhoneFirstRun
    /// First run's practice request, in the real request's layout, while it is open.
    public var practiceRequest: AccessRequest?
    /// The reply sent with a denied practice request, if any, to echo on the confirmation card.
    public var practiceDeniedReply: String?
    /// The Mac this iPhone joined, by name.
    public var macName: String?
    /// What this iPhone can see of its Apple Watch, for the Apple Watch step.
    public var watch = PhoneWatchFacts()
    public var notices: [PhoneNotice] = []
    public var settings = PhoneSettings()
    public var notificationFacts = PhoneNotificationFacts()
    /// Adding Apple Watch, while its flow is open.
    public var addWatch: PhoneAddWatch?
    /// While this iPhone's copies of the passwords arrive after joining: how many are here, of how many.
    public var filling: PhoneFill?
    /// Requests whose answer is not delivered yet: the relay cannot be reached, and it is retried.
    public var undelivered: Set<String> = []
    /// In the signed list of devices.
    public var joined = false
    /// Copying from Passwords on this iPhone.
    public var passwordsCopy = PhonePasswordsCopy()
    /// Adding another computer from this iPhone, while its page is open.
    public var addComputer: PhoneAddComputer?
    /// A Mac or another iPhone asking to join this iPhone's list through iCloud.
    public var deviceJoin: PhoneDeviceJoin?
    /// A computer or a Mac is in the list: Ready need not offer Add a Computer.
    public var hasComputer = false
    /// Another device changed the list while apart from this iPhone: the merged list waits to be signed and sent
    /// (`sendUnsentChanges`), and computers are sent no changes until it is.
    public var hasUnsentUpdates = false

    public init(firstRun: PhoneFirstRun, requests: [AccessRequest] = [], logins: [PhoneLogin] = [], devices: [PhoneDevice] = [],
                practiceRequest: AccessRequest? = nil) {
        self.firstRun = firstRun; self.requests = requests; self.logins = logins; self.devices = devices
        self.practiceRequest = practiceRequest
    }
}

/// Stop could not reach the asking computer, so it waits with the Mac until that computer next asks.
public struct PhoneStopNotConfirmed: Error { public init() {} }

@MainActor
public protocol PhoneBackend: AnyObject {
    /// The current snapshot first, then one each time anything changes.
    func phoneSnapshotUpdates() -> AsyncStream<PhoneSnapshot>
    /// Face ID, then the answer goes to the machine that asked. `reusingUnlock`:
    /// a Face ID unlock of the phone in the last few seconds counts, so an
    /// Approve pressed on the Lock Screen needs one look, not two.
    func approveAccessRequest(_ requestID: String, reusingUnlock: Bool) async throws
    func denyAccessRequest(_ requestID: String, reply: String?) async throws
    func endApprovedAccess(_ requestID: String) async throws
    /// Changing a rule is signed by this iPhone after Face ID.
    func setLoginRule(_ rule: LoginRule, forLogin loginID: String) async throws
    /// Batch-changes rules for multiple logins under one Face ID and one Catalogue revision.
    func setLoginRule(_ rule: LoginRule, forLogins loginIDs: [String]) async throws
    /// Signs and sends the merged list after one Face ID, while `hasUnsentUpdates`.
    func sendUnsentChanges() async throws
    /// Removing a device is signed by this iPhone after Face ID.
    func removeDevice(device deviceID: String) async throws
    /// A step of first run: a tap, or what iOS answered.
    func sendFirstRunEvent(_ event: PhoneFirstRunEvent) async
    /// What iOS now allows, read again each time the app comes to the front.
    func checkNotifications() async -> PhoneNotificationStatus
    /// iOS's own question about notifications. True if he allowed them.
    func askForNotifications() async -> Bool
    /// A practice request to this iPhone (nil) or to another device he answers on. For this iPhone, returns
    /// the one already waiting, to be shown again, instead of making a second.
    func sendPracticeRequest(to deviceID: String?) async -> String?
    func savePhoneSettings(_ settings: PhoneSettings) async
    /// A tap in the Apple Watch flow.
    func handleAddWatchTap(_ tap: PhoneAddWatchTap) async
    /// "Set Up on This iPhone": this iPhone keeps the passwords itself, with no Mac.
    func setUpHere() async throws
    /// "Turn On in Passwords": iOS asks to let Passwords export to Agent Keyring (`asking`), or it is only
    /// read again. True once it may.
    func turnOnInPasswords(asking: Bool) async -> Bool
    /// A tap on the page that adds another computer.
    func handleAddComputerTap(_ tap: PhoneAddComputerTap) async
    /// Add (after Face ID) or Don't Add, for the Mac or iPhone asking to join this iPhone's list.
    func answerDeviceJoin(add: Bool) async throws
    /// Drops the cached iCloud change token and pulls/pushes everything fresh.
    func syncWithICloudNow() async
    /// Clears local state on this iPhone (and paired Apple Watch) and returns to first-run setup.
    /// When `includingICloud` is true, also deletes the AgentKeyringVault iCloud zone and iCloud Keychain invitation.
    func resetKeyring(includingICloud: Bool) async throws
}
