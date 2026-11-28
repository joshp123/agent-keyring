// Written by AI on 2026.11.18 by model claude opus 5.5; rebuilt on 2026.11.26
// by model gemini-4-neon; split into its own file on 2026.11.27 by model claude opus 5.5.
//
// What the main Mac window shows (rows and snapshot) and the backend it calls.

#if os(macOS)
import AgentKeyringApprovalCore
import AgentKeyringDesign
import Foundation

public struct LoginRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var site: String
    public var account: String
    public var rule: LoginRule
    public var category: ImportCategory
    public var asked: Int
    public var approved: Int
    public var denied: Int
    public var isTestPassword: Bool
    public var secretDeleted: Bool
    /// Grants of it an agent is using or collecting now, and how many of them Always Allowed gave.
    public var activeLeases: Int
    public var automaticLeases: Int

    public init(
        id: UUID,
        site: String,
        account: String,
        rule: LoginRule,
        category: ImportCategory = .other,
        asked: Int = 0,
        approved: Int = 0,
        denied: Int = 0,
        isTestPassword: Bool = false,
        secretDeleted: Bool = false,
        activeLeases: Int = 0,
        automaticLeases: Int = 0
    ) {
        self.id = id
        self.site = site
        self.account = account
        self.rule = rule
        self.category = category
        self.asked = asked
        self.approved = approved
        self.denied = denied
        self.isTestPassword = isTestPassword
        self.secretDeleted = secretDeleted
        self.activeLeases = activeLeases
        self.automaticLeases = automaticLeases
    }

    public var ruleOrder: Int { LoginRule.allCases.firstIndex(of: rule) ?? 0 }

    /// As a rule change sees it.
    public var planned: RuleChangePlanLogin<UUID> {
        .init(id: id, rule: rule, holdsSecret: rule != .blocked && !secretDeleted, activeLeases: activeLeases, automaticLeases: automaticLeases)
    }
}

public typealias PracticeStatus = DevicePracticeStatus

/// `mac`: another Mac Josh approves on.
public enum ApproverDeviceKind: Sendable { case thisMac, iPhone, watch, mac }

public struct ApproverRow: Identifiable, Hashable, Sendable {
    public let id: String
    public var kind: ApproverDeviceKind
    public var name: String
    public var practice: PracticeStatus?
    public var canPractise: Bool
    public var readiness: DeviceReadiness
    /// A Mac whose agents also ask: one Remove takes both.
    public var alsoAsks: Bool

    public init(id: String, kind: ApproverDeviceKind, name: String, practice: PracticeStatus? = nil, canPractise: Bool, readiness: DeviceReadiness = .ready,
                alsoAsks: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.practice = practice
        self.canPractise = canPractise
        self.readiness = readiness
        self.alsoAsks = alsoAsks
    }
}

public struct ComputerRow: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum DevicesNotice: Hashable, Sendable {
    case noICloud
    case noPushKey
}

public enum DevicesSheet: String, Identifiable, Sendable {
    case addIPhone, addComputer
    public var id: String { rawValue }
}

public struct MainSnapshot: Hashable, Sendable {
    public var logins: [LoginRow]
    public var importedAt: Date?
    public var sampleOnly: Bool
    public var approvers: [ApproverRow]
    public var computers: [ComputerRow]
    public var notices: [DevicesNotice]
    public var unsentChanges: Int
    public var copyChangedNothing: Bool
    public var copyIsStale: Bool
    public var remindsToUpdate: Bool?
    public var opensAtLogin: Bool?
    /// The daily anonymous version check may count this Mac.
    public var anonymousTelemetry: Bool
    public var requests: [AccessRequest]
    public var enrolments: [DeviceEnrolment]

    public init(
        logins: [LoginRow],
        importedAt: Date?,
        sampleOnly: Bool = false,
        approvers: [ApproverRow] = [],
        computers: [ComputerRow] = [],
        notices: [DevicesNotice] = [],
        unsentChanges: Int = 0,
        copyChangedNothing: Bool = false,
        copyIsStale: Bool = false,
        remindsToUpdate: Bool? = nil,
        opensAtLogin: Bool? = nil,
        anonymousTelemetry: Bool = true,
        requests: [AccessRequest] = [],
        enrolments: [DeviceEnrolment] = []
    ) {
        self.logins = logins
        self.importedAt = importedAt
        self.sampleOnly = sampleOnly
        self.approvers = approvers
        self.computers = computers
        self.notices = notices
        self.unsentChanges = unsentChanges
        self.copyChangedNothing = copyChangedNothing
        self.copyIsStale = copyIsStale
        self.remindsToUpdate = remindsToUpdate
        self.opensAtLogin = opensAtLogin
        self.anonymousTelemetry = anonymousTelemetry
        self.requests = requests
        self.enrolments = enrolments
    }
}

@MainActor
public protocol MainWindowBackend: AnyObject {
    func mainWindowSnapshotUpdates() -> AsyncStream<MainSnapshot>
    /// One Touch ID for every change, asked by the backend in macOS's own dialog.
    func saveLoginRules(_ changes: [UUID: LoginRule]) async throws
    func removeDevice(id: String) async throws
    func renameDevice(id: String, to newName: String) async throws
    /// Closes macOS's dialog if a rule change, removal or rename is still waiting for Touch ID.
    func cancelAuthentication()
    func importAgain()
    func addManualPassword(website: String, account: String, password: String, totpSecret: String?, rule: LoginRule) async throws
    func sendPracticeRequest(deviceID: String)
    func sendUnsentChanges() async throws
    func setPasswordCopyReminder(_ on: Bool)
    func setOpensAtLogin(_ on: Bool)
    func setAnonymousTelemetry(_ on: Bool)
    func syncWithICloudNow()
    func resetKeyring(includingICloud: Bool) async throws
    func approveAccessRequest(id: String) async throws
    func denyAccessRequest(id: String, reply: String?) async throws
    func approveEnrolment(id: String) async throws
    func denyEnrolment(id: String) async throws
}
#endif
