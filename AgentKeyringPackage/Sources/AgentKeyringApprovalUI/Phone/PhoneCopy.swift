// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// Every word the iPhone app and its notifications show, from Paper's pages
// "The request" and "First run and the app". Words Paper does not have are
// marked; they go back to the designer.

import Foundation

public enum PhoneCopy {
    // The request, in the app and in the held notification.
    public static let appName = "Agent Keyring"
    public static func wants(_ agent: RequestingAgent) -> String { agent.machine.isEmpty ? "\(agent.name) wants" : "\(agent.name) on \(agent.machine) wants" }
    public static func quoted(_ reason: String) -> String { "“\(reason)”" }
    public static func replyPlaceholder(_ agent: RequestingAgent) -> String { "What should \(agent.name) do instead?" }
    /// Not in Paper: when the agent's name is too long for the box beside Deny.
    public static let replyPlaceholderShort = "What should it do instead?"
    public static let deny = "Deny"
    public static let approveWithFaceID = "Approve with Face ID"
    public static func lasts(_ agent: RequestingAgent) -> String {
        "\(agent.name) can use this password for this task, 30 minutes at most."
    }

    /// "Project bookkeeping", "Folder Downloads", or nothing.
    public static func scope(_ agent: RequestingAgent) -> (label: String, name: String)? {
        if let project = agent.project, !project.isEmpty { return ("Project", project) }
        if let folder = agent.folder, !folder.isEmpty { return ("Folder", folder) }
        return nil
    }

    // The notification on the Lock Screen.
    public static func notificationTitle(_ request: AccessRequest) -> String { request.login.site }
    public static func notificationSubtitle(_ agent: RequestingAgent) -> String { "\(agent.name) on \(agent.machine) wants this password" }
    public static func notificationBody(_ request: AccessRequest) -> String {
        let reason = quoted(request.agentReason)
        if let project = request.agent.project, !project.isEmpty {
            return "\(request.login.account), for the \(project) project: \(reason)"
        }
        // Not in Paper: a request from outside any project.
        return "\(request.login.account): \(reason)"
    }
    /// The push that replaces a request on the Lock Screen once it has ended (Paper, "Wherever you are").
    /// `device` is the answering device's own name, e.g. "Watch".
    public static func outcomeBody(_ request: AccessRequest, answeredBy device: String?) -> String {
        let on = device.map { " on your \($0)" } ?? ""
        switch request.state {
        case let .approved(_, until): return "Approved\(on). \(request.agent.name) can use this password until \(clock(until)) at the latest."
        case let .denied(_, reply?, _): return "Denied\(on). You told \(request.agent.name): \(quoted(reply))"
        case .denied: return "Denied\(on)."
        case .unanswered: return "No answer. The request ended after 10 minutes, and \(request.agent.name) can ask again."
        case .cancelled: return "Cancelled. \(request.agent.name) stopped asking before you answered."
        default: return "This request has ended."
        }
    }

    /// Shown if the request's words cannot be opened in time.
    public static let notificationFallbackTitle = "An agent wants to use a password."
    public static let notificationFallbackBody = "Open Agent Keyring to see the request."

    // The buttons iOS draws under a held notification.
    public static let approve = "Approve"
    public static let denyAndExplain = "Deny and Explain"
    /// The category is fixed, so it cannot name the agent.
    public static let explainPlaceholder = replyPlaceholderShort

    // Activity.
    public static let activity = "Activity"
    public static let waitingForYou = "Waiting for you"
    /// Not in Paper.
    public static let nothingWaiting = "Nothing waiting"
    public static let inUse = "In use"
    public static let show = "Show"
    public static let stop = "Stop"
    public static func waitingDetail(_ agent: RequestingAgent) -> String {
        [ "\(agent.name) on \(agent.machine)", agent.project ].compactMap { $0 }.joined(separator: " · ")
    }
    public static func inUseDetail(_ agent: RequestingAgent, until: Date) -> String {
        "\(agent.name) on \(agent.machine) · until \(clock(until))"
    }
    public static func historyDetail(_ request: AccessRequest) -> String {
        "\(clock(request.askedAt)) · \(request.agent.name) on \(request.agent.machine)"
    }
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Earlier today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
    public enum Outcome { case approved, denied, noAnswer }
    public static func outcome(_ state: AccessRequestState) -> (Outcome, String) {
        switch state {
        case .approved(by: .automaticRule, _): (.approved, "Automatic")
        case .approved, .expired, .released, .ended: (.approved, "Approved")
        case .blockedByRule: (.denied, "Blocked")
        case .denied: (.denied, "Denied")
        case .unanswered: (.noAnswer, "No answer")
        case .cancelled, .waitingForYou, .sendingAnswer, .waitingForMac: (.noAnswer, "Cancelled")
        }
    }

    // Passwords.
    public static let passwords = "Passwords"
    public static let search = "Search"
    /// The Passwords list row, where the full name would wrap.
    public static let ruleShortPhoneOrWatch = "iPhone or Apple Watch"
    public static func rule(_ rule: PhoneLogin.Rule) -> String {
        switch rule {
        case .ask: "Ask"
        case .askOnIPhoneOrWatch: "Ask on iPhone or Apple Watch"
        case .automatic: "Automatic"
        case .blocked: "Blocked"
        }
    }

    /// Face ID's sentence when a password becomes Automatic (Paper, "Passwords and rules", in the Mac's words).
    public static func automaticReason(site: String, from: PhoneLogin.Rule, computers: [String]) -> String {
        "\(site) changes from \(rule(from)) to Automatic. Agents on \(list(computers)) will get it without asking."
    }
    /// "A", "A and B", "A, B and C".
    public static func list(_ names: [String]) -> String {
        names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // Devices.
    public static let devices = "Devices"
    public static let youApproveOn = "You approve on"
    public static let agentsAskFrom = "Agents ask from"
    public static let thisIPhone = "This iPhone"
    public static let faceID = "Face ID"
    public static let remove = "Remove"
    public static let cancel = "Cancel"

    // First run (Paper, "First run", "On iPhone"; first-run-v2.md).
    public static let appLead = "Approve or deny your agents’ requests from this iPhone."
    public static let approveOnMac = "Approve on your Mac"
    public static let approveOnMacDetail = "A request to add this iPhone is waiting there."
    public static let finishOnMac = "Finish on your Mac first"
    public static let finishOnMacDetail = "Set up Agent Keyring on your Mac, then ask an agent there to add your iPhone. This iPhone connects by itself."
    /// After two minutes with nothing found.
    public static let finishOnMacLongWait = "Already done? Check that iCloud Keychain is on for this iPhone and your Mac."
    public static let notificationsTitle = "Get requests when your iPhone is locked"
    public static let notificationsLead = "Agent Keyring sends a notification each time an agent asks for a password."
    public static let continueButton = "Continue"
    public static let notificationsOff = "Turn on notifications so requests appear on your Lock Screen and Apple Watch."
    public static let openSettings = "Open Settings"
    // The practice request: the real request's layout.
    public static let practice = "Practice"
    public static let practiceAgent = "Agent Keyring"
    public static let practiceMachine = ""
    public static let practiceSite = "example.com"
    public static let practiceAccount = "you@example.com"
    public static let practiceReason = "This is a practice request. No real password is used."
    public static let practiceLasts = "An approval lasts for one task, 30 minutes at most."
    /// Not drawn for the iPhone: the Mac's words for a practice request denied or left.
    public static let practiceAgainTitle = "Try a practice request"
    public static let practiceAgainDetail = "Approve one to finish setting up."
    public static let sendAnother = "Send Another"
    public static let setUpTitle = "You’re set up"
    public static let setUpLead = "Requests arrive as notifications. Tap one to open it, or touch and hold to approve or deny."
    public static let done = "Done"
    // Activity after first run.
    public static let noRequestsYet = "No requests yet"
    public static let noRequestsDetail = "When an agent asks for a password, the request appears here."
    public static let addAppleWatch = "Add Apple Watch"
    public static let addAppleWatchDetail = "Open Agent Keyring on your Apple Watch to approve from your wrist."
    public static let stillConnecting = "This iPhone is still connecting. Until it finishes, requests appear only while Agent Keyring is open."
    public static func relayOffline(_ name: String?) -> String {
        // Paper names the computer (Members.relay_machine_id); the words without a name are for a relay that names none.
        "\(name ?? "The computer that passes on your requests") is offline. Check that it is turned on and connected."
    }
    public static func notice(_ notice: PhoneNotice) -> String {
        switch notice {
        case .stillConnecting: stillConnecting
        case let .relayOffline(name): relayOffline(name)
        case .addAppleWatch: addAppleWatchDetail
        }
    }
    public static let close = "Close"
    // Settings (Paper, "On iPhone and Apple Watch", iPhone, Settings).
    public static let settings = "Settings"
    public static let timeSensitive = "Time Sensitive Notifications"
    public static let timeSensitiveDetail = "Requests can break through a Focus, such as Sleep, while an agent is waiting."
    public static let quietHours = "Quiet Hours"
    public static let from = "From"
    public static let to = "To"
    public static let quietHoursDetail = "During quiet hours, requests don’t break through a Focus."
    public static let watchFollows = "Apple Watch follows these settings."
    // Apple Watch's request to be added (Paper, "On Apple Watch").
    public static let addWatchLead = "Add to Agent Keyring"
    public static let pairedWithThisIPhone = "Paired with this iPhone"
    public static let watchFootnote = "It approves requests with one tap while unlocked on your wrist. Remove it in Devices."
    // A rule change the Mac sent (Paper, "Logins and rules").
    public static func ruleChangeLead(_ c: PhoneRuleProposal) -> String {
        c.changes.count == 1 ? "\(c.from) wants to change the rule for" : "\(c.from) wants to change the rules for"
    }
    public static func ruleChangeTitle(_ c: PhoneRuleProposal) -> String {
        c.changes.count == 1 ? c.changes[0].site : "\(c.changes.count) passwords"
    }
    /// The account under the site; none for several logins.
    public static func ruleChangeAccount(_ c: PhoneRuleProposal) -> String? { c.changes.count == 1 ? c.changes[0].account : nil }
    /// The lines under the title: the change first, then what it would allow.
    public static func ruleChangeLines(_ c: PhoneRuleProposal) -> (change: [String], allows: String) {
        guard let first = c.changes.first else { return ([], "") }
        if c.changes.count == 1 {
            return (["From \(rule(first.from)) to \(rule(first.to))"], allows(first.to, from: c.from))
        }
        return (["From \(rule(first.from)):"] + c.changes.map { "\($0.site) to \(rule($0.to))" },
                "\(c.from) could then change them again with Touch ID.")
    }
    static func allows(_ to: PhoneLogin.Rule, from device: String) -> String {
        switch to {
        case .ask: "\(device) could then approve requests for this password with Touch ID."
        case .automatic: "Agents could then get this password without asking."
        case .blocked: "No agent could then use this password, and \(device) could change its rule again with Touch ID."
        case .askOnIPhoneOrWatch: ""
        }
    }
    public static func ruleChangeFootnote(_ c: PhoneRuleProposal) -> String { "Deny it if you did not make this change on \(c.from)." }
    public static func ruleChangeNotificationTitle(_ c: PhoneRuleProposal) -> String {
        c.changes.count == 1 ? "\(c.from) wants to change a rule" : "\(c.from) wants to change \(c.changes.count) rules"
    }
    public static func ruleChangeNotificationBody(_ c: PhoneRuleProposal) -> String {
        guard let first = c.changes.first else { return "" }
        switch c.changes.count {
        case 1: return "\(first.site), from \(rule(first.from)) to \(rule(first.to))."
        case 2: return "\(first.site) and \(c.changes[1].site), from \(rule(first.from))."
        default: return "\(first.site) and \(c.changes.count - 1) more, from \(rule(first.from))."
        }
    }
    /// Not in Paper for several logins with different new rules: the first one's rule is named.
    private static func ruleChangeTo(_ c: PhoneRuleProposal) -> String { c.changes.first.map { rule($0.to) } ?? "" }
    public static func ruleChangeWaitingDetail(_ c: PhoneRuleProposal) -> String { "\(c.from) · rule change to \(ruleChangeTo(c))" }
    public static func ruleChangeHistoryDetail(_ c: PhoneRuleProposal) -> String { "\(clock(c.askedAt)) · Rule change to \(ruleChangeTo(c))" }

    // Failures.
    public static let answerFailed = "Your answer wasn’t sent. Try again."
    public static func stopFailed(until: Date?) -> String {
        "Couldn’t stop it. Try again." + (until.map { " It ends by itself at \(clock($0))." } ?? "")
    }
    public static let changeFailed = "That change wasn’t saved. Try again."
    public static let ok = "OK"
    public static func removeQuestion(_ name: String) -> String { "Remove \(name)?" }
    /// `alsoAsks`: a Mac both approves and has agents that ask; one Remove takes both.
    public static func removeDetail(_ device: PhoneDevice, alsoAsks: Bool = false) -> String {
        if device.role == .approves {
            return alsoAsks ? "It will no longer approve requests, and agents on it can no longer ask for your passwords."
                : "It will no longer approve requests. You can add it again."
        }
        return "Agents on it can no longer ask for your passwords."
    }
    // Devices list (Paper, "On iPhone and Apple Watch", Devices).
    public static let ready = "Ready"
    public static let passesRequests = "Passes requests to iPhone and Apple Watch"

    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}
