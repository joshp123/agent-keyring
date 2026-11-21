// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// Paper's made-up requests, logins and devices, held in memory. The app
// runs on it in the simulator (launch argument -sample) to compare its
// screens with Paper's boards. Nothing in it reaches a computer or a login.

import Foundation

@MainActor
public final class PhoneSampleBackend: PhoneBackend {
    private var snapshot: PhoneSnapshot {
        didSet { for continuation in subscribers.values { continuation.yield(snapshot) } }
    }
    private var subscribers: [UUID: AsyncStream<PhoneSnapshot>.Continuation] = [:]

    /// `step` is one of the first-run iPhone screens: start, trouble, found-mac, approve-on-mac, denied, cant-reach, expired,
    /// receiving, notifications, notifications-off, practice-offer, practice-waiting, practice, not-arrived, mac-asleep,
    /// setting-up, approved, denied-practice, offer-watch, add-watch (the Apple Watch flow), or empty (Home with nothing);
    /// nil is the app in use.
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
        if requestID == snapshot.practiceRequest?.id { await firstRun(.practiceEnded(.approved)); return }
        update(requestID) { .approved(by: .iPhone, until: .now.addingTimeInterval(RequestedAccess.longestLease)) }
    }

    public func deny(_ requestID: String, reply: String?) async throws {
        if requestID == snapshot.practiceRequest?.id { await firstRun(.practiceEnded(.denied)); return }
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
    public func sendPractice(to deviceID: String?) async -> String? { nil }
    public func notificationFacts(_ facts: PhoneNotificationFacts) async { snapshot.notificationFacts = facts }
    public func dismiss(_ notice: PhoneNotice) async { snapshot.notices.removeAll { $0 == notice } }
    public func setSettings(_ settings: PhoneSettings) async { snapshot.settings = settings }
    public func addWatch(_ tap: PhoneAddWatchTap) async {
        let flow = snapshot.addWatch ?? .faceIDFirst
        let next: PhoneAddWatch = switch tap {
        case .open: .faceIDFirst
        case .continueWithFaceID: flow.on(.confirmed(until: .now.addingTimeInterval(PhoneAddWatch.hold)))
        case .checkAgain: flow.on(.checked(paired: true, installed: true))
        case .tryAgain: flow.on(.tryAgain(now: .now))
        case .cancel: .closed
        case .done: flow.on(.done)
        }
        snapshot.addWatch = next == .closed ? nil : next
        if next == .closed, snapshot.firstRun == .addWatch { await firstRun(.done) }
    }

    static func practiceOpen(_ stage: PhoneFirstRun) -> Bool { stage == .practice(id: "practice") }

    /// Paper's first-run iPhone screens.
    static func firstRun(_ step: String, into snapshot: inout PhoneSnapshot) {
        snapshot.requests = []; snapshot.notices = []
        snapshot.macName = "MacBook Pro"; snapshot.watch.paired = true; snapshot.watch.installed = true
        let stages: [String: PhoneFirstRun] = [
            "start": .start, "trouble": .trouble, "found-mac": .foundMac(name: "MacBook Pro"),
            "approve-on-mac": .waitingForMac(name: "MacBook Pro"), "denied": .deniedByMac(name: "MacBook Pro"),
            "cant-reach": .cantReachMac(name: "MacBook Pro"), "expired": .expired(name: "MacBook Pro"), "receiving": .receivingPasswords,
            "notifications": .notifications, "notifications-off": .notificationsOff, "mac-asleep": .practiceMacUnreachable(id: "practice"),
            "practice-waiting": .practiceWaiting(id: "practice", arrived: false), "practice": .practice(id: "practice"),
            "not-arrived": .practiceNotArrived(id: "practice"), "setting-up": .settingUpNotifications(id: "practice"), "practice-offer": .practiceOffer,
            "approved": .practiceResult(.approved), "denied-practice": .practiceResult(.denied),
            "offer-watch": .readyOfferWatch(watchToAdd: true), "no-watch": .readyOfferWatch(watchToAdd: false),
            "no-answer": .practiceResult(.noAnswer),
        ]
        let until = Calendar.current.date(bySettingHour: 14, minute: 17, second: 0, of: .now) ?? .now
        let flows: [String: PhoneAddWatch] = [
            "watch-not-paired": .notPaired, "watch-missing": .watchAppMissing, "add-watch": .faceIDFirst,
            "watch-waiting": .waitingForWatch(until: until), "watch-expired": .faceIDExpired,
            "watch-passcode": .watchNeedsPasscode(until: until), "watch-encrypting": .encrypting(done: 312, total: 547),
            "watch-failed": .copiesFailed(reason: "Your Mac couldn’t be reached"), "watch-added": .added,
        ]
        snapshot.firstRun = flows[step] != nil ? .addWatch : stages[step] ?? .finished
        snapshot.addWatch = flows[step]
        snapshot.practiceRequest = practiceOpen(snapshot.firstRun) ? .practice() : nil
        if step == "receiving" { snapshot.filling = PhoneFill(copied: 312, of: 547) }
        if step == "notifications-checklist" {
            snapshot.firstRun = .notifications
            snapshot.notificationFacts.allowed = true; snapshot.notificationFacts.banners = true; snapshot.notificationFacts.lockScreen = true
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
            PhoneDevice(id: "d5", name: "Mac mini", role: .asks),
            PhoneDevice(id: "d6", name: "Linux server", role: .asks),
        ]
        return PhoneSnapshot(firstRun: .finished, requests: requests, logins: logins, devices: devices)
    }
}
