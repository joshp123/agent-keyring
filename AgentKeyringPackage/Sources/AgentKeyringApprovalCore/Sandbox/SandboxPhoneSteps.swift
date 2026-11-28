// Written by AI on 2026.11.27 by model claude opus 5.5.
//
// The iPhone's first-run and Apple Watch pages by name, each a state of the
// real flows (PhoneFirstRun, PhoneAddWatch), for the gallery and for
// launching the app with -Sandbox YES -SandboxStep <name>.

import Foundation

extension SandboxState {
    /// Every first-run page worth seeing, in board order.
    public static let phoneFirstRunSteps = [
        "start", "welcome", "trouble", "found-mac", "approve-on-mac", "denied", "cant-reach", "expired", "receiving",
        "notifications", "notifications-checklist", "notifications-off", "practice-offer", "practice-waiting",
        "not-arrived", "mac-asleep", "setting-up", "approved", "denied-practice", "no-answer", "offer-watch", "no-watch",
        "standalone-offer-watch", "standalone-no-watch", "import-passwords",
    ]
    /// Every page of adding Apple Watch.
    public static let phoneWatchSteps = [
        "watch-not-paired", "watch-missing", "add-watch", "watch-waiting", "watch-expired", "watch-passcode",
        "watch-encrypting", "watch-failed", "watch-added",
    ]

    /// The world as the iPhone stands at `step`: a first-run or Apple Watch page, "mac-joining" (a Mac asking
    /// to join), "empty" (no requests) or "settled" (none waiting). Any other name leaves it as it is.
    public mutating func showPhone(step: String) {
        switch step {
        case "mac-joining":
            phone.deviceJoin = .asked(name: "MacBook Pro", isMac: true)
            return
        case "empty":
            requests = []
            return
        case "settled":
            for index in requests.indices where requests[index].request.state.isWaitingForYou {
                requests[index].request.state = .released(at: Self.fixedClock())
            }
            return
        default: break
        }
        let practiceID = AccessRequest.localPracticeID
        let stages: [String: PhoneFirstRun] = [
            "start": .start, "welcome": .welcome, "trouble": .trouble, "found-mac": .foundMac(name: "MacBook Pro"),
            "approve-on-mac": .waitingForMac(name: "MacBook Pro"), "denied": .deniedByMac(name: "MacBook Pro"),
            "cant-reach": .cantReachMac(name: "MacBook Pro"), "expired": .expired(name: "MacBook Pro"), "receiving": .receivingPasswords,
            "notifications": .notifications, "notifications-checklist": .notifications, "notifications-off": .notificationsOff,
            "mac-asleep": .practiceMacUnreachable(id: practiceID), "practice-waiting": .practiceWaiting(id: practiceID, arrived: false),
            "practice": .practice(id: practiceID), "not-arrived": .practiceNotArrived(id: practiceID),
            "setting-up": .settingUpNotifications(id: practiceID), "practice-offer": .practiceOffer,
            "approved": .practiceResult(.approved), "denied-practice": .practiceResult(.denied), "no-answer": .practiceResult(.noAnswer),
            "offer-watch": .readyOfferWatch(watchToAdd: true), "no-watch": .readyOfferWatch(watchToAdd: false),
            "standalone-offer-watch": .readyOfferWatch(watchToAdd: true), "standalone-no-watch": .readyOfferWatch(watchToAdd: false),
            "import-passwords": .importPasswords, "add-computer": .addComputer,
        ]
        let until = Calendar.current.date(bySettingHour: 14, minute: 17, second: 0, of: .now) ?? .now
        let total = max(logins.count, 548)
        let flows: [String: PhoneAddWatch] = [
            "watch-not-paired": .notPaired, "watch-missing": .watchAppMissing, "add-watch": .faceIDFirst,
            "watch-waiting": .waitingForWatch(until: until), "watch-expired": .faceIDExpired,
            "watch-passcode": .watchNeedsPasscode(until: until), "watch-encrypting": .encrypting(done: 312, total: total),
            "watch-failed": .copiesFailed(reason: PhoneCopy.watchNotReached), "watch-added": .added,
        ]
        guard flows[step] != nil || stages[step] != nil else { return }
        requests = []
        phone.notices = []
        phone.macName = "MacBook Pro"
        phone.watch.paired = true
        phone.watch.installed = true
        phone.watch.added = false
        phone.hasComputer = !step.hasPrefix("standalone-")
        phone.firstRun = flows[step] != nil ? .addWatch : stages[step] ?? .finished
        phone.addWatch = flows[step]
        phone.practiceRequest = phone.firstRun == .practice(id: practiceID) ? .practiceAccessRequest() : nil
        if step == "receiving" { phone.filling = PhoneFill(copied: 312, of: total) }
        if step == "notifications-checklist" {
            phone.notificationFacts.allowed = true
            phone.notificationFacts.banners = true
            phone.notificationFacts.lockScreen = true
        }
    }
}
