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
    /// Not in Paper: shown if the request's words cannot be opened in time.
    public static let notificationFallbackTitle = "An agent is asking to use a login"
    public static let notificationFallbackBody = "Open Agent Keyring to see the request."

    // The buttons iOS draws under a held notification.
    public static let approve = "Approve"
    public static let denyAndExplain = "Deny and Explain"
    /// Not in Paper: the category is fixed, so it cannot name the agent.
    public static let explainPlaceholder = "What should the agent do instead?"

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
        case .approved, .expired, .released, .ended: (.approved, "Approved")
        case .denied, .blockedByRule: (.denied, "Denied")
        case .unanswered: (.noAnswer, "No answer")
        // Not in Paper: the agent stopped asking before anyone answered.
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

    // First run.
    public static let firstRunLead = "Approve or deny your AI agents’ requests on this iPhone."
    public static let pointCamera = "Point the camera at the code on your Mac."
    public static let canApprove = "This iPhone can approve"
    public static let turnOnNotificationsLead = "Turn on notifications so that requests reach you while the iPhone is locked."
    public static let turnOnNotifications = "Turn On Notifications"
    public static let watchQuestion = "Let your Apple Watch approve too?"
    public static let watchLead = "On the Watch you approve with one tap, while it is unlocked on your wrist."
    public static let allowWithFaceID = "Allow with Face ID"
    public static let notNow = "Not Now"

    // Failures. Not in Paper.
    public static let answerFailed = "Your answer didn’t reach Agent Keyring. Try again."
    public static let stopFailed = "Couldn’t stop it. It stops by itself after 30 minutes."
    public static let joinFailed = "That code didn’t work. Show a new code on your Mac and try again."
    public static let watchFailed = "Couldn’t add your Watch. Try again from Devices."
    public static let changeFailed = "Couldn’t make that change. Try again."
    public static let ok = "OK"
    public static func removeQuestion(_ name: String) -> String { "Remove \(name)?" }
    public static func removeDetail(_ device: PhoneDevice) -> String {
        device.role == .approves ? "It will no longer be able to approve requests." : "Its agents will no longer be able to ask for logins."
    }

    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}
