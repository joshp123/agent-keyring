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
        case ask, askOnIPhoneOrWatch, automatic, blocked
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

    public init(id: String, name: String, detail: String? = nil, role: Role, isThisIPhone: Bool = false) {
        self.id = id; self.name = name; self.detail = detail; self.role = role; self.isThisIPhone = isThisIPhone
    }
}

public enum PhoneTab: String, Hashable, Sendable {
    case activity, logins, devices
}

/// Where first run stands (Paper, "First run", "On iPhone"): one screen at a
/// time, ending in Done. Nil once he has tapped Done.
public enum PhoneFirstRun: Hashable, Sendable {
    /// Not joined yet. `macAsked`: the Mac has been asked to add this iPhone.
    /// `longWait`: nothing found for two minutes.
    case findingMac(macAsked: Bool, longWait: Bool)
    /// Joined; the screen before iOS's notification question.
    case notifications
    /// iOS's question was answered Don't Allow.
    case notificationsOff
    /// The practice request, as a sheet, while it waits.
    case practice
    /// The practice request was denied or ran out; he can send another.
    case practiceAgain
    /// Approved: "You're set up" and Done.
    case done
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

/// A rule change the Mac sent here, which only this iPhone may approve
/// (Paper, "Logins and rules"). The Watch never shows one.
public struct PhoneRuleProposal: Identifiable, Hashable, Sendable {
    public struct Change: Hashable, Sendable {
        public var site: String
        public var account: String
        public var from: PhoneLogin.Rule
        public var to: PhoneLogin.Rule
        public init(site: String, account: String, from: PhoneLogin.Rule, to: PhoneLogin.Rule) {
            self.site = site; self.account = account; self.from = from; self.to = to
        }
    }

    public let id: String
    /// The device that sent it, e.g. "MacBook Pro".
    public var from: String
    public var changes: [Change]
    public var askedAt: Date
    /// Waiting, approved, denied or no answer.
    public var state: AccessRequestState

    public init(id: String, from: String, changes: [Change], askedAt: Date, state: AccessRequestState) {
        self.id = id; self.from = from; self.changes = changes; self.askedAt = askedAt; self.state = state
    }
}

public struct PhoneSnapshot: Hashable, Sendable {
    public var requests: [AccessRequest]
    public var logins: [PhoneLogin]
    public var devices: [PhoneDevice]
    /// Nil once first run is finished.
    public var firstRun: PhoneFirstRun?
    /// First run's practice request, in the real request's layout, while it waits.
    public var practiceRequest: AccessRequest?
    public var notices: [PhoneNotice] = []
    public var settings = PhoneSettings()
    public var deviceRequest: PhoneDeviceRequest?
    /// Rule changes sent here, waiting and finished.
    public var ruleChanges: [PhoneRuleProposal] = []
    /// In the signed list of devices.
    public var joined = false

    public init(firstRun: PhoneFirstRun?, requests: [AccessRequest] = [], logins: [PhoneLogin] = [], devices: [PhoneDevice] = [],
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
    /// What iOS answered when asked about notifications.
    func notifications(allowed: Bool) async
    /// Sends the practice request again after it was denied or ran out.
    func sendTestAgain() async
    /// Done on "You're set up".
    func finishFirstRun() async
    func dismiss(_ notice: PhoneNotice) async
    func setSettings(_ settings: PhoneSettings) async
    /// A new device's request to approve requests: Face ID signs it in.
    func approveDevice(_ id: String) async throws
    func denyDevice(_ id: String) async
    /// A rule change the Mac sent: Face ID publishes the new rules.
    func approveRuleChange(_ id: String) async throws
    func denyRuleChange(_ id: String) async
}

@MainActor
@Observable
public final class PhoneModel {
    public private(set) var snapshot: PhoneSnapshot
    public var tab = PhoneTab.activity
    /// The request on screen, from a tap on a notification or on Show.
    public var shownRequestID: String? {
        didSet { if shownRequestID != nil { tab = .activity } }
    }
    public var replyDraft = ""
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

    public var waitingRuleChanges: [PhoneRuleProposal] {
        snapshot.ruleChanges.filter { $0.state.isWaitingForYou || $0.state.isSending }.sorted { $0.askedAt > $1.askedAt }
    }
    public var finishedRuleChanges: [PhoneRuleProposal] {
        snapshot.ruleChanges.filter { !$0.state.isWaitingForYou && !$0.state.isSending }
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
        guard settings.authorizationStatus != .notDetermined else { return }
        let allowed = settings.authorizationStatus == .authorized
        if snapshot.firstRun == .notificationsOff ? allowed : !allowed { await backend.notifications(allowed: allowed) }
    }

    /// iOS's own question, raised by Continue on the screen that says why.
    public func askAboutNotifications() async {
        let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await backend.notifications(allowed: allowed)
    }

    public func sendTestAgain() async { await backend.sendTestAgain() }
    public func finishFirstRun() async { await backend.finishFirstRun(); tab = .activity }
    public func dismiss(_ notice: PhoneNotice) async { await backend.dismiss(notice) }
    public func setSettings(_ settings: PhoneSettings) async { await backend.setSettings(settings) }

    public func approveDevice(_ id: String) async {
        await answer(.approve) { try await backend.approveDevice(id) }
    }

    public func denyDevice(_ id: String) async { await backend.denyDevice(id) }

    public func approveRuleChange(_ id: String) async { await answer(.approve) { try await backend.approveRuleChange(id) } }
    public func denyRuleChange(_ id: String) async {
        await backend.denyRuleChange(id)
        shownRequestID = nil
    }

    public func ruleChange(id: String) -> PhoneRuleProposal? { snapshot.ruleChanges.first { $0.id == id } }

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
