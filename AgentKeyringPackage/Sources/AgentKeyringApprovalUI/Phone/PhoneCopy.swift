// Written by AI on 2026.11.18 by model Claude Opus 5.5; rewritten from the master copy ledger of 21 November 2026.
//
// Every word the iPhone app shows, in screen order. The
// words come from master-copy-audit-21-nov.md; where it and the truth
// disagree, the truth wins, and the line says so.

import AgentKeyringApprovalCore
import Foundation

public enum RequestHistoryOutcome { case approved, denied, noAnswer }

extension PhoneCopy {
    public static let appName = SharedCopy.appName
    /// The inviting device's name, as a sentence says it: "your Mac" until the join card carries a name, and
    /// "your other iPhone" for an iPhone, whose name is only "iPhone".
    static func mac(_ name: String?) -> String {
        switch name {
        case nil: "your Mac"
        case "iPhone"?: "your other iPhone"
        case let name?: name
        }
    }
    /// The same, at the start of a sentence.
    static func macAtStart(_ name: String?) -> String {
        let said = mac(name)
        return said.hasPrefix("your ") ? "Y" + said.dropFirst() : said
    }

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

    // MARK: Add iPhone: the first screen, finding the Mac and joining

    public static let lookingForMac = "Looking for your Mac in your iCloud Keychain…"
    public static let welcomeTitle = "Welcome to Agent Keyring"
    public static let welcomeDetail = "Copy your passwords from Passwords to this iPhone, then approve your AI agents’ password requests with Face ID. You can add a Mac or other computers at any time."
    public static let alreadySetUpOnMac = "Already set up on your Mac?"
    public static func continueFrom(_ name: String?) -> String { "Continue setup from \(mac(name))" }
    public static func continueFromDetail(_ name: String?) -> String {
        "This iPhone found \(mac(name)) through your iCloud Keychain. Connect to approve password requests from your AI agents with Face ID."
    }
    public static let trustTitle = "End-to-end encrypted and signed"
    public static func trustDetail(_ name: String?) -> String {
        "\(macAtStart(name)) encrypts a copy of your passwords for this iPhone’s Secure Enclave and signs it against tampering, so nothing in between can read or change them."
    }
    public static func connectTo(_ name: String?) -> String { "Connect to \(mac(name))" }
    public static let troubleTitle = "Check these four things"
    public static let troubleLead = "This iPhone finds your Mac through your iCloud Keychain."
    public static let troubleSteps = [
        "Agent Keyring is open on your Mac.",
        "Your Mac is awake and online.",
        "Both devices use the same Apple Account.",
        "iCloud Passwords & Keychain is on in Settings.",
    ]
    public static func cantReach(_ name: String?) -> String { "Can’t reach \(mac(name))" }
    public static func cantReachDetail(_ name: String?) -> String {
        "Make sure \(mac(name)) is awake and online with Agent Keyring open, and that this iPhone is signed in to iCloud."
    }
    public static func approveOn(_ name: String?) -> String { "Approve on \(mac(name))" }
    public static func approveOnDetail(_ name: String?) -> String { "Confirm on \(mac(name)) to connect this iPhone." }
    public static func waitingFor(_ name: String?) -> String { "Waiting for \(mac(name))" }
    public static func notApprovedOn(_ name: String?) -> String { "Not approved on \(mac(name))" }
    public static let notApprovedDetail = "This iPhone wasn’t added. You can ask again when you’re ready."
    public static let joinExpiredTitle = "The request timed out"
    public static func joinExpiredDetail(_ name: String?) -> String { "Tap below to ask \(mac(name)) again." }
    public static let receivingTitle = "Copying your passwords"
    public static func receivingDetail(_ fill: PhoneFill?) -> String {
        fill.map { "\($0.copied) of \($0.of) passwords received." } ?? "Encrypting a copy of each password for this iPhone…"
    }

    // MARK: Add iPhone: notifications

    public static let notificationsTitle = "Turn on notifications"
    public static let notificationsLead = "Password requests from your AI agents arrive as notifications so you can approve or deny them straight from your Lock Screen."
    public static let checkAllowed = "Notifications allowed"
    public static let checkNotYetAllowed = "Notifications not yet allowed"
    public static let checkTurnedOff = "Notifications turned off"
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
    public static let practiceLead = "Tap below to send yourself a practice password request. Touch and hold it to try Approve, Deny, or Deny & Reply. No real passwords are shared."
    public static let practiceArrived = "Touch and hold the notification at the top of your screen, or swipe down Notification Centre, to Approve, Deny, or Deny & Reply."
    public static let practiceNote = "If nothing arrives within 30 seconds, tap Answer It Here, or open Settings > Focus to allow Agent Keyring during Sleep or Driving Focus."
    public static let sendPractice = "Send Practice Request"
    public static let sendAnother = "Send Another"
    public static let practiceWaiting = "Waiting for notification…"
    public static let practiceSettingUp = "Setting up Apple notifications… Try again in a moment."
    public static let practiceNotArrived = "Didn’t see the notification? Focus may have silenced it, or notifications may be off."
    public static let answerItHere = "Answer It Here"
    /// This iPhone could not send itself the practice request: no connection, or no push address yet.
    public static let practiceNotSent = "The practice request couldn’t be sent. Check that this iPhone is online, then try again."
    public static func practiceResult(_ outcome: PhonePracticeOutcome, reply: String? = nil) -> String {
        switch outcome {
        case .approved: "Practice approved."
        case .denied:
            if let reply, !reply.isEmpty { "Practice denied: \(quoted(reply))" }
            else { "Practice denied." }
        case .noAnswer: "The practice request ended with no answer."
        }
    }

    // MARK: Add iPhone: set up on this iPhone, with no Mac

    public static let setUpHere = "Set Up on This iPhone"
    public static let setUpFailed = "This iPhone wasn’t set up. Try again."

    // MARK: Adding passwords from Apple Passwords, on this iPhone

    public static let copyTitle = "Add passwords from Apple Passwords"
    public static let copyLead = "Agent Keyring keeps its own copy, encrypted for this iPhone’s Secure Enclave. Neither we nor Apple can read it."
    public static let copySteps = [
        "Turn on Agent Keyring in Apple Passwords, below.",
        "Open Apple Passwords and tap the More button.",
        "Tap Export Data to Another App, then choose Agent Keyring.",
        "Confirm with Face ID. Your passwords arrive here.",
    ]
    public static let turnOnInPasswords = "Turn On in Apple Passwords"
    public static let turnedOnInPasswords = "Agent Keyring is on in Apple Passwords."
    public static let copyWaiting = "Waiting for Apple Passwords…"
    public static let copyingNow = "Encrypting your passwords for this iPhone…"
    public static let copyFromPasswords = "Add from Apple Passwords…"
    public static func copiedOn(_ date: Date) -> String { "Added from Apple Passwords on \(day(date))." }
    public static func copiedOnStale(_ date: Date) -> String { "Added from Apple Passwords on \(day(date)). Update from Apple Passwords to pick up changes." }
    public static let notCopiedYet = "No passwords added from Apple Passwords yet."
    public static let otherDevicesGetCopies = "Your other devices get their own encrypted copies through your own iCloud."

    // MARK: Add another computer, from this iPhone

    public static let addComputerRow = "Add Agent Computer"
    /// Ready, with no computer or Mac added yet.
    public static let addAComputer = "Add Agent Computer"
    public static let addComputerTitle = "Add agent computer"
    public static let addComputerLead = "Run this on the computer, or paste it to an agent there. The code works once, for 10 minutes."
    public static let copyCommand = "Copy Command"
    public static let shareCommand = "Share…"
    public static let commandCopied = "Copied"
    public static func waitingForComputer(until: Date) -> String { "Waiting for the computer. The code works until \(clock(until))." }
    public static func computerAsks(_ name: String) -> String { "\(name) asks to join" }
    public static let computerAsksDetail = "Agents on it will be able to ask you for passwords. Each request comes to this iPhone."
    public static let dontAdd = "Don’t Add"
    public static func adding(_ name: String) -> String { "Adding \(name)…" }
    public static func computerAdded(_ name: String) -> String { "\(name) is added" }
    public static let computerAddedDetail = "Its agents can now ask you for passwords."
    public static func computerNotAdded(_ name: String) -> String { "\(name) wasn’t added." }
    public static let codeExpired = "The code ran out. Make a new one to try again."
    public static let newCode = "New Code"

    // MARK: A Mac or another iPhone joining this iPhone's list, through iCloud

    public static func addDeviceLead(isMac: Bool) -> String { isMac ? "Add this Mac to Agent Keyring?" : "Add this iPhone to Agent Keyring?" }
    public static func addDeviceBody(isMac: Bool) -> String {
        isMac ? "It gets its own encrypted copy of your passwords, locked in its Secure Enclave, and can approve password requests. Agents on it can ask you for passwords."
            : "It gets its own encrypted copy of your passwords, locked in its Secure Enclave, and can approve password requests with Face ID."
    }
    public static let add = "Add"
    public static let addDeviceFailed = "It wasn’t added. Ask again from the other device."

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
    public static let tapAddOnWatch = "Open Agent Keyring on your Apple Watch"
    public static let tapAddOnWatchDetail = "Keep this iPhone open while you add your Watch."
    public static let tapAddOnWatchSteps = [
        "Open the Agent Keyring app on your Apple Watch.",
        "Tap Add on your Watch.",
        "Stay nearby while this iPhone encrypts your passwords for your Watch.",
    ]
    public static let watchNotShowingTitle = "Not showing up on your Watch?"
    public static let watchNotShowing = "Check that your Watch is unlocked, has a passcode, and Bluetooth is on. You can cancel and start again any time."
    public static let faceIDExpired = "Face ID confirmation expired. Confirm again to add your Apple Watch."
    public static let watchNeedsPasscode = "Your Apple Watch needs a passcode before it can store Secure Enclave keys. Turn on a passcode in Apple’s Watch app, then try again."
    public static func encryptingForWatch(_ done: Int, _ total: Int) -> String { "Encrypting passwords for Apple Watch (\(done.formatted()) of \(total.formatted()))" }
    public static func watchCopiesFailed(_ reason: String) -> String {
        let reason = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return "Couldn’t finish preparing passwords for your Apple Watch. \(reason)."
    }
    /// The reason in a failure line: the Watch did not take its passwords, or this iPhone lacks some. Never a raw error.
    public static let watchAdded = "Apple Watch added"
    public static let watchAddedDetail = "You can now approve password requests with one tap on your wrist."

    // MARK: The request, in the app and in the held notification

    public static func wants(_ agent: RequestingAgent) -> String { agent.machine.isEmpty ? agent.name : "\(agent.name) · \(agent.machine)" }
    public static let deny = SharedCopy.deny
    public static let approve = SharedCopy.approve
    public static let approveWithFaceID = SharedCopy.approve
    public static let approving = "Approving…"
    public static let back = "Back"
    public static let denyAndExplain = SharedCopy.denyAndReply
    public static func lasts(_ agent: RequestingAgent) -> String { "\(agent.name) can use this password for this task." }
    public static let practiceLasts = "Practice only. No passwords are shared."
    public static func askedAgo(_ date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        return minutes == 0 ? "Asked just now" : "Asked \(minutes) min ago"
    }
    public static let tellTheAgent = "Reply to the agent"
    public static let replyPrompt = SharedCopy.replyPlaceholder
    public static let denyAndSend = SharedCopy.denyAndSend
    public static let approveInstead = "Approve Instead"
    public static let listening = "Listening…"
    public static let speakHint = "Tap the square to stop speaking, then tap Deny & Send."
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
    public static func staleRequestNote(_ state: AccessRequestState) -> String {
        switch state {
        case .approved, .released, .expired, .ended: "This request was already approved."
        case .denied, .blockedByRule: "This request was already denied."
        case .unanswered: "This request ended with no answer."
        case .cancelled: "This request was cancelled."
        default: "This request has already ended."
        }
    }

    // MARK: The practice request

    public static let practiceLabel = "Practice request"

    // MARK: Activity

    public static let home = SharedCopy.activity
    public static func waitingPill(_ count: Int) -> String { SharedCopy.requestsWaiting(count) }
    public static let allQuiet = SharedCopy.noRequestsWaiting
    public static let waitingForYou = SharedCopy.waiting
    public static let inUse = "In use"
    public static let earlierToday = SharedCopy.today
    public static let nothingWaiting = SharedCopy.noRequestsWaiting
    public static let stop = "Stop"
    public static func until(_ date: Date) -> String { "until \(clock(date))" }
    /// Who asked, in a list: "Codex · Mac mini", or "Practice request".
    public static func who(_ request: AccessRequest) -> String {
        if request.isPractice { return practiceLabel }
        return request.agent.machine.isEmpty ? request.agent.name : "\(request.agent.name) · \(request.agent.machine)"
    }
    public static func inUseDetail(_ request: AccessRequest, until: Date) -> String { "\(who(request)) · \(self.until(until))" }
    public static func historyDetail(_ request: AccessRequest) -> String { "\(who(request)) · \(clock(request.askedAt))" }
    public static func outcome(_ state: AccessRequestState) -> (RequestHistoryOutcome, String) {
        switch state {
        case .approved, .expired, .released: (.approved, SharedCopy.approved)
        case .ended: (.approved, SharedCopy.ended)
        case .blockedByRule: (.denied, SharedCopy.ruleBlocked)
        case .denied: (.denied, SharedCopy.denied)
        case .sendingAnswer: (.noAnswer, SharedCopy.sending)
        case .waitingForMac: (.noAnswer, SharedCopy.waitingForMac)
        case .unanswered: (.noAnswer, SharedCopy.noAnswer)
        case .cancelled, .waitingForYou: (.noAnswer, SharedCopy.cancelled)
        }
    }
    public static let stillConnecting = "This iPhone is still connecting. Until it finishes, requests appear only while Agent Keyring is open."
    public static func notice(_ notice: PhoneNotice) -> String {
        switch notice {
        case .stillConnecting: stillConnecting
        case .iCloudSignedOut: iCloudSignedOut
        }
    }
    public static let stopNotConfirmed = "Stop was sent, but Agent Keyring couldn’t confirm it. Try again."
    public static func stopFailed(until: Date?) -> String {
        "Couldn’t stop it. Try again." + (until.map { " It ends by itself at \(clock($0))." } ?? "")
    }

    // MARK: Passwords

    public static let passwords = SharedCopy.passwords
    public static let categories = SharedCopy.categories
    public static let recentRequests = SharedCopy.recent
    public static let noRequestsForPassword = "No requests yet."
    public static let agentAccess = "Rule"
    public static let askLegend = "**Ask First:** you approve each time an agent wants it."
    public static let automaticLegend = "**Always Allowed:** agents on your agent computers get it without asking you."
    public static let blockedLegend = "**Blocked:** no agent can ever use it, and its password is deleted from Agent Keyring."
    public static let twoFactorLegend = "**Two-factor codes:** for Ask First passwords, the secret stays on your devices and agents get only the current code. For Always Allowed passwords, your agent computers hold their own encrypted copy."
    public static func passwordsCount(_ count: Int) -> String { "\(count.formatted()) passwords" }
    public static let search = "Search"
    public static let filter = "Show"
    public static let all = SharedCopy.all
    public static func ruleExplanation(_ rule: LoginRule) -> String {
        switch rule {
        case .ask: SharedCopy.ruleAskFirstShort
        case .automatic: SharedCopy.ruleAlwaysAllowedShort
        case .blocked: SharedCopy.ruleBlockedShort
        }
    }
    public static let changeFailed = "That change wasn’t saved. Try again."

    // MARK: Devices

    public static let devices = SharedCopy.devices
    public static let youApproveOn = SharedCopy.whereYouApprove
    public static let agentsAskFrom = SharedCopy.agentComputers
    public static let thisIPhone = "This iPhone"
    public static let connected = "Agents can ask"
    public static let agentComputersFooter = "Agents on these computers can ask for your passwords."
    public static let addAppleWatchRow = "Add Apple Watch"
    public static let practiceShort = "Send Practice Request"
    public static let remove = SharedCopy.remove
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

    public static let settings = SharedCopy.settings
    public static let timeSensitive = "Time Sensitive Notifications"
    public static let timeSensitiveDetail = "When on, requests are marked Time Sensitive, so Do Not Disturb, Sleep or Driving Focus lets them through if Time Sensitive Notifications are allowed in Settings > Focus."
    public static let quietHours = "Quiet Hours"
    public static let from = "From"
    public static let to = "To"
    public static let quietHoursDetail = "Overrides Time Sensitive Notifications during these hours so requests arrive silently in Notification Centre instead of waking you. Your Apple Watch follows these settings."
    public static let watchFollows = "Your Apple Watch follows these settings."
    public static let remindToUpdate = "Remind Me to Update Passwords"
    public static let remindToUpdateDetail = "One notification once your passwords from Apple Passwords are a week old, then none for a week."
    public static let anonymousTelemetry = SharedCopy.analyticsTitle
    public static let anonymousTelemetryDetail = SharedCopy.analyticsDetail
    public static let syncNow = "Sync Now"
    public static let syncingNow = "Syncing…"
    public static let resetApp = "Reset Agent Keyring…"
    public static let resetTitle = "Reset Agent Keyring?"
    public static let resetThisIPhone = "Reset This iPhone"
    public static let resetEverything = "Reset Everything (Including iCloud)"
    public static let resetDetail = "Reset This iPhone clears local data here and returns to setup. Reset Everything also deletes your Agent Keyring data from iCloud so you can start from scratch. Your passwords in Apple Passwords are not affected."
    public static let resetFailed = "Agent Keyring couldn’t finish resetting. Check your iCloud connection and try again."
    public static let iCloudSignedOut = "This iPhone isn’t signed in to iCloud, so your other devices don’t get changes made here."

    /// Under a password in the list: its account, and whether its password was deleted when it was blocked.
    public static func loginDetail(account: String, secretDeleted: Bool) -> String? {
        let deleted = MainWindowCopy.deletedWhenBlocked
        guard secretDeleted else { return account.isEmpty ? nil : account }
        return account.isEmpty ? deleted : account + "\n" + deleted
    }

    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: "en_GB")))
    }

}
