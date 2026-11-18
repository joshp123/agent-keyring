// Written by AI on 2026.11.18 by model Claude Opus 5.5.
//
// Every word the iPhone app and its notifications show, from Paper's pages
// "The request" and "First run and the app". Words Paper does not have are
// marked; they go back to the designer.

import Foundation

public enum PhoneCopy {
    // The request, in the app and in the held notification.
    public static let appName = "Agent Keyring"
    public static func wants(_ agent: RequestingAgent) -> String { "\(agent.name) on \(agent.machine) wants" }
    public static func quoted(_ reason: String) -> String { "“\(reason)”" }
    public static func replyPlaceholder(_ agent: RequestingAgent) -> String { "What should \(agent.name) do instead?" }
    /// Not in Paper: when the agent's name is too long for the box beside Deny.
    public static let replyPlaceholderShort = "What should it do instead?"
    public static let deny = "Deny"
    public static let approveWithFaceID = "Approve with Face ID"
    public static func lasts(_ agent: RequestingAgent) -> String {
        "\(agent.name) can use this login for this task, 30 minutes at most."
    }

    /// "Project bookkeeping", "Folder Downloads", or nothing.
    public static func scope(_ agent: RequestingAgent) -> (label: String, name: String)? {
        if let project = agent.project, !project.isEmpty { return ("Project", project) }
        if let folder = agent.folder, !folder.isEmpty { return ("Folder", folder) }
        return nil
    }

    // The notification on the Lock Screen.
    public static func notificationTitle(_ request: AccessRequest) -> String { request.login.site }
    public static func notificationSubtitle(_ agent: RequestingAgent) -> String { "\(agent.name) on \(agent.machine) wants this login" }
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
        case let .approved(_, until): return "Approved\(on). \(request.agent.name) can use this login until \(clock(until)) at the latest."
        case let .denied(_, reply?, _): return "Denied\(on). You told \(request.agent.name): \(quoted(reply))"
        case .denied: return "Denied\(on)."
        case .unanswered: return "No answer. The request ended after 10 minutes, and \(request.agent.name) can ask again."
        case .cancelled: return "Withdrawn. \(request.agent.name) stopped asking before you answered."
        default: return "This request has ended."
        }
    }

    /// Shown if the request's words cannot be opened in time.
    public static let notificationFallbackTitle = "An agent wants to use a login."
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
        case .cancelled, .waitingForYou, .sendingAnswer, .waitingForMac: (.noAnswer, "Withdrawn")
        }
    }

    // Logins.
    public static let logins = "Logins"
    public static let search = "Search"
    public static func rule(_ rule: PhoneLogin.Rule) -> String {
        switch rule {
        case .ask: "Ask"
        case .askOnIPhoneOrWatch: "Ask on iPhone or Watch"
        case .automatic: "Automatic"
        case .blocked: "Blocked"
        }
    }

    // Devices.
    public static let devices = "Devices"
    public static let youApproveOn = "You approve on"
    public static let agentsAskFrom = "Agents ask from"
    public static let thisIPhone = "This iPhone"
    public static let faceID = "Face ID"
    public static let remove = "Remove"
    public static let cancel = "Cancel"

    // First run (Paper, "First run").
    public static let firstRunLead = "Approve or deny your AI agents’ requests on this iPhone."
    public static let readyLead = "This iPhone is ready. Requests appear here."
    public static let approveOnMac = "Approve this iPhone on your Mac"
    public static let approveOnMacDetail = "A request is waiting there. Click its green button, then touch the sensor."
    public static let macAdded = "Your Mac added this iPhone"
    public static let noMac = "No Mac found. Set up Agent Keyring on your Mac first."
    public static let iCloudKeychainOff = "iCloud Keychain is off on this iPhone, so it can’t find your Mac. Turn it on in Settings."
    public static let notificationsOn = "Notifications are on"
    public static let notificationsOff = "Notifications are off"
    public static let notificationsOffDetail = "Requests can’t reach this iPhone until you turn them on in Settings."
    public static let openSettings = "Open Settings"
    public static let requestsReach = "Requests reach this iPhone"
    public static let cantReachRelay = "This iPhone can’t reach Mac mini. Check that Tailscale is on."
    public static let noAlwaysOn = "Your Mac has no always-on machine yet, so requests can’t reach this iPhone. Add one on your Mac."
    public static let testApproved = "You approved the test request with Face ID"
    public static let addWatch = "Add your Watch"
    public static let addWatchOpen = "Open Agent Keyring on your Watch."
    public static let addWatchApprove = "Approve the Watch’s request with Face ID."
    public static func deviceWorks(_ name: String) -> String { "\(name) works" }

    // The test request and a new device's request, as sheets.
    public static let testFrom = "A test from Agent Keyring"
    public static let testTitle = "Test request"
    public static let noLoginUsed = "No login is used"
    public static let testFootnote = "Approve it to finish setting up."
    public static let newDevice = "A new device wants to approve requests"
    public static let pairedWithThisIPhone = "Paired with this iPhone"
    public static let watchFootnote = "It will approve with one tap while it is on your wrist and unlocked. You can remove it at any time."

    // Failures.
    public static let answerFailed = "Your answer wasn’t sent. Try again."
    public static func stopFailed(until: Date?) -> String {
        "Couldn’t stop it. Try again." + (until.map { " It ends by itself at \(clock($0))." } ?? "")
    }
    public static let changeFailed = "That change wasn’t saved. Try again."
    public static let ok = "OK"
    public static func removeQuestion(_ name: String) -> String { "Remove \(name)?" }
    public static func removeDetail(_ device: PhoneDevice) -> String {
        device.role == .approves ? "It will no longer approve requests. You can add it again."
            : "Agents on it will no longer be able to ask to use your logins."
    }

    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}
