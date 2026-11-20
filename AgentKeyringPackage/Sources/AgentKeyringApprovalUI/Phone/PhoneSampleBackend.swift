// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// Paper's made-up requests, logins and devices, held in memory. The app
// runs on it in the simulator (launch argument -sample) to compare its
// screens with Paper's boards. Nothing in it reaches a relay or a login.

import Foundation

@MainActor
public final class PhoneSampleBackend: PhoneBackend {
    private var snapshot: PhoneSnapshot {
        didSet { for continuation in subscribers.values { continuation.yield(snapshot) } }
    }
    private var subscribers: [UUID: AsyncStream<PhoneSnapshot>.Continuation] = [:]

    /// `step` is one of Paper's first-run iPhone screens: start, long-wait, add-computer, approve-on-mac, denied,
    /// notifications, notifications-off, practice-offer, practice-waiting, practice, not-arrived, setting-up, approved,
    /// denied-practice, add-watch-step, empty (Home with nothing), or add-watch (the request to add it); nil is the app in use.
    public init(step: String? = nil, now: Date = .now) {
        snapshot = Self.paper(now: now)
        if let step { Self.firstRun(step, into: &snapshot) }
    }

    public var current: PhoneSnapshot { snapshot }

    public func updates() -> AsyncStream<PhoneSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers.removeValue(forKey: id) } }
        }
    }

    public func approve(_ requestID: String, reusingUnlock: Bool) async throws {
        if requestID == snapshot.practiceRequest?.id { await firstRun(snapshot.firstRun == .practice ? .practiceEnded(.approved) : .closePractice); return }
        update(requestID) { .approved(by: .iPhone, until: .now.addingTimeInterval(RequestedAccess.longestLease)) }
    }

    public func deny(_ requestID: String, reply: String?) async throws {
        if requestID == snapshot.practiceRequest?.id { await firstRun(snapshot.firstRun == .practice ? .practiceEnded(.denied) : .closePractice); return }
        update(requestID) { .denied(by: .iPhone, reply: reply, askAgainAfter: .now.addingTimeInterval(1800)) }
    }

    public func stop(_ requestID: String) async throws { update(requestID) { .ended(at: .now) } }

    public func setRule(_ rule: PhoneLogin.Rule, forLogin loginID: String) async throws {
        guard let index = snapshot.logins.firstIndex(where: { $0.id == loginID }) else { return }
        snapshot.logins[index].rule = rule
    }

    public func remove(device deviceID: String) async throws {
        snapshot.devices.removeAll { $0.id == deviceID }
    }

    public func join(invitation: String) async throws {}
    public func firstRun(_ event: PhoneFirstRun.Event) async {
        var next = snapshot
        next.firstRun = snapshot.firstRun.on(event)
        next.practiceRequest = Self.practiceOpen(next.firstRun) ? .practice() : nil
        snapshot = next
    }
    public func sendPractice(to deviceID: String?) async {}
    public func dismiss(_ notice: PhoneNotice) async { snapshot.notices.removeAll { $0 == notice } }
    public func setSettings(_ settings: PhoneSettings) async { snapshot.settings = settings }
    public func approveDevice(_ id: String) async throws { snapshot.deviceRequest = nil }
    public func denyDevice(_ id: String) async { snapshot.deviceRequest = nil }

    static func practiceOpen(_ stage: PhoneFirstRun) -> Bool {
        if case .welcome(_, true) = stage { return true }
        return stage == .practice
    }

    /// Paper's first-run iPhone screens.
    static func firstRun(_ step: String, into snapshot: inout PhoneSnapshot) {
        snapshot.requests = []; snapshot.deviceRequest = nil; snapshot.notices = []
        snapshot.relayName = "Mac mini"; snapshot.watchPaired = true
        let stages: [String: PhoneFirstRun] = [
            "start": .start, "long-wait": .welcome(.startOnMac(longWait: true), practising: false),
            "add-computer": .welcome(.addComputer(mac: "MacBook Pro"), practising: false),
            "approve-on-mac": .welcome(.approveOnMac(mac: "MacBook Pro"), practising: false),
            "denied": .welcome(.denied(mac: "MacBook Pro"), practising: false),
            "notifications": .notifications, "notifications-off": .notificationsOff,
            "practice-waiting": .practiceWaiting(arrived: false), "practice": .practice,
            "not-arrived": .practiceNotArrived, "setting-up": .settingUpNotifications, "practice-offer": .practiceOffer,
            "approved": .practiceResult(.approved), "denied-practice": .practiceResult(.denied), "add-watch-step": .addWatch,
        ]
        snapshot.firstRun = stages[step] ?? .finished
        snapshot.practiceRequest = practiceOpen(snapshot.firstRun) ? .practice() : nil
        if step == "add-watch" {
            snapshot.deviceRequest = PhoneDeviceRequest(id: "watch", name: "Apple Watch Ultra 3", detail: PhoneCopy.pairedWithThisIPhone)
        } else if stages[step] == nil {
            snapshot.notices = [.addAppleWatch]
        }
    }

    private func update(_ id: String, to state: () -> AccessRequestState) {
        guard let index = snapshot.requests.firstIndex(where: { $0.id == id }) else { return }
        snapshot.requests[index].state = state()
    }

    /// The board "On the iPhone and Watch", at 14:02 today.
    static func paper(now: Date) -> PhoneSnapshot {
        let calendar = Calendar.current
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        }
        let codexMini = RequestingAgent(name: "Codex", machine: "Mac mini", address: "", project: "bookkeeping")
        let claudeMac = RequestingAgent(name: "Claude Code", machine: "MacBook Pro", address: "")
        let codexLinux = RequestingAgent(name: "Codex", machine: "Linux server", address: "")
        let requests = [
            AccessRequest(id: "r1", login: RequestedLogin(site: "example.com", account: "josh@example.com"), agent: codexMini,
                          access: .login, agentReason: "You asked me to download October’s invoice.", askedAt: at(14, 2),
                          state: .waitingForYou(until: now.addingTimeInterval(600))),
            AccessRequest(id: "r2", login: RequestedLogin(site: "example.org", account: "josh@example.org"), agent: claudeMac,
                          access: .login, agentReason: "Checking the order status you asked about.", askedAt: at(14, 0),
                          state: .approved(by: .mac, until: at(14, 32))),
            AccessRequest(id: "r3", login: RequestedLogin(site: "shop.example", account: "josh@example.com"), agent: claudeMac,
                          access: .login, agentReason: "Reordering coffee filters.", askedAt: at(13, 40),
                          state: .expired(at: at(14, 10))),
            AccessRequest(id: "r4", login: RequestedLogin(site: "forum.example", account: "josh"), agent: codexLinux,
                          access: .login, agentReason: "Posting the release notes.", askedAt: at(13, 12),
                          state: .denied(by: .iPhone, reply: nil, askAgainAfter: nil)),
            AccessRequest(id: "r5", login: RequestedLogin(site: "example.com", account: "josh@example.com"),
                          agent: RequestingAgent(name: "Codex", machine: "Mac mini", address: ""),
                          access: .login, agentReason: "Downloading statements.", askedAt: at(11, 5), state: .unanswered),
        ]
        let logins = [
            PhoneLogin(id: "l1", site: "example.com", account: "josh@example.com", rule: .ask),
            PhoneLogin(id: "l2", site: "news.example", account: "josh@example.com", rule: .ask),
            PhoneLogin(id: "l3", site: "example.org", account: "josh@example.org", rule: .ask),
            PhoneLogin(id: "l4", site: "bank.example", account: "josh@example.com", rule: .ask),
            PhoneLogin(id: "l5", site: "mail.example", account: "josh@example.com", rule: .ask),
            PhoneLogin(id: "l6", site: "forum.example", account: "josh", rule: .automatic),
            PhoneLogin(id: "l7", site: "shop.example", account: "josh@example.com", rule: .ask),
        ]
        let devices = [
            PhoneDevice(id: "d1", name: "iPhone", detail: PhoneCopy.answersWithFaceID, role: .approves, isThisIPhone: true, canRemove: false),
            PhoneDevice(id: "d2", name: "Apple Watch", detail: PhoneCopy.answersWithTap, role: .approves, canPractice: true),
            PhoneDevice(id: "d3", name: "MacBook Pro", detail: PhoneCopy.answersWithTouchID, role: .approves, canPractice: true),
            PhoneDevice(id: "d4", name: "MacBook Pro", role: .asks, canRemove: false),
            PhoneDevice(id: "d5", name: "Mac mini", detail: PhoneCopy.passesRequests, role: .asks),
            PhoneDevice(id: "d6", name: "Linux server", role: .asks),
        ]
        return PhoneSnapshot(firstRun: .finished, requests: requests, logins: logins, devices: devices)
    }
}
