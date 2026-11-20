// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// What the iPhone app shows and what it can ask for. Views read the model;
// everything real (the relay, push, the Secure Enclave and Face ID) sits
// behind PhoneBackend.

import Foundation
import Observation
import UserNotifications

/// A saved login as the iPhone lists it. Site and account are readable;
/// the password stays sealed.
public struct PhoneLogin: Identifiable, Hashable, Sendable {
    public enum Rule: Hashable, Sendable {
        case ask, automatic, blocked
    }

    public let id: String
    public var site: String
    public var account: String
    public var rule: Rule

    public init(id: String, site: String, account: String, rule: Rule) {
        self.id = id; self.site = site; self.account = account; self.rule = rule
    }
}

public struct PhoneDevice: Identifiable, Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// A device that approves: this iPhone, a Watch, a MacBook.
        case approves
        /// A machine whose agents ask.
        case asks
    }

    public let id: String
    public var name: String
    /// How it approves, or what it does: "Face ID", "Always on. Passes requests…".
    public var detail: String?
    public var role: Role
    public var isThisIPhone: Bool
    /// Practice on its row: a device he answers on, other than this iPhone.
    public var canPractice: Bool
    /// Remove on its row: not this iPhone, and not a Mac's computer row (its device row removes both).
    public var canRemove: Bool

    public init(id: String, name: String, detail: String? = nil, role: Role, isThisIPhone: Bool = false,
                canPractice: Bool = false, canRemove: Bool = true) {
        self.id = id; self.name = name; self.detail = detail; self.role = role; self.isThisIPhone = isThisIPhone
        self.canPractice = canPractice; self.canRemove = canRemove
    }
}

public enum PhoneTab: String, Hashable, Sendable {
    case home, logins, devices
}

/// One sentence in Activity when something needs him, or an offer he can dismiss.
public enum PhoneNotice: Hashable, Sendable, Identifiable {
    /// Apple has not yet given this iPhone a push address.
    case stillConnecting
    /// The computer the relay runs on can't be reached; its name if known.
    case relayOffline(String?)
    /// An Apple Watch is paired and has not been added.
    case addAppleWatch

    public var id: String {
        switch self {
        case .stillConnecting: "stillConnecting"
        case .relayOffline: "relayOffline"
        case .addAppleWatch: "addAppleWatch"
        }
    }
    public var dismissable: Bool { self == .addAppleWatch }
}

public struct PhoneFill: Hashable, Sendable {
    public var copied: Int
    public var of: Int
    public init(copied: Int, of: Int) { self.copied = copied; self.of = of }
}

/// The one journey, as the Mac publishes it: the steps for the devices he chose, in order, the same on
/// every device, and where each device is on it. Read from the devices' signed status reports.
public struct PhoneJourney: Hashable, Sendable {
    public enum Step: String, Hashable, Sendable {
        case welcome, chooseDevices, practice, passwords, agents, alwaysOn, iPhone, watch, computers, tryDevices, ready
    }

    /// Where one device is.
    public struct Place: Hashable, Sendable {
        public var device: String
        public var step: Step?
        public var finished: Bool
        public init(device: String, step: Step?, finished: Bool) { self.device = device; self.step = step; self.finished = finished }
    }

    /// Empty until the Mac has published its list.
    public var steps: [Step] = []
    /// The Mac's place, and every other device's but this iPhone's.
    public var mac: Place?
    public var others: [Place] = []
    public init() {}
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
    public var notificationsAllowed = false
    /// Apple has given it a push address.
    public var pushAddress = false
    /// It has answered a practice request.
    public var practiceAnswered = false

    public init() {}

    /// Paired, with the app, and not yet added: first run offers the Apple Watch step.
    public var toAdd: Bool { paired && installed && !added }
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

    public init(_ settings: UNNotificationSettings) {
        allowed = settings.authorizationStatus == .authorized
        banners = settings.alertSetting == .enabled
        lockScreen = settings.lockScreenSetting == .enabled
        timeSensitive = settings.timeSensitiveSetting == .enabled
        inScheduledSummary = settings.scheduledDeliverySetting == .enabled
    }
}

/// The two notification settings (Paper, "On iPhone and Apple Watch", Settings).
public struct PhoneSettings: Hashable, Sendable {
    public var timeSensitive: Bool
    public var quietHours: Bool
    /// Minutes after midnight.
    public var quietFrom: Int
    public var quietTo: Int

    public init(timeSensitive: Bool = true, quietHours: Bool = false, quietFrom: Int = 23 * 60, quietTo: Int = 7 * 60) {
        self.timeSensitive = timeSensitive; self.quietHours = quietHours; self.quietFrom = quietFrom; self.quietTo = quietTo
    }
}

/// A device asking to approve requests, answered here like a login request.
public struct PhoneDeviceRequest: Identifiable, Hashable, Sendable {
    public let id: String
    /// "Apple Watch Ultra 3".
    public var name: String
    /// "Paired with this iPhone".
    public var detail: String

    public init(id: String, name: String, detail: String) { self.id = id; self.name = name; self.detail = detail }
}


public struct PhoneSnapshot: Hashable, Sendable {
    public var requests: [AccessRequest]
    public var logins: [PhoneLogin]
    public var devices: [PhoneDevice]
    public var firstRun: PhoneFirstRun
    /// First run's practice request, in the real request's layout, while it is open.
    public var practiceRequest: AccessRequest?
    /// The computer that stays on and passes requests to this iPhone, by name.
    public var relayName: String?
    /// What this iPhone can see of its Apple Watch, for the Apple Watch step.
    public var watch = PhoneWatchFacts()
    public var notices: [PhoneNotice] = []
    public var settings = PhoneSettings()
    public var notificationFacts = PhoneNotificationFacts()
    public var deviceRequest: PhoneDeviceRequest?
    public var journey = PhoneJourney()
    /// While this iPhone's copies of the passwords arrive after joining: how many are here, of how many.
    public var filling: PhoneFill?
    /// Requests whose answer is not delivered yet: the asking computer's door cannot be reached, and it is retried.
    public var undelivered: Set<String> = []
    /// In the signed list of devices.
    public var joined = false

    public init(firstRun: PhoneFirstRun, requests: [AccessRequest] = [], logins: [PhoneLogin] = [], devices: [PhoneDevice] = [],
                practiceRequest: AccessRequest? = nil, deviceRequest: PhoneDeviceRequest? = nil) {
        self.firstRun = firstRun; self.requests = requests; self.logins = logins; self.devices = devices
        self.practiceRequest = practiceRequest; self.deviceRequest = deviceRequest
    }
}

@MainActor
public protocol PhoneBackend: AnyObject {
    /// The current snapshot first, then one each time anything changes.
    func updates() -> AsyncStream<PhoneSnapshot>
    /// Face ID, then the answer goes to the machine that asked. `reusingUnlock`:
    /// a Face ID unlock of the phone in the last few seconds counts, so an
    /// Approve pressed on the Lock Screen needs one look, not two.
    func approve(_ requestID: String, reusingUnlock: Bool) async throws
    func deny(_ requestID: String, reply: String?) async throws
    func stop(_ requestID: String) async throws
    /// Changing a rule is signed by this iPhone after Face ID.
    func setRule(_ rule: PhoneLogin.Rule, forLogin loginID: String) async throws
    /// Removing a device is signed by this iPhone after Face ID.
    func remove(device deviceID: String) async throws
    /// Joins from the Mac's invitation (an `agentkeyring://join` link).
    func join(invitation: String) async throws
    /// A step of first run: a tap, or what iOS answered.
    func firstRun(_ event: PhoneFirstRun.Event) async
    /// What iOS now allows, read each time the app comes to the front and after its question.
    func notificationFacts(_ facts: PhoneNotificationFacts) async
    /// A practice request to this iPhone (nil) or to another device he answers on. For this iPhone, returns
    /// the one already waiting, to be shown again, instead of making a second.
    func sendPractice(to deviceID: String?) async -> String?
    func dismiss(_ notice: PhoneNotice) async
    func setSettings(_ settings: PhoneSettings) async
    /// A new device's request to approve requests: Face ID signs it in.
    func approveDevice(_ id: String) async throws
    func denyDevice(_ id: String) async
}

@MainActor
@Observable
public final class PhoneModel {
    public private(set) var snapshot: PhoneSnapshot
    public var tab = PhoneTab.home
    /// The request on screen, from a tap on a notification or on Show.
    public var shownRequestID: String? {
        didSet { if shownRequestID != nil { tab = .home } else { explaining = nil } }
    }
    public var replyDraft = ""
    /// The request was opened from Deny and Explain: its reply box takes the keyboard as it appears.
    public private(set) var explaining: String?

    public func explain(_ id: String) {
        explaining = id
        shownRequestID = id
    }
    public private(set) var answering: AnswerChoice?
    public private(set) var failure: String?

    private let backend: any PhoneBackend

    public init(backend: any PhoneBackend, initial: PhoneSnapshot) {
        self.backend = backend
        self.snapshot = initial
    }

    public func followUpdates() async {
        for await next in backend.updates() { snapshot = next }
    }

    public var waiting: [AccessRequest] { snapshot.requests.filter(\.state.isWaitingForYou).sorted { $0.askedAt > $1.askedAt } }
    public var inUse: [AccessRequest] { snapshot.requests.filter(\.state.isInUse).sorted { $0.askedAt > $1.askedAt } }
    public var finished: [AccessRequest] {
        snapshot.requests.filter { !$0.state.isWaitingForYou && !$0.state.isInUse && !$0.state.isSending }
            .sorted { $0.askedAt > $1.askedAt }
    }


    public func request(id: String) -> AccessRequest? { snapshot.requests.first { $0.id == id } }

    public func approve(_ id: String, reusingUnlock: Bool = false) async {
        await answer(.approve) { try await backend.approve(id, reusingUnlock: reusingUnlock) }
    }

    public func deny(_ id: String) async {
        let reply = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        await answer(.deny) { try await backend.deny(id, reply: reply.isEmpty ? nil : reply) }
    }

    public func stop(_ id: String) async {
        do { try await backend.stop(id) } catch {
            var until: Date?
            if case let .approved(_, end)? = request(id: id)?.state { until = end }
            failure = PhoneCopy.stopFailed(until: until)
        }
    }

    public func setRule(_ rule: PhoneLogin.Rule, forLogin id: String) async {
        do { try await backend.setRule(rule, forLogin: id) }
        catch is CancellationError {}
        catch { failure = PhoneCopy.changeFailed }
    }

    public func remove(device id: String) async {
        do { try await backend.remove(device: id) }
        catch is CancellationError {}
        catch { failure = PhoneCopy.changeFailed }
    }

    public func join(invitation: String) async {
        try? await backend.join(invitation: invitation)
    }

    /// What iOS now allows, read again each time the app comes to the front: he may
    /// have turned notifications on in Settings, and first run then carries on by itself.
    public func recheckNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await backend.notificationFacts(PhoneNotificationFacts(settings))
        guard settings.authorizationStatus != .notDetermined else { return }
        await backend.firstRun(.notificationsAnswered(allowed: settings.authorizationStatus == .authorized))
    }

    /// iOS's own question, raised by Continue on the screen that says why.
    public func askAboutNotifications() async {
        guard snapshot.firstRun == .notifications else { return }
        await backend.firstRun(.continueTapped)
        let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await backend.notificationFacts(PhoneNotificationFacts(await UNUserNotificationCenter.current().notificationSettings()))
        await backend.firstRun(.notificationsAnswered(allowed: allowed))
    }

    public func firstRun(_ event: PhoneFirstRun.Event) async {
        await backend.firstRun(event)
        if snapshot.firstRun == .finished { tab = .home }
    }

    public func sendPractice(to deviceID: String? = nil) async {
        if let waiting = await backend.sendPractice(to: deviceID) { shownRequestID = waiting }
    }
    public func dismiss(_ notice: PhoneNotice) async { await backend.dismiss(notice) }
    public func setSettings(_ settings: PhoneSettings) async { await backend.setSettings(settings) }

    public func approveDevice(_ id: String) async {
        await answer(.approve) { try await backend.approveDevice(id) }
    }

    public func denyDevice(_ id: String) async { await backend.denyDevice(id) }



    public func dismissFailure() { failure = nil }

    private func answer(_ choice: AnswerChoice, send: () async throws -> Void) async {
        guard answering == nil else { return }
        answering = choice
        defer { answering = nil }
        do {
            try await send()
            replyDraft = ""
            shownRequestID = nil
        } catch is CancellationError {
            // Face ID cancelled: the request stays on screen, unanswered.
        } catch {
            failure = PhoneCopy.answerFailed
        }
    }
}

extension AccessRequestState {
    var isSending: Bool {
        if case .sendingAnswer = self { return true }
        return false
    }
}
