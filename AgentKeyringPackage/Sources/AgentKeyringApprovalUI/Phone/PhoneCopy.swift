// Written by AI on 2026.11.18 by model Claude Opus 5.5; rewritten from the master copy ledger of 21 November 2026.
//
// Every word the iPhone app and its notifications show, in screen order. The
// words come from master-copy-audit-21-nov.md; where it and the truth
// disagree, the truth wins, and the line says so.

import Foundation

public enum PhoneCopy {
    public static let appName = "Agent Keyring"
    /// The Mac's name until the join card carries it.
    static func mac(_ name: String?) -> String { name ?? "your Mac" }

    // MARK: Common buttons

    public static let cancel = "Cancel"
    public static let tryAgain = "Try Again"
    public static let askAgain = "Ask Again"
    public static let continueButton = "Continue"
    public static let done = "Done"
    public static let close = "Close"
    public static let ok = "OK"
    public static let openSettings = "Open Settings"
    public static let skipForNow = "Skip for Now"
    public static let checkAgain = "Check Again"
    public static let doThisLater = "Do This Later"
    public static let havingTrouble = "Having trouble?"

    // MARK: Add iPhone: finding the Mac and joining

    public static let lookingForMac = "Looking for your Mac via iCloud…"
    public static func continueFrom(_ name: String?) -> String { "Continue setup from \(mac(name))" }
    public static let continueFromDetail = "Connect this iPhone to approve password requests from your AI agents with Face ID."
    public static let trustTitle = "End-to-end encrypted and signed"
    public static let trustDetail = "Your Mac encrypts a copy of your passwords for this iPhone’s Secure Enclave and signs them against tampering, so nothing in between can read or change them."
    public static func connectTo(_ name: String?) -> String { "Connect to \(mac(name))" }
    public static let troubleBanner = "Can’t find your Mac right now"
    public static let troubleTitle = "Check these four things"
    public static let troubleSteps = [
        "Agent Keyring is open on your Mac.",
        "Tailscale is turned on for both your Mac and this iPhone.",
        "Both devices use the same Apple Account.",
        "iCloud Passwords & Keychain is on in Settings.",
    ]
    public static func cantReach(_ name: String?) -> String { "Can’t reach \(mac(name))" }
    public static func cantReachDetail(_ name: String?) -> String {
        "Check that Tailscale is turned on for both your Mac and this iPhone, and that \(mac(name)) is awake."
    }
    public static func approveOn(_ name: String?) -> String { "Approve on \(mac(name))" }
    public static func approveOnDetail(_ name: String?) -> String { "Confirm with Touch ID on \(mac(name)) to connect this iPhone." }
    public static func waitingFor(_ name: String?) -> String { "Waiting for \(mac(name))" }
    public static func notApprovedOn(_ name: String?) -> String { "Not approved on \(mac(name))" }
    public static let notApprovedDetail = "This iPhone wasn’t added. You can ask again when you’re ready."
    public static let joinExpiredTitle = "The request timed out"
    public static func joinExpiredDetail(_ name: String?) -> String { "Tap below to ask \(mac(name)) again." }
    public static let receivingTitle = "Copying your passwords"
    public static func receivingDetail(_ fill: PhoneFill?) -> String {
        fill.map { "\($0.copied) of \($0.of) passwords received." } ?? "Your Mac is encrypting a copy of each password for this iPhone."
    }

    // MARK: Add iPhone: notifications

    public static let notificationsTitle = "Turn on notifications"
    public static let notificationsLead = "Password requests from your AI agents arrive as notifications so you can approve or deny them straight from your Lock Screen."
    public static let checkAllowed = "Notifications allowed"
    public static let checkBanners = "Banners and Lock Screen"
    public static let checkTimeSensitive = "Time Sensitive"
    public static let checkNotScheduled = "Not in Scheduled Summary"
    /// Not in the ledger: under an unticked row, what to do.
    public static let checkTurnOnFirst = "Tap Turn On Notifications below."
    public static let checkInSettings = "Turn this on in Settings > Notifications > Agent Keyring."
    public static let checkScheduledInSettings = "Turn off Scheduled Summary for Agent Keyring in Settings > Notifications."
    public static let notificationsFocus = "Vibe coding late at night? If Sleep or Driving Focus is on, iOS silences notifications unless Agent Keyring is allowed in Settings > Focus."
    public static let notificationsOff = "Notifications are turned off for Agent Keyring. Turn them on in Settings so password requests reach your Lock Screen."
    public static let turnOnNotifications = "Turn On Notifications"
    public static let continueWithout = "Continue Without Notifications"

    // MARK: Add iPhone: practice

    public static let practiceTitle = "Try a practice notification"
    public static let practiceLead = "Tap below to send yourself a practice password request. Touch and hold it to try Approve, Deny, or Deny and Explain. No real passwords are shared."
    public static let practicePreviewTitle = "Practice request: example.com"
    public static let practicePreview = "you@example.com: “You asked me to download October’s invoice.” Touch and hold to Approve, Deny, or Deny and Explain."
    public static let practiceNote = "If nothing arrives within 30 seconds, tap Answer It Here, or open Settings > Focus to allow Agent Keyring during Sleep or Driving Focus."
    public static let sendPractice = "Send Practice Request"
    public static let sendAnother = "Send Another"
    public static let practiceWaiting = "Waiting for notification…"
    public static let practiceSettingUp = "Setting up Apple notifications… Try again in a moment."
    public static let practiceNotArrived = "Didn’t see the notification? Focus may have silenced it, or notifications may be off."
    public static let answerItHere = "Answer It Here"
    public static func practiceMacAsleep(_ name: String?) -> String {
        "\(mac(name)) sends practice requests, so it needs to be awake with Agent Keyring open. Real requests come from the computer that asks."
    }
    public static func practiceResult(_ outcome: PhonePracticeOutcome) -> String {
        switch outcome {
        case .approved: "Practice approved."
        case .denied: "Practice denied."
        case .noAnswer: "The practice request ended with no answer."
        }
    }

    // MARK: Add iPhone: ready, and the offer to add Apple Watch

    public static let readyTitle = "This iPhone is ready"
    public static let readyDetail = "Password requests from your AI agents will arrive here so you can approve them with Face ID."
    public static let addWatchOfferTitle = "Add your Apple Watch?"
    public static let addWatchOfferDetail = "Approve password requests with one tap on your wrist."
    public static let addAppleWatch = "Add Apple Watch"

    // MARK: Add Apple Watch, on the iPhone

    public static let notPairedTitle = "No Apple Watch is paired with this iPhone"
    public static let installOnWatchTitle = "Install Agent Keyring on your Apple Watch"
    public static let installOnWatchDetail = "Your Apple Watch is paired with this iPhone, but Agent Keyring isn’t installed on it yet."
    /// The ledger has an Open Watch App button; no app can open Apple's Watch app there, so the steps are words.
    public static let installOnWatchSteps = [
        "On this iPhone, open Apple’s Watch app.",
        "In My Watch, scroll to Available Apps.",
        "Tap Install next to Agent Keyring, then return here.",
    ]
    public static let addWatchTitle = "Add your Apple Watch"
    public static let addWatchDetail = "Approve password requests from your AI agents with one tap on your wrist. Your iPhone encrypts passwords for your Watch’s Secure Enclave."
    public static let addWatchSteps = [
        "Confirm with Face ID here so this iPhone can prepare your passwords for your Watch.",
        "Open Agent Keyring on your Apple Watch and tap Add.",
    ]
    public static let continueWithFaceID = "Continue with Face ID"
    public static func confirmedUntil(_ until: Date) -> String { "Confirmed with Face ID · ready until \(clock(until))" }
    public static let tapAddOnWatch = "Now tap Add on your Apple Watch"
    public static let tapAddOnWatchDetail = "Open Agent Keyring on your Apple Watch and tap Add. This iPhone will encrypt your passwords for your Watch."
    public static let watchNotShowingTitle = "Not showing up on your Watch?"
    public static let watchNotShowing = "Check that your Watch is unlocked, has a passcode, and Bluetooth is on. You can cancel and start again any time."
    public static let faceIDExpired = "Face ID confirmation expired. Confirm again to add your Apple Watch."
    public static let watchNeedsPasscode = "Your Apple Watch needs a passcode before it can store Secure Enclave keys. Turn on a passcode in Apple’s Watch app, then try again."
    public static func encryptingForWatch(_ done: Int, _ total: Int) -> String { "Encrypting passwords for Apple Watch (\(done) of \(total))" }
    public static func watchCopiesFailed(_ reason: String) -> String {
        let reason = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return "Couldn’t finish preparing passwords for your Apple Watch. \(reason)."
    }
    /// The reason in a failure line: the Mac refused it, or could not be reached. Never a raw error.
    public static let macRefused = "Your Mac refused it"
    public static let macNotReached = "Your Mac couldn’t be reached"
    public static let watchAdded = "Apple Watch added"
    public static let watchAddedDetail = "You can now approve password requests with one tap on your wrist."

    // MARK: The request, in the app and in the held notification

    public static func wants(_ agent: RequestingAgent) -> String { agent.machine.isEmpty ? "\(agent.name) wants" : "\(agent.name) on \(agent.machine) wants" }
    public static func quoted(_ reason: String) -> String { "“\(reason)”" }
    public static let deny = "Deny"
    public static let approve = "Approve"
    public static let denyAndExplain = "Deny and Explain"
    public static func lasts(_ agent: RequestingAgent) -> String { "\(agent.name) can use this password for this task, 30 minutes at most." }
    public static let practiceLasts = "Practice only. No passwords are shared."
    public static func askedAgo(_ date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        return minutes == 0 ? "Asked just now" : "Asked \(minutes) min ago"
    }
    public static let tellTheAgent = "Tell the agent what to do instead"
    public static let replyPrompt = "Type, or tap the microphone and speak"
    public static let denyAndSend = "Deny and Send"
    public static let approveInstead = "Approve Instead"
    public static let listening = "Listening…"
    public static let speakHint = "Tap the square to stop speaking, then tap Deny and Send."
    public static let speakReply = "Speak your reply"
    public static let stopSpeaking = "Stop speaking"
    #if os(iOS)
    /// Under the reply box when the microphone cannot listen, and why.
    static func cannotListen(_ reason: PhoneDictation.Reason) -> String {
        switch reason {
        case .microphoneOff: "Agent Keyring can’t use the microphone. Turn on Microphone in Settings."
        case let .gettingReady(percent): "Getting the speech model from Apple (\(percent)%). Type, or wait a moment."
        case .unsupported, .failed: "Voice input isn’t available right now. Type your reply instead."
        }
    }
    #endif
    public static let answerFailed = "Your answer wasn’t sent. Try again."
    public static let notDeliveredYet = "Not delivered yet. Trying again…"

    // MARK: The notification on the Lock Screen

    public static func notificationTitle(_ request: AccessRequest) -> String { request.login.site }
    /// The ledger puts who asks in the subtitle; iOS cuts a subtitle to one line, so it leads the body instead.
    public static func notificationSubtitle(_ agent: RequestingAgent) -> String {
        agent.machine.isEmpty ? "\(agent.name) wants this password" : "\(agent.name) on \(agent.machine) wants this password"
    }
    public static func notificationBody(_ request: AccessRequest) -> String {
        "\(request.login.account): \(quoted(request.agentReason))"
    }
    public static let practiceNotificationBody = "Practice request: “You asked me to download October’s invoice.”"
    public static let notificationFallbackTitle = "An agent wants to use a password."
    public static let notificationFallbackBody = "Open Agent Keyring to see the request."
    /// The push that replaces a request on the Lock Screen once it has ended.
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

    // MARK: The practice request

    /// With no computer: "Practice request: an agent wants".
    public static let practiceAgent = "Practice request: an agent"
    public static let practiceSite = "example.com"
    public static let practiceAccount = "you@example.com"
    public static let practiceReason = "You asked me to download October’s invoice."
    public static let practiceLabel = "Practice request"

    // MARK: Home

    public static let home = "Home"
    public static func waitingPill(_ count: Int) -> String { "\(count) waiting" }
    public static let allQuiet = "All quiet"
    public static let waitingForYou = "Waiting for you"
    public static let inUse = "In use"
    public static let earlierToday = "Earlier today"
    /// The truth about these lists: the iPhone knows only the requests whose push or answer reached it.
    public static let seenOnThisIPhone = "Requests this iPhone has seen. One answered on your Mac shows here once its notice reaches this iPhone."
    public static let nothingWaiting = "Nothing waiting. Nothing in use."
    public static let stop = "Stop"
    public static func until(_ date: Date) -> String { "until \(clock(date))" }
    /// Who asked, in a list: "Codex on Mac mini", or "Practice request".
    public static func who(_ request: AccessRequest) -> String {
        if request.isPractice { return practiceLabel }
        return request.agent.machine.isEmpty ? request.agent.name : "\(request.agent.name) on \(request.agent.machine)"
    }
    public static func inUseDetail(_ request: AccessRequest, until: Date) -> String { "\(who(request)) · \(self.until(until))" }
    public static func historyDetail(_ request: AccessRequest) -> String { "\(who(request)) · \(clock(request.askedAt))" }
    public enum Outcome { case approved, denied, noAnswer }
    public static func outcome(_ state: AccessRequestState) -> (Outcome, String) {
        switch state {
        case .approved(by: .automaticRule, _): (.approved, "Automatic")
        case .approved, .expired, .released: (.approved, "Approved")
        case .ended: (.approved, "Stopped")
        case .blockedByRule: (.denied, "Blocked")
        case .denied: (.denied, "Denied")
        case .unanswered: (.noAnswer, "No answer")
        case .cancelled, .waitingForYou, .sendingAnswer, .waitingForMac: (.noAnswer, "Cancelled")
        }
    }
    public static let stillConnecting = "This iPhone is still connecting. Until it finishes, requests appear only while Agent Keyring is open."
    public static func macOffline(_ name: String?) -> String {
        "Can’t reach \(mac(name)). Requests still come from the computers that ask; changes to your passwords arrive once it is back."
    }
    public static func notice(_ notice: PhoneNotice) -> String {
        switch notice {
        case .stillConnecting: stillConnecting
        case let .macOffline(name): macOffline(name)
        case .addAppleWatch: addWatchOfferDetail
        }
    }
    public static let stopLeftWithMac = "Stop reaches that computer the next time one of its agents uses Agent Keyring."
    public static func stopFailed(until: Date?) -> String {
        "Couldn’t stop it. Try again." + (until.map { " It ends by itself at \(clock($0))." } ?? "")
    }

    // MARK: Passwords

    public static let passwords = "Passwords"
    public static let askLegend = "**Ask:** you approve each time an agent wants it."
    public static let automaticLegend = "**Automatic:** agents on the computers you choose get it without asking you."
    public static let blockedLegend = "**Blocked:** no agent can ever use it."
    public static let twoFactorLegend = "**Two-factor codes:** for Ask passwords, the secret stays on your devices and agents get only the current code. For Automatic passwords, the chosen computer holds its own encrypted copy."
    public static let sortWithAI = "To set rules for many passwords at once, use Sort with AI on your Mac."
    public static func passwordsCount(_ count: Int) -> String { "\(count) passwords" }
    public static let search = "Search"
    public static func rule(_ rule: PhoneLogin.Rule) -> String {
        switch rule {
        case .ask: "Ask"
        case .automatic: "Automatic"
        case .blocked: "Blocked"
        }
    }
    public static let changeFailed = "That change wasn’t saved. Try again."
    /// Face ID's sentence when a password becomes Automatic.
    public static func automaticReason(site: String, from: PhoneLogin.Rule, computers: [String]) -> String {
        "\(site) changes from \(rule(from)) to Automatic. Agents on \(list(computers)) will get it without asking."
    }
    /// "A", "A and B", "A, B and C".
    public static func list(_ names: [String]) -> String {
        names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // MARK: Devices

    public static let devices = "Devices"
    public static let youApproveOn = "Where you approve password requests"
    public static let agentsAskFrom = "Other computers"
    public static let thisIPhone = "This iPhone"
    public static let answersWithFaceID = "Face ID"
    public static let answersWithTap = "One tap"
    public static let answersWithTouchID = "Touch ID"
    public static let connected = "Its agents can ask you"
    public static let addAppleWatchRow = "Add Apple Watch…"
    public static let practiceShort = "Send Practice Request"
    public static let remove = "Remove"
    public static func removeQuestion(_ name: String) -> String { "Remove \(name)?" }
    /// `alsoAsks`: a Mac both approves and has agents that ask; one Remove takes both.
    public static func removeDetail(_ device: PhoneDevice, alsoAsks: Bool = false) -> String {
        if device.role == .approves {
            return alsoAsks ? "\(device.name) will no longer receive password requests or hold copies of your passwords, and agents on it can no longer ask."
                : "\(device.name) will no longer receive password requests or hold copies of your passwords."
        }
        return "Agents on \(device.name) can no longer ask for your passwords."
    }

    // MARK: Settings

    public static let settings = "Settings"
    public static let timeSensitive = "Time Sensitive Notifications"
    public static let timeSensitiveDetail = "When on, requests are marked Time Sensitive, so a Focus that allows Time Sensitive notifications lets them through. To get them while you sleep, open Settings > Focus > Sleep > Apps and turn on Time Sensitive Notifications."
    public static let quietHours = "Quiet Hours"
    public static let from = "From"
    public static let to = "To"
    public static let quietHoursDetail = "During these hours, requests arrive silently and wait in Notification Centre."
    public static let watchFollows = "Your Apple Watch follows these settings."

    // MARK: What Face ID says it is for

    public static let faceIDPractice = "Approve the practice request."
    public static func faceIDApprove(agent: String, computer: String, site: String) -> String {
        "Let \(agent) on \(computer) use \(site) for up to 30 minutes."
    }
    public static func faceIDRemove(_ name: String) -> String { "Remove \(name)." }
    public static let faceIDAddWatch = "Let your Apple Watch approve requests."
    public static func faceIDSetRule(site: String, rule: PhoneLogin.Rule) -> String { "Set \(site) to \(self.rule(rule))." }
    public static let anAgent = "An agent"
    public static let passwordNotOnThisIPhone = "This password isn’t on this iPhone yet. Open Agent Keyring on your Mac, then try again."

    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}
