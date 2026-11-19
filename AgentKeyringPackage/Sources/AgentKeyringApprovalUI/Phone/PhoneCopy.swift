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
    public static func notificationSubtitle(_ agent: RequestingAgent) -> String {
        agent.machine.isEmpty ? "\(agent.name) wants this password" : "\(agent.name) on \(agent.machine) wants this password"
    }
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
    public static func rule(_ rule: PhoneLogin.Rule) -> String {
        switch rule {
        case .ask: "Ask"
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

    // First run (Paper, "First run", iPhone row).
    public static let appLead = "When an AI agent such as Claude Code or Codex needs one of your passwords, it sends you a request. Approve it on this iPhone with Face ID, or deny it and tell the agent what to do instead."
    /// The Mac's name until the invitation carries it.
    static func mac(_ name: String?) -> String { name ?? "your Mac" }
    public static let startOnMac = "Start on your Mac"
    public static let startOnMacDetail = "Agent Keyring on your Mac holds your passwords. Install it there and follow its steps. This screen moves on by itself when your Mac is ready."
    /// After two minutes with nothing found.
    public static let startOnMacLongWait = "Already set up on your Mac? This iPhone finds it through iCloud. Check that both use the same Apple Account, and that Passwords syncs on both: in Settings, tap your name, then iCloud, then Passwords."
    public static let addComputer = "Add a computer that stays on"
    public static func addComputerDetail(_ name: String?) -> String {
        "Agent Keyring is set up on \(mac(name)). Requests reach your iPhone through a computer of yours that stays on, such as a Mac mini or a home server. To set one up, click the keyhole in the menu bar on \(mac(name)), then Devices, then send the setup message to an agent."
    }
    public static func approveOn(_ name: String?) -> String { "Approve on \(mac(name))" }
    public static func approveOnDetail(_ name: String?) -> String {
        "A request to add this iPhone is beside the pointer on \(mac(name)). Click the green button there and use Touch ID."
    }
    public static func waitingFor(_ name: String?) -> String { "Waiting for \(mac(name))" }
    public static func didNotAdd(_ name: String?) -> String { name.map { "\($0) didn’t add this iPhone" } ?? "Your Mac didn’t add this iPhone" }
    public static func didNotAddDetail(_ name: String?) -> String {
        "The request to add it was denied on your Mac. To try again, tap Ask Again, then approve it on \(mac(name))."
    }
    public static let askAgain = "Ask Again"
    public static let tryPractice = "Try a Practice Request"
    public static let notificationsTitle = "Answer requests from your Lock Screen"
    public static let notificationsLead = "Allow notifications, and each request appears on this iPhone’s Lock Screen, and on your Apple Watch if you add it. Touch and hold it to approve or deny without opening the app."
    public static let notificationsFocus = "Requests are marked Time Sensitive. To let them through a Focus such as Sleep, allow Time Sensitive notifications for that Focus in Settings. To keep them quiet at night, set quiet hours in Agent Keyring’s Settings."
    public static let continueButton = "Continue"
    public static let notificationsOffTitle = "Notifications are off"
    public static let notificationsOff = "Without them, requests appear only while Agent Keyring is open on this iPhone. To answer from your Lock Screen and Apple Watch, turn notifications on in Settings."
    public static let openSettings = "Open Settings"
    public static let continueWithout = "Continue Without Notifications"
    /// The computer that stays on, by name, at the start of a sentence.
    static func relay(_ name: String?) -> String { name ?? "The computer that passes on your requests" }
    public static let practiceCheckTitle = "Check that requests reach this iPhone"
    public static func practiceCheckDetail(_ relayName: String?) -> String {
        "\(relay(relayName)) is sending a practice request, the same way an agent’s request reaches you. Tap it when it arrives."
    }
    public static let practiceWaiting = "Waiting for the practice request"
    public static let practiceNotArrivedTitle = "The practice request hasn’t arrived"
    public static func practiceNotArrivedDetail(_ relayName: String?) -> String {
        let name = relayName ?? "the computer that passes on your requests"
        return "Requests reach this iPhone through \(name). Check that \(name) is turned on and connected to the internet, then try again."
    }
    public static let tryAgain = "Try Again"
    public static let settingUpTitle = "Setting up notifications"
    public static let settingUpDetail = "Apple is connecting this iPhone for notifications. This usually takes a few seconds, and the practice request comes as soon as it is done."
    // The practice request: the real request's layout and the board's words, the same before and after joining.
    /// With no machine, "Practice request: an agent wants".
    public static let practiceAgent = "Practice request: an agent"
    public static let practiceSite = "example.com"
    public static let practiceAccount = "you@example.com"
    public static let practiceReason = "You asked me to download October’s invoice."
    public static let practiceLasts = "Practice only. No password is shared."
    public static let readyTitle = "Ready on this iPhone"
    public static let readyNotifications = "Requests arrive as notifications"
    public static let readyNotificationsDetail = "Touch and hold one to approve or deny. Tap it to see the whole request."
    public static let readyActivity = "Activity shows what agents are doing"
    public static let readyActivityDetail = "See requests waiting for you, passwords agents are using now and what happened earlier. Tap Stop to end an approval early."
    public static let readyWatch = "Add your Apple Watch"
    public static let readyWatchDetail = "To approve from your wrist, open Agent Keyring on your Apple Watch."
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
