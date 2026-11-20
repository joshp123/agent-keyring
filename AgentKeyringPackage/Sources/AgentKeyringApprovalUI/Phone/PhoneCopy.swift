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
    public static let speakReply = "Speak your reply"
    #if os(iOS)
    /// Under the reply box when the microphone cannot listen, and why.
    static func cannotListen(_ reason: PhoneDictation.Reason) -> String {
        switch reason {
        case .microphoneOff: "Agent Keyring may not use the microphone."
        case let .gettingReady(percent): "Getting speech ready on this iPhone (\(percent)%). Type, or try again in a moment."
        case let .unsupported(language): "This iPhone can’t turn \(language) speech into text. Type your reply instead."
        case .failed: "The microphone didn’t start. Type your reply, or try again."
        }
    }
    #endif
    public static let stopSpeaking = "Stop"
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
    /// Who asked, in a list: "Codex on Mac mini", or "Practice request" for a practice request.
    public static func who(_ request: AccessRequest) -> String {
        if request.isPractice { return practiceLabel }
        return request.agent.machine.isEmpty ? request.agent.name : "\(request.agent.name) on \(request.agent.machine)"
    }
    public static let practiceLabel = "Practice request"
    public static func inUseDetail(_ request: AccessRequest, until: Date) -> String {
        "\(who(request)) · until \(clock(until))"
    }
    public static func historyDetail(_ request: AccessRequest) -> String {
        "\(clock(request.askedAt)) · \(who(request))"
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
    public static func passwordsCount(_ count: Int) -> String {
        "\(count) passwords. You don’t need to sort them by hand. On your Mac, open Passwords and click Sort with AI, and an agent suggests a rule for each one."
    }
    public static let askMeans = "agents ask you each time."
    public static let automaticMeans = "agents get it without asking."
    public static let blockedMeans = "no agent can use it."
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
    public static let youApproveOn = "Where you answer requests"
    public static let agentsAskFrom = "Computers whose agents can ask"
    public static let answersWithFaceID = "You answer with Face ID"
    public static let answersWithTap = "You answer with a tap"
    public static let answersWithTouchID = "You answer with Touch ID"
    public static let practiceShort = "Practice"
    public static let thisIPhone = "This iPhone"
    public static let faceID = "Face ID"
    public static let remove = "Remove"
    public static let cancel = "Cancel"

    // First run (Paper, "First run and the app", board "iPhone and Apple Watch").
    public static let welcomeTitle = "Welcome to Agent Keyring"
    public static let appLead = "Agent Keyring gives your AI agents, such as Claude Code and Codex, your passwords when they need them. They ask first, and you answer here with Face ID."
    /// The Mac's name until the invitation carries it.
    static func mac(_ name: String?) -> String { name ?? "your Mac" }
    public static let welcomeSecureTitle = "End-to-end encrypted, locked in Secure Enclave"
    public static let welcomeSecureDetail = "Your passwords are end-to-end encrypted with unlock keys stored inside your devices’ Secure Enclave, and signed so nothing in between can read or tamper with them. Nothing can access a password except an agent you approve, one password at a time, with each approval lasting up to 30 minutes."
    public static let addThisPhone = "Add This iPhone"
    public static let lookingForMac = "Looking for your Mac"
    public static let startOnMac = "Start on your Mac"
    public static let startOnMacDetail = "Agent Keyring on your Mac holds your passwords. Install it there and follow its steps. This screen moves on by itself when your Mac is ready."
    /// After two minutes with nothing found.
    public static let startOnMacLongWait = "Already set up on your Mac? This iPhone finds it through iCloud. Check that both use the same Apple Account, and that Passwords syncs on both: in Settings, tap your name, then iCloud, then Passwords."
    public static let addComputer = "Add a computer that stays on"
    public static func addComputerDetail(_ name: String?) -> String {
        "Agent Keyring is set up on \(mac(name)), but your iPhone also needs a computer of yours that stays on, such as a Mac mini. On \(mac(name)), click the keyhole in the menu bar, then Devices, then Add iPhone or Apple Watch."
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
    public static let notificationsTitle = "Turn on notifications"
    public static let notificationsLead = "Each request arrives as a notification, so you can approve or deny it without opening Agent Keyring. Your Apple Watch shows it too, once you add it."
    public static let notificationsFocus = "If you use a Focus, such as Sleep or Do Not Disturb, requests wait until it ends. To get them anyway, allow Time Sensitive notifications for that Focus in Settings > Focus."
    public static let continueButton = "Continue"
    public static let notificationsOffTitle = "Notifications are off"
    public static let notificationsOff = "Without them, requests appear only while Agent Keyring is open on this iPhone. To get them as notifications on this iPhone and your Apple Watch, turn notifications on in Settings."
    public static let openSettings = "Open Settings"
    public static let continueWithout = "Continue Without Notifications"
    public static let practiceOfferTitle = "Try a request on this iPhone"
    public static let practiceOfferDetail = "Send yourself a practice request. It arrives as a notification, as an agent’s request does. Approve it, deny it, or deny it with a reply. To speak the reply, tap the microphone in the reply box, and tap it again to stop."
    public static let sendPractice = "Send Practice Request"
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
    public static func practiceResultTitle(_ outcome: PhonePracticeOutcome) -> String {
        switch outcome {
        case .approved: "You approved it"
        /// Not drawn: the board shows the approved result only.
        case .denied: "You denied it"
        case .noAnswer: "The practice request ended"
        }
    }
    public static func practiceResultDetail(_ outcome: PhonePracticeOutcome) -> String {
        switch outcome {
        case .approved: "A real agent would now have the password for its task. Try a denial too, with a spoken or typed reply, to see what the agent gets back."
        /// Not drawn.
        case .denied: "A real agent would now be told no, with your reply if you gave one."
        /// Not drawn.
        case .noAnswer: "Nobody answered it within 10 minutes. A real agent would be told there was no answer."
        }
    }
    public static let sendAnother = "Send Another"
    public static let addWatchTitle = "Add your Apple Watch"
    public static let addWatchDetail = "Approve requests with one tap on your wrist. On your Apple Watch, press the Digital Crown, then open Agent Keyring. Then approve your Apple Watch here."
    public static let addWatchInstall = "Not on your Apple Watch? On this iPhone, open the Watch app, scroll to Available Apps and tap Install next to Agent Keyring."
    public static let openWatchApp = "Open the Watch App"
    public static let skip = "Skip"
    // The practice request: the real request's layout and the board's words, the same before and after joining.
    /// With no machine, "Practice request: an agent wants".
    public static let practiceAgent = "Practice request: an agent"
    public static let practiceSite = "example.com"
    public static let practiceAccount = "you@example.com"
    public static let practiceReason = "You asked me to download October’s invoice."
    public static let practiceLasts = "Practice only. No password is shared."
    public static let done = "Done"
    // Home (Paper, "iPhone every day", Home).
    public static let home = "Home"
    public static let homeReady = "Ready"
    /// "Agents on MacBook Pro, Mac mini and Linux server can ask you for passwords. Each request comes here, to your Apple Watch and to your Mac. Answer wherever is nearest."
    public static func homeReadyDetail(computers: [String], watch: Bool, mac: Bool) -> String {
        let places = ["here"] + (watch ? ["to your Apple Watch"] : []) + (mac ? ["to your Mac"] : [])
        let start = computers.isEmpty ? "Agents can ask you for passwords." : "Agents on \(list(computers)) can ask you for passwords."
        return "\(start) Each request comes \(list(places)). Answer wherever is nearest."
    }
    public static let needsYourAnswer = "Needs your answer"
    public static let denyEllipsis = "Deny…"
    public static let earlierToday = "Earlier today"
    public static func homeDetail(_ request: AccessRequest) -> String {
        [ who(request), request.agent.project ].compactMap { $0 }.joined(separator: " · ")
    }
    /// The practice request's notification: short enough that iOS does not cut it.
    public static let practiceNotificationBody = "Practice request: “You asked me to download October’s invoice.”"
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
    public static let timeSensitiveDetail = "When on, requests are marked Time Sensitive, so a Focus that allows Time Sensitive notifications lets them through. To get them while you sleep, open Settings > Focus > Sleep > Apps and turn on Time Sensitive Notifications."
    public static let quietHours = "Quiet Hours"
    public static let from = "From"
    public static let to = "To"
    public static let quietHoursDetail = "During these hours, requests arrive silently and wait in Notification Centre."
    public static let watchFollows = "Your Apple Watch follows these settings."
    // Apple Watch's request to be added (Paper, "On Apple Watch").
    public static let addWatchLead = "Add to Agent Keyring"
    public static let pairedWithThisIPhone = "Paired with this iPhone"
    public static let watchFootnote = "Adding it gives it your passwords, locked to its own Secure Enclave, and asks for Face ID. It then approves requests with one tap while unlocked on your wrist. Remove it in Devices."

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
    public static let passesRequests = "Stays on, and passes requests to this iPhone"

    // What Face ID says it is for.
    public static let faceIDPractice = "Approve the practice request."
    public static func faceIDApprove(agent: String, computer: String, site: String) -> String {
        "Let \(agent) on \(computer) use \(site) for up to 30 minutes."
    }
    public static func faceIDRemove(_ name: String) -> String { "Remove \(name)." }
    public static let faceIDAddWatch = "Let your Apple Watch approve requests."

    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}
