// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// Everything a sandbox world holds: the logins, devices, computers and
// requests both the Mac and the iPhone show, and where the iPhone's own flows
// stand. A real keyring's dump (AgentKeyringSealing/Sandbox, SandboxBundle) loads into
// the same values, with every password "hunter2". The built-in world is the
// one the galleries, PanelRender and the apps' -Sandbox launch run on.

import Foundation

/// The only secrets a sandbox ever holds.
public enum SandboxSecrets {
    public static let password = "hunter2"
    /// RFC 6238's test seed, as text.
    public static let totpSeed = "12345678901234567890"
}

public struct SandboxLogin: Identifiable, Hashable, Sendable {
    public let id: String
    public var site: String
    public var account: String
    public var rule: LoginRule
    public var category: ImportCategory
    public var asked: Int
    public var approved: Int
    public var denied: Int
    /// Its password was deleted when it was Blocked.
    public var secretDeleted: Bool
    /// The Mac's test password from first run.
    public var isTestPassword: Bool
    public var password: String
    public var totpSeed: String?

    public init(id: String, site: String, account: String, rule: LoginRule, category: ImportCategory = .other, asked: Int = 0,
                approved: Int = 0, denied: Int = 0, secretDeleted: Bool = false, isTestPassword: Bool = false,
                password: String = SandboxSecrets.password, totpSeed: String? = nil) {
        self.id = id; self.site = site; self.account = account; self.rule = rule; self.category = category
        self.asked = asked; self.approved = approved; self.denied = denied; self.secretDeleted = secretDeleted
        self.isTestPassword = isTestPassword; self.password = password; self.totpSeed = totpSeed
    }

    /// This device holds its password.
    public var holdsSecret: Bool { rule != .blocked && !secretDeleted }
}

/// A computer in the list, and the Mac device it is half of, if any.
public struct SandboxComputer: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var pairedDeviceID: String?
    public init(id: String, name: String, pairedDeviceID: String? = nil) { self.id = id; self.name = name; self.pairedDeviceID = pairedDeviceID }
}

public struct SandboxRequest: Identifiable, Hashable, Sendable {
    public var request: AccessRequest
    /// The login it asks for, when it is one in the world.
    public var loginID: String?
    public var id: String { request.id }
    public init(_ request: AccessRequest, loginID: String? = nil) { self.request = request; self.loginID = loginID }
}

/// What only the Mac shows: its own notices and settings.
public struct SandboxMacState: Hashable, Sendable {
    /// Only first run's test password is here.
    public var sampleOnly = false
    public var signedOutOfICloud = false
    public var noPushKey = false
    public var unsentChanges = 0
    public var copyChangedNothing = false
    public var copyIsStale = false
    public var remindsToUpdate: Bool?
    public var opensAtLogin: Bool?
    /// The daily version check may count this Mac: the world's own switch, never the real preference.
    public var anonymousTelemetry = true
    /// Touch ID can be used now: the lid is open and a finger is enrolled.
    public var canApprove = true
    public init() {}
}

public struct SandboxState: Hashable, Sendable {
    public var logins: [SandboxLogin]
    public var devices: [SignedListDevice]
    public var computers: [SandboxComputer]
    /// The device the world was dumped on, or the built-in iPhone.
    public var thisDeviceID: String
    public var requests: [SandboxRequest]
    public var enrolments: [DeviceEnrolment]
    public var importedAt: Date?
    public var readiness: [String: DeviceReadiness]
    public var practice: [String: DevicePracticeStatus]
    /// The iPhone's flows and settings. Its logins, devices and requests are always the world's.
    public var phone: PhoneSnapshot
    public var mac = SandboxMacState()

    public init(logins: [SandboxLogin], devices: [SignedListDevice], computers: [SandboxComputer], thisDeviceID: String,
                requests: [SandboxRequest] = [], enrolments: [DeviceEnrolment] = [], importedAt: Date? = nil,
                readiness: [String: DeviceReadiness] = [:], practice: [String: DevicePracticeStatus] = [:],
                phone: PhoneSnapshot = PhoneSnapshot(firstRun: .finished)) {
        self.logins = logins; self.devices = devices; self.computers = computers; self.thisDeviceID = thisDeviceID
        self.requests = requests; self.enrolments = enrolments; self.importedAt = importedAt
        self.readiness = readiness; self.practice = practice; self.phone = phone
    }

    /// The devices and computers as both screens list them.
    public var listed: DevicesSnapshot {
        DevicesSnapshot(devices: devices, computers: computers.map { .init(id: $0.id, name: $0.name) }, thisDeviceID: thisDeviceID) { id in
            Set(computers.filter { $0.pairedDeviceID == id }.map(\.id))
        }
    }

    /// The device of `kind` the screens of that kind run as: the dump's own if it is one, else the first.
    public func this(_ kind: SignedListDeviceKind) -> SignedListDevice? {
        devices.first { $0.id == thisDeviceID && $0.kind == kind } ?? devices.first { $0.kind == kind }
    }
}

extension SandboxState {
    /// 14:02 today, so every screen shows the same times.
    public static func fixedClock(_ now: Date = .now) -> Date {
        Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: now) ?? now
    }

    /// The galleries' world: six logins, an iPhone, an Apple Watch, a MacBook Pro whose agents also ask,
    /// two other computers, and five requests (one waiting).
    public static func builtIn(now: Date = .now) -> SandboxState {
        let clock = fixedClock(now)
        func ago(_ minutes: Double) -> Date { clock.addingTimeInterval(-minutes * 60) }
        let logins = [
            SandboxLogin(id: "6A0C6F1E-0000-4000-8000-000000000001", site: "github.com", account: "you@example.com", rule: .ask,
                         category: .codingCloud, asked: 41, approved: 38, denied: 3, totpSeed: SandboxSecrets.totpSeed),
            SandboxLogin(id: "6A0C6F1E-0000-4000-8000-000000000002", site: "cloudflare.com", account: "ops@example.com", rule: .ask,
                         category: .codingCloud, asked: 17, approved: 15, denied: 2),
            SandboxLogin(id: "6A0C6F1E-0000-4000-8000-000000000003", site: "example.com", account: "you@example.com", rule: .ask,
                         category: .emailWork, asked: 4, approved: 3, denied: 1, isTestPassword: true),
            SandboxLogin(id: "6A0C6F1E-0000-4000-8000-000000000004", site: "openai.com", account: "you@example.com", rule: .automatic,
                         category: .aiTools, asked: 12, approved: 12),
            SandboxLogin(id: "6A0C6F1E-0000-4000-8000-000000000005", site: "bank.example", account: "you@example.com", rule: .blocked,
                         category: .sensitive, secretDeleted: true),
            SandboxLogin(id: "6A0C6F1E-0000-4000-8000-000000000006", site: "shop.example", account: "orders@example.com", rule: .ask,
                         category: .shopping, asked: 1, denied: 1, secretDeleted: true),
        ]
        let devices: [SignedListDevice] = [
            .init(id: "iphone", name: "iPhone", kind: .iPhone),
            .init(id: "watch", name: "Apple Watch", kind: .watch),
            .init(id: "macbook", name: "MacBook Pro", kind: .mac),
        ]
        let computers = [
            SandboxComputer(id: "macbook-agents", name: "MacBook Pro", pairedDeviceID: "macbook"),
            SandboxComputer(id: "mini", name: "Mac mini"),
            SandboxComputer(id: "linux", name: "Linux server"),
        ]
        let codex = RequestingAgent(name: "Codex", machine: "Mac mini", address: "", project: "bookkeeping")
        let claude = RequestingAgent(name: "Claude Code", machine: "MacBook Pro", address: "")
        let requests = [
            SandboxRequest(AccessRequest(id: "r1", login: RequestedLogin(site: "example.com", account: "you@example.com"), agent: codex,
                access: .login, agentReason: "You asked me to download October’s invoice.", askedAt: ago(2),
                state: .waitingForYou(until: clock.addingTimeInterval(600))), loginID: logins[2].id),
            SandboxRequest(AccessRequest(id: "r2", login: RequestedLogin(site: "github.com", account: "you@example.com"), agent: claude,
                access: .login, agentReason: "Checking pull request status for release 1.1.", askedAt: ago(12),
                state: .released(at: ago(9))), loginID: logins[0].id),
            SandboxRequest(AccessRequest(id: "r3", login: RequestedLogin(site: "forum.example", account: "you@example.com"), agent: codex,
                access: .login, agentReason: "Posting the release notes.", askedAt: ago(28),
                state: .denied(by: .iPhone, reply: "Wait until I review the changelog first.", askAgainAfter: nil))),
            SandboxRequest(AccessRequest(id: "r4", login: RequestedLogin(site: "openai.com", account: "you@example.com"), agent: codex,
                access: .login, agentReason: "Checking API usage balance.", askedAt: ago(45),
                state: .released(at: ago(44)), byAutomaticRule: true), loginID: logins[3].id),
            SandboxRequest(AccessRequest(id: "r5", login: RequestedLogin(site: "shop.example", account: "orders@example.com"), agent: claude,
                access: .login, agentReason: "Reordering coffee filters.", askedAt: ago(65),
                state: .expired(at: ago(35))), loginID: logins[5].id),
        ]
        var phone = PhoneSnapshot(firstRun: .finished)
        phone.joined = true
        phone.hasComputer = true
        phone.macName = "MacBook Pro"
        phone.watch.paired = true
        phone.watch.installed = true
        phone.watch.added = true
        phone.passwordsCopy.copiedAt = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 11, day: 20))
        return SandboxState(logins: logins, devices: devices, computers: computers, thisDeviceID: "iphone", requests: requests,
                            importedAt: phone.passwordsCopy.copiedAt, phone: phone)
    }
}
