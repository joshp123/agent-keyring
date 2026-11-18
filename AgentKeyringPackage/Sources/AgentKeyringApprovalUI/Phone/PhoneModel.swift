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

/// One line of first run's self-ticking list (Paper, "First run").
public struct PhoneSetupLine: Identifiable, Hashable, Sendable {
    public enum Mark: Hashable, Sendable {
        /// A tick.
        case done
        /// A dark ring: working, or waiting for him.
        case working
        /// A pale ring: not yet.
        case notYet
        /// A red mark, with one sentence in the detail.
        case failed
    }

    public let id: String
    public var mark: Mark
    public var title: String
    public var detail: String?
    /// The line's one button opens Agent Keyring's notification settings.
    public var opensSettings: Bool

    public init(id: String, mark: Mark, title: String, detail: String? = nil, opensSettings: Bool = false) {
        self.id = id; self.mark = mark; self.title = title; self.detail = detail; self.opensSettings = opensSettings
    }
}

public struct PhoneSetup: Hashable, Sendable {
    public var lines: [PhoneSetupLine]
    /// Joined, notifications on, requests reach it, and the test approved.
    public var isReady: Bool

    public init(lines: [PhoneSetupLine], isReady: Bool) { self.lines = lines; self.isReady = isReady }
    public static let ready = PhoneSetup(lines: [], isReady: true)
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
    public var setup: PhoneSetup
    public var requests: [AccessRequest]
    public var logins: [PhoneLogin]
    public var devices: [PhoneDevice]
    /// First run's test request, while it waits for Face ID.
    public var testRequest: String?
    public var deviceRequest: PhoneDeviceRequest?
    /// In the signed list of devices.
    public var joined = false
    /// Joined, and iOS has not yet been asked about notifications.
    public var asksAboutNotifications = false

    public init(setup: PhoneSetup, requests: [AccessRequest] = [], logins: [PhoneLogin] = [], devices: [PhoneDevice] = [],
                testRequest: String? = nil, deviceRequest: PhoneDeviceRequest? = nil) {
        self.setup = setup; self.requests = requests; self.logins = logins; self.devices = devices
        self.testRequest = testRequest; self.deviceRequest = deviceRequest
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
    /// First run's test request: Face ID proves the chip and the round trip.
    func approveTest() async throws
    /// A new device's request to approve requests: Face ID signs it in.
    func approveDevice(_ id: String) async throws
    func denyDevice(_ id: String) async
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

    /// iOS's own question, asked once, straight after joining.
    public func askAboutNotifications() async {
        let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await backend.notifications(allowed: allowed)
    }

    public func approveTest() async {
        await answer(.approve) { try await backend.approveTest() }
    }

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
