// Written by AI on 2026.10.31 by model Claude Opus 5.5; first run, the
// practice request, Passwords and Devices rewritten on 2026.11.19 by model
// claude opus 5.5; first run, the device sheets, the join card and sending
// changes rewritten on 2026.11.21 by the same model from the copy ledger of
// that day.
//
// Every sentence Josh reads on the Mac's setup screens, first run and the
// main window, so each is a one-line change. Requests are in AccessRequestCopy.

import AgentKeyringApprovalCore
import Foundation

public enum SetupCopy {
    public static let appName = "Agent Keyring"
    /// How Josh approves on this Mac, in a sentence: "Touch ID", or "your Mac password" on a Mac that approves with it.
    public static func approveWith(_ mode: MacApprovalMode = .current) -> String {
        mode == .devicePassword ? "your Mac password" : "Touch ID"
    }
    public static let ok = "OK"
    public static let tryAgain = "Try again"
    /// Under a joining device's name in the menu bar.
    public static func joiningDetail(_ enrolment: DeviceEnrolment) -> String {
        enrolment.kind == .machine ? "Wants its agents to ask for your passwords" : "Wants to approve requests"
    }

    public static let notNow = "Not Now"
    public static let allow = "Allow"
    /// A password set to Always Allowed on the iPhone: the computers get their copies only after Touch ID here.
    public static let automaticCopiesLead = "Changed on your iPhone"
    public static let automaticCopiesTitle = "Let your computers use the passwords you set to Always Allowed on your iPhone?"
    public static let automaticCopiesBody = "Agents on those computers keep asking for them until you allow this."
    public static let automaticCopiesReason = "let your computers use the passwords you set to Always Allowed"

    // MARK: A computer or device asking to join (the card beside the window)

    public static let addIPhoneLead = "Add this iPhone to Agent Keyring?"
    public static let addWatchLead = "Add this Apple Watch to Agent Keyring?"
    public static let addComputerLead = "Add this computer to Agent Keyring?"
    public static let addIPhoneBody = "It gets its own encrypted copy of your passwords, locked in its Secure Enclave, and can approve password requests with Face ID."
    public static let addWatchBody = "It approves password requests with one tap on your wrist, and each request carries the one encrypted copy it needs."
    public static let addComputerBody = "Agents on this computer will get your Always Allowed passwords right away, and can ask you for Ask First passwords."
    public static let denyNotePrompt = "Optional note if you deny"
    public static func copyingTo(done: Int, total: Int) -> String {
        "Copying your passwords to it: \(done.formatted()) of \(total.formatted()). You can remove it later in Devices."
    }
    public static func stoppedCopying(done: Int, total: Int, reason: String) -> String {
        "Stopped copying after \(done.formatted()) of \(total.formatted()) passwords. \(reason) Remove it in Devices and add it again."
    }
    public static func added(_ name: String) -> String { "\(name) added" }
    public static let addedPhoneDetail = "It can approve password requests with Face ID."
    public static func addedPhoneDetail(count: Int) -> String {
        count > 0 ? "\(count.formatted()) passwords copied. It can approve password requests with Face ID." : addedPhoneDetail
    }
    public static func addedComputerDetail(_ name: String) -> String { "Agents on \(name) can now ask you for passwords." }
    public static func notAdded(_ name: String) -> String { "\(name) wasn’t added." }
}

/// Before first run, on a Mac with no keys yet and no Touch ID: how this Mac
/// is used. Written by AI on 2026.11.23 by model claude opus 5.5.
public enum ThisMacCopy {
    public static let quit = "Quit Agent Keyring"
    public static let back = "Back"

    // MARK: How do you use this Mac?

    public static let askTitle = "How do you use this Mac?"
    public static let askBody = "This Mac doesn’t have Touch ID. Choose how you use it so your passwords stay on a device you approve on."
    public static let forAgents = "A Mac for agents"
    public static let forAgentsDetail = "Best for a Mac mini or Mac Studio that runs your agents. You’ll approve requests on your personal Mac, iPhone or Apple Watch."
    public static let personalMac = "My personal Mac where I add passwords"
    public static let personalMacDetail = "Keep your passwords on this Mac and approve requests with your Mac password."
    public static let choose = "Continue"

    // MARK: A Mac for agents

    public static let forAgentsTitle = "Set up this Mac for agents"
    public static let forAgentsBody = "Keep your passwords on your personal Mac or iPhone. Agents here ask for them using the agent-keyring command."
    public static let agentSetupSteps = [
        "Open Agent Keyring on your personal Mac or iPhone, go to Devices, and choose Add Agent Computer.",
        "Copy the prompt below and give it to an agent on this Mac to install the command and connect this computer.",
        "Once connected, you can quit and remove this Mac app here.",
    ]
    public static let installLabel = "1. Install the command on this Mac"
    /// Copied as is: the standalone command, checked against the release's checksums before it is
    /// installed, in a folder of its own that is deleted after.
    public static let installCommand = "(d=\"$(mktemp -d)\" && trap 'rm -r \"$d\"' EXIT && cd \"$d\" && curl -fsSLO https://github.com/opentrawl/agent-keyring/releases/latest/download/agent-keyring-darwin-universal && curl -fsSLO https://github.com/opentrawl/agent-keyring/releases/latest/download/SHA256SUMS.txt && grep '  agent-keyring-darwin-universal$' SHA256SUMS.txt | shasum -a 256 -c && mkdir -p ~/.local/bin && install -m 755 agent-keyring-darwin-universal ~/.local/bin/agent-keyring && echo \"Installed ~/.local/bin/agent-keyring\")"
    public static let installPrompt = "Set up this Mac as an Agent Keyring computer for agents, following https://keyring.opentrawl.sh/llms.txt. Install only the agent-keyring command, not the Mac app. Ask me before you change anything."
    public static let addLabel = "2. Add this Mac from your Mac or iPhone"
    public static let addSteps = "In Agent Keyring on your Mac or iPhone, choose Devices, then Add Agent Computer, and give the code to an agent here."
    public static let notNeeded = "You don’t need this app here once connected. Quit it and move it to the Bin."

    // MARK: My personal Mac

    public static let personalTitle = "Approve with your Mac password"
    public static let personalBody = "Your passwords stay locked by this Mac’s Secure Enclave, and macOS asks for your Mac password before any agent gets one you approve. A typed password is weaker than Touch ID or Face ID: an agent or tool that knows your Mac login password, for example from a sudo prompt, could approve its own requests."
    public static let touchIDLater = "If you add a Magic Keyboard with Touch ID or an Apple Watch later, macOS accepts those too, and your Mac password still works."
    public static let usePassword = "Use My Mac Password"

    // MARK: No Secure Enclave

    public static let noChipTitle = "This Mac can’t keep your passwords"
    public static let noChipBody = "It has no Secure Enclave, the chip that locks passwords to one device. Agents here can still ask for passwords with the agent-keyring command."

    // MARK: Keys that could not be read or made

    public static let keysFailedTitle = "Agent Keyring can’t start on this Mac"
    public static let tryAgain = "Try Again"
}

/// Every sentence of the Mac's first run, from the copy ledger of 21 November
/// (Paper page "Agent Keyring (Holistic)", board 1).
public enum FirstRunCopy {
    public static let setupHeading = "Setup on this Mac"
    public static let steps = ["Try a request", "Privacy", "Add passwords", "Connect an agent", "Ready"]
    public static let back = "Back"
    public static let continueButton = "Continue"

    // MARK: Welcome

    public static let title = "Welcome to Agent Keyring"
    public static let intro = "Let AI agents sign in to websites only when you say yes."
    public static func points(_ mode: MacApprovalMode = .current) -> [(symbol: String, title: String, body: String)] { [
        ("checkmark.circle.fill", "You choose which passwords to add",
         "Start with a single password or pick categories from Apple Passwords. Banking, crypto and government sites are excluded by default."),
        ("checkmark.shield.fill", "You approve requests on your devices",
         "Approve on this Mac with \(SetupCopy.approveWith(mode)), on iPhone with Face ID, or on Apple Watch with one tap. Or deny and reply to the agent."),
        ("lock.fill", "Encrypted on your devices, never on our servers",
         "Your passwords stay locked in your devices’ Secure Enclave and sync only through your own iCloud. Two-factor codes are included."),
    ] }
    public static let getStarted = "Get Started"

    // MARK: Welcome, when Agent Keyring is already set up on his iPhone

    /// The iPhone as a sentence says it: its name is only "iPhone" unless he renamed it.
    static func phone(_ name: String) -> String { name == "iPhone" ? "your iPhone" : name }
    static func phoneAtStart(_ name: String) -> String { name == "iPhone" ? "Your iPhone" : name }
    public static func continueFrom(_ name: String) -> String { "Continue setup from \(phone(name))" }
    public static func continueFromDetail(_ name: String, mode: MacApprovalMode = .current) -> String {
        "This Mac found Agent Keyring on \(phone(name)) through your iCloud Keychain. Connect to keep the same passwords here and approve requests with \(SetupCopy.approveWith(mode))."
    }
    public static func connectTo(_ name: String) -> String { "Connect to \(phone(name))" }
    public static let setUpHere = "Set Up on This Mac"
    public static let trustTitle = "End-to-end encrypted and signed"
    public static func trustDetail(_ name: String) -> String {
        "\(phoneAtStart(name)) encrypts a copy of your passwords for this Mac’s Secure Enclave and signs it against tampering, so nothing in between can read or change them."
    }
    public static func approveOn(_ name: String) -> String { "Approve on \(phone(name))" }
    public static func approveOnDetail(_ name: String) -> String { "Open Agent Keyring on \(phone(name)), then add this Mac and confirm." }
    public static func waitingFor(_ name: String) -> String { "Waiting for \(phone(name))" }
    public static func notAddedOn(_ name: String) -> String { "Not added on \(phone(name))" }
    public static let notAddedDetail = "This Mac wasn’t added. You can ask again when you’re ready."
    public static let askAgain = "Ask Again"
    public static func connectedTo(_ name: String) -> String { "Connected to \(phone(name))" }
    public static func connectedDetail(_ name: String) -> String { "Your passwords are arriving from \(phone(name)). Next, try a password request on this Mac." }

    // MARK: Step 1 of 4: Try a password request

    public static let practiceTitle = "Try a password request"
    public static let practiceBody = "See how an AI agent asks for a password. This practice request doesn’t share any passwords."
    public static let practiceTrigger = "Click **Send Practice Request** to open a sample approval card beside this window."
    public static let sendPractice = "Send Practice Request"
    public static let sendAnother = "Send Another Practice Request"
    public static func howToApprove(_ mode: MacApprovalMode = .current) -> String {
        mode == .devicePassword ? "**Approve:** Click the green button, then enter your Mac password." : "**Approve:** Click the green button, then use Touch ID."
    }
    public static let howToDeny = "**Deny:** Click Deny, or type what the agent should do instead first."
    public static let youApproved = "You approved it"
    public static let youApprovedDetail = "A real agent would now have this password for this task."
    public static let youDenied = "You denied it"
    public static let youDeniedDetail = "A real agent would be told no and carry on without the password."
    public static let youDeniedAndReplied = "You denied it and replied"
    public static func youDeniedAndRepliedDetail(_ reply: String) -> String { "A real agent would get your reply: “\(reply)”" }
    public static let lidClosed = "Open the lid to use Touch ID, then send the practice request."
    public static let touchIDMissing = "Touch ID isn’t connected. Connect your Magic Keyboard with Touch ID, then come back here."
    public static let needsFingerprint = "Touch ID isn’t set up on this Mac. Add a fingerprint in System Settings, then come back here."
    public static let openTouchIDSettings = "Open Touch ID Settings"

    // MARK: Step 2 of 4: Copy your passwords

    public static let copyTitle = "Copy your passwords"
    public static let copyBody = "Start with 1 or 2 logins from Passwords, or export all. You can add more later; nothing is deleted from Passwords."
    /// Copy Again, once other devices hold the list: what happens when the copy arrives.
    public static func copyAgainBody(_ mode: MacApprovalMode = .current) -> String {
        copyBody + " When the copy arrives, confirm with \(SetupCopy.approveWith(mode)) to update your other devices."
    }
    public static func guideStep(_ number: Int) -> String { "Guide step \(number) of 5" }
    /// Markdown: the menu items and buttons are in bold.
    public static let guide = [
        "Select 1 or 2 logins in Passwords and choose **File > Export Selected Items to App…** (or **Export All…**).",
        "If Passwords says some items will not be exported, click **Continue**, then click **Continue** on **Export Passwords**.",
        "Unlock with Touch ID or your Mac password.",
        "In **Select a Destination**, choose **Agent Keyring** (blue keyhole), then click **Continue**.",
        "Click **Continue in “Agent Keyring”** on the final confirmation sheet.",
    ]
    public static let previous = "Previous"
    public static let next = "Next"
    public static let notInList = "Agent Keyring isn’t in the list?"
    public static let openPasswords = "Open Passwords"
    public static let useTestPasswordOnly = "Use Test Password Only"
    public static let cancel = "Cancel"
    public static let noneArrived = "No passwords have arrived yet. In Select a Destination, make sure you chose Agent Keyring with the blue keyhole (not an earlier version), or check that Agent Keyring is turned on in AutoFill Settings."
    public static let copying = "Copying passwords…"
    public static func copiedHeadline(_ count: Int) -> String {
        count == 1 ? "1 password copied." : "\(count.formatted()) passwords copied."
    }
    public static let copiedDetail = "Every password starts as Ask first, so an agent must ask you before using it."
    /// A Mac that joined another device's list: its passwords came from there.
    public static func syncedHeadline(_ count: Int, from name: String) -> String {
        count == 0 ? "No passwords on \(phone(name)) yet." : count == 1 ? "1 password arrived from \(phone(name))."
            : "\(count.formatted()) passwords arrived from \(phone(name))."
    }
    public static func syncedDetail(_ count: Int) -> String {
        count == 0 ? "Passwords you copy on any of your devices appear here too." : "They keep the rules you set there."
    }
    public static func copied(_ count: Int) -> String {
        copiedHeadline(count) + " " + copiedDetail
    }
    public static let allowExportTitle = "Allow export from Apple Passwords"
    public static let allowExportBody = "macOS uses its AutoFill setting to choose which apps Apple Passwords can export to. Agent Keyring never fills in passwords on its own. Click Open AutoFill Settings, turn on Agent Keyring, then return here."
    public static let openAutoFillSettings = "Open AutoFill Settings"

    // MARK: Step 3 of 4: Connect an agent

    public static let connectTitle = "Connect an agent"
    public static let connectBody = "Give your AI agent this instruction so it knows how to ask Agent Keyring for passwords and two-factor codes."
    public static let instructionLabel = "1. Add to AGENTS.md or CLAUDE.md"
    public static func agentNote(appPath: String) -> String {
        "When a task needs a website password or a two-factor code, use Agent Keyring. To learn how, run \"\(appPath)/Contents/Helpers/agent-keyring\" skill"
    }
    public static var agentNote: String { agentNote(appPath: Bundle.main.bundleURL.path) }
    public static let tryItLabel = "2. Try it: send this to an agent"
    public static let tryItText = "Use Agent Keyring to get the test password for example.com."
    public static let whatToExpect = "**What to expect:** When your agent asks for a password, an approval card pops up beside this window."
    public static func agentWorked(_ agent: String) -> String { "\(agent) got the password. You’re connected." }
    public static func agentDenied(_ agent: String) -> String { "You denied \(agent)’s request. Your connection works." }
    public static let skipTest = "Skip the Test"

    // MARK: Step 4 of 4: Ready

    public static let ready = "Agent Keyring is ready on this Mac"
    public static func readyCopied(_ count: Int) -> String {
        (count == 1 ? "1 password copied." : "\(count.formatted()) passwords copied.") + " Click the keyhole in your menu bar any time."
    }
    public static let readyTestOnly = "Ready with the example.com test password. Click the keyhole in your menu bar any time."
    public static let otherDevices = "Add your other devices (optional, or later in the Devices tab)"
    public static let iPhone = "iPhone"
    public static let iPhoneDetail = "Approve password requests with Face ID anywhere."
    public static let watch = "Apple Watch"
    public static let watchDetail = "Approve with one tap on your wrist. Added from your iPhone."
    public static let computers = "Other Computers"
    public static let computersDetail = "Let agents on a Linux server or another Mac ask too."
    public static func added(_ names: [String]) -> String { MainWindowCopy.list(names) + " added." }
    /// Under a row whose title is already the device's name: "iPhone", then "Added."
    public static func added(_ name: String, under title: String) -> String { name == title ? "Added." : added([name]) }
    public static let addButton = "Add…"
    public static let showPasswords = "Show Passwords"
    /// Under the menu bar icon after Show Passwords.
    public static let staysHere = "Agent Keyring stays here."

    // MARK: The practice request in the card

    public static let practiceAgent = "Agent Keyring"
    public static let practiceWants = "Practice request: an agent wants"
    public static let practiceSite = "example.com"
    public static let practiceAccount = "you@example.com"
    public static let practiceReason = "You asked me to download October’s invoice."
    public static let practiceReplyPrompt = "What should the agent do instead?"
    public static let practiceFooter = "Practice only. No passwords are shared."
    public static let practiceApproved = "No real password was used."

    // MARK: A practice request on another device, in Devices: only what is known

    public static let practiceSending = "Sending…"
    public static func practiceWithApple(_ time: String) -> String { "With Apple since \(time). On its way to the device." }
    public static func practiceOnWrist(_ time: String) -> String { "On your Apple Watch since \(time). Raise your wrist to answer." }
    public static func practiceOnPhone(_ time: String) -> String { "On your iPhone since \(time). Answer it there." }
    public static let practiceSentHere = "Sent. Answer it beside your pointer."
    public static let practiceUnanswered = "No answer within 10 minutes."
    public static func practiceApprovedAt(_ time: String, touchID: Bool) -> String { touchID ? "Approved with Touch ID at \(time)" : "Approved at \(time)" }
    public static func practiceDeniedAt(_ time: String, reply: String) -> String { reply.isEmpty ? "Denied at \(time)" : "Denied at \(time): “\(reply)”" }
}

/// The sheets that add a device, from Ready and from Devices (board 2).
extension DeviceSheetCopy {
    public static let addIPhoneTitle = "Add your iPhone"
    public static let addIPhoneBody = "Approve password requests from your AI agents with Face ID anywhere. Your Mac and iPhone find each other through your own iCloud Keychain. Each password is end-to-end encrypted for your iPhone’s Secure Enclave and signed against tampering."
    /// Agent Keyring's public TestFlight beta link: the code he scans.
    public static let testFlightLink = "https://testflight.apple.com/join/W5xBNeMw"
    public static var addIPhoneSteps: [String] { [
        "Scan to open the beta link: install TestFlight, then join the Agent Keyring beta.",
        "Open Agent Keyring and tap **Connect** on your iPhone.",
        "Approve your iPhone beside this window with \(SetupCopy.approveWith()).",
    ] }
    public static let phoneNoICloud = "This Mac can’t reach your iCloud right now, so your iPhone can’t find it. Check that this Mac is signed in to iCloud in System Settings, then click Check Again."
    public static func approveBeside(_ name: String) -> String { "Approve \(name) beside this window with \(SetupCopy.approveWith())." }
    public static func copyingTo(_ name: String, done: Int, total: Int) -> String { "Copying your passwords to \(name): \(done.formatted()) of \(total.formatted())." }
    public static let checkAgain = "Check Again"
    public static let doThisLater = "Do This Later"
    public static let done = "Done"

    public static let addComputerTitle = "Add another computer"
    public static var addComputerBody: String {
        "Send this note to an agent on a Linux server, a cloud computer or another Mac. The code works once, for 10 minutes, and you approve it beside this window with \(SetupCopy.approveWith())."
    }
    public static func enrolPrompt(_ command: String) -> String { "Connect this computer to Agent Keyring by running: \(command)" }
    public static let copyPrompt = "Copy Prompt for Agent"
    public static let copyCommand = "Copy Command"
    public static func worksUntil(_ time: String) -> String { "This code works once, until \(time)." }
    public static let expired = "This code expired. Create a new one to add another computer."
    public static let withdrawn = "Two computers tried to use this code, so it was cancelled for safety. Create a new code and try again."
    public static let createNewInvite = "Create New Code"
}

/// The words of the main window: the Passwords and Devices tabs, from the
/// copy ledger of 21 November 2026 (section 3, "Every day"). Rewritten on
/// 2026.11.21 by model claude opus 5.5 for the direct design: no relay and no
/// computer that stays on.
public enum MainWindowCopy {
    public static let activityTab = SharedCopy.activity
    public static let passwordsTab = SharedCopy.passwords
    public static let devicesTab = SharedCopy.devices
    public static let categoriesSection = SharedCopy.categories
    public static let noActivityYet = SharedCopy.noRequestsWaiting
    public static let inspectorEmptyTitle = "Select a password"
    public static let inspectorEmptyDetail = "Choose a password to change its rule or see recent requests."
    public static let recentRequests = SharedCopy.recent
    public static let noRequestsForPassword = "No requests yet."
    public static let stagedRuleNote = "Unsaved rule change"
    public static let timeColumn = "Time"
    public static let agentColumn = "Agent"
    public static let reasonColumn = "Reason"
    public static let outcomeColumn = "Outcome"

    // Passwords
    /// Each rule, then two-factor codes: one line each, as on the iPhone.
    public static let rulesExplained = [
        "**Ask First:** you approve each request.",
        "**Always Allowed:** agents on your agent computers get it without asking.",
        "**Blocked:** no agent can use it. Its copy here is deleted.",
        "**Two-factor codes:** for Ask First passwords, the secret stays on your devices and agents get only the current code. For Always Allowed passwords, your agent computers hold their own encrypted copy.",
    ]
    public static func ruleExplanation(_ rule: LoginRule) -> String { rule.hint }
    public static func search(_ count: Int) -> String { count == 1 ? "Search 1 password" : "Search \(count.formatted()) passwords" }
    public static let all = SharedCopy.all
    /// A filter with its count: "Ask First 533".
    public static func filter(_ name: String, _ count: Int) -> String { "\(name) \(count.formatted())" }
    public static let website = "Website"
    public static let asked = "Asked"
    public static let approved = SharedCopy.approved
    public static let denied = SharedCopy.denied
    public static let rule = "Rule"
    /// The tag beside example.com, the password Agent Keyring always keeps.
    public static let testPassword = "Test password"
    /// Under a password whose secret was deleted when it was blocked, since unblocked (iPhone).
    public static let deletedWhenBlocked = "Deleted when blocked. Update from Apple Passwords to use it."
    /// The tag beside such a password in the Mac's table.
    public static let deletedTag = "Deleted when blocked"
    /// Added to the sentence for unblocking a password whose secret was deleted.
    public static let unblockNeedsCopy = " Its password was deleted when it was blocked: update from Apple Passwords to use it."
    public static let unblockNeedsCopyMany = " Passwords deleted when they were blocked stay deleted: update from Apple Passwords to use them."
    public static func copiedOn(_ date: String) -> String { "Added from Apple Passwords on \(date)" }
    /// The same, once the copy is over a week old.
    public static func copiedOnStale(_ date: String) -> String { "Added from Apple Passwords on \(date) · Update for changes" }
    public static let remindToUpdate = "Remind me to update passwords"
    public static let remindToUpdateDetail = "One notification once your passwords from Apple Passwords are a week old, then none for a week."
    public static let openAtLogin = "Open at Login"
    public static let openAtLoginDetail = "Start Agent Keyring in your menu bar when you sign in to this Mac."
    public static let anonymousTelemetry = SharedCopy.analyticsTitle
    public static let anonymousTelemetryDetail = SharedCopy.analyticsDetail
    public static let syncTitle = "Sync with iCloud"
    public static let syncNow = "Sync Now"
    public static let syncNowDetail = "Fetch the latest rules, devices and passwords from your own iCloud."
    public static let resetAppTitle = "Reset Agent Keyring"
    public static let resetApp = "Reset…"
    public static let resetAppDetail = "Clears Agent Keyring data on this Mac (or in iCloud too) and returns to setup. Your passwords in Apple Passwords are not affected."
    public static let resetTitle = "Reset Agent Keyring?"
    public static let resetThisMac = "Reset This Mac"
    public static let resetEverything = "Reset Everything (Including iCloud)"
    public static let resetMessage = "Reset This Mac clears local data here and returns to setup. Reset Everything also deletes your Agent Keyring data from iCloud so you can start from scratch. Reset other devices before setting up again so they don’t push old data back to iCloud."
    public static let resetFailed = "Agent Keyring couldn’t finish resetting. Check your iCloud connection and try again."
    public static let noneCopied = "No passwords added from Apple Passwords yet."
    /// After a copy that brought nothing new.
    public static func copiedNoChanges(_ date: String) -> String { "Updated from Apple Passwords on \(date) · No changes" }
    public static let sampleOnly = "Test password only"
    public static let copyAgain = "Update from Apple Passwords…"
    public static let copyFromPasswords = "Add from Apple Passwords…"
    public static let addPassword = "Add Manually…"
    public static let toggleInspector = "Toggle Inspector"

    // The bar shown while rules are changed, saved together with one approval
    public static let cancel = SharedCopy.cancel
    public static var saveWithTouchID: String { MacApprovalMode.current == .devicePassword ? "Save with Mac Password" : "Save with Touch ID" }
    public static var useTouchIDToSave: String {
        MacApprovalMode.current == .devicePassword ? "Enter Mac password…" : "Use Touch ID…"
    }
    public static func rulesChange(_ count: Int) -> String { "Change rules for \(count.formatted()) passwords." }
    public static func ruleChange(site: String, from: String, to: String) -> String { "\(site): \(from) → \(to)." }
    public static let stillKnown = " Agents that already received it still have it."
    /// Names every computer that will get the password without asking once saved.
    public static func automaticTo(_ computers: [String], count: Int) -> String {
        " Will send to \(list(computers))."
    }
    public static let didNotFinish = "That didn’t finish. Nothing changed."

    // Bulk rule review with your own agent
    public static let sortWithAI = "Review Rules with Agent…"
    public static let sortTitle = "Review password rules with your agent"
    public static let sortBody = "Contains website and account names only. Never passwords or two-factor codes."
    public static let copyPrompt = "Copy Prompt"
    public static let promptCopied = "Prompt Copied"
    public static let applySuggestions = "Preview Changes"
    public static let pasteReplyPlaceholder = "Paste your agent’s reply here"
    /// After Copy Prompt: what to do with the agent's answer.
    public static var applyHow: String {
        "1. Copy the prompt and send it to your AI agent.\n2. Paste the reply below, then click Preview Changes.\n3. Check the changes in the table, then save with \(SetupCopy.approveWith())."
    }
    public static let noSuggestions = "No suggested rule changes were found. Paste your agent’s whole reply, then try again."
    /// Not drawn: what Copy Prompt copies for an agent. Names only, never a password.
    public static func sortPrompt(_ rows: [(site: String, account: String, rule: String)]) -> String {
        "Help me choose a rule for each of my saved passwords in Agent Keyring. The rules: Ask First (you approve each request), "
            + "Always Allowed (agents get it without asking) and Blocked (no agent can use it). Suggest Always Allowed only for low-risk sites "
            + "an agent of mine uses often, Blocked for banks, email, government and anything that can move money or reset other accounts, "
            + "and Ask First for the rest. Reply with one line for each password whose rule you would change, and nothing else: "
            + "the website, a tab, the account, a tab, then Ask First, Always Allowed or Blocked.\n\n"
            + rows.map { "\($0.site)\t\($0.account)\t\($0.rule)" }.joined(separator: "\n")
    }

    // Devices
    public static let addDevice = "Add Device…"
    public static let addIPhone = "Add iPhone…"
    public static let addComputer = "Add Agent Computer…"
    public static let whereYouApprove = SharedCopy.whereYouApprove
    public static let otherComputers = SharedCopy.agentComputers
    public static func thisMacName(_ name: String) -> String { "\(name) (this Mac)" }
    public static let thisMac = "This Mac"
    /// In a sentence: "Agents on this Mac and Mac mini".
    public static let thisMacInSentence = "this Mac"
    public static var macAnswers: String { MacApprovalMode.current == .devicePassword ? "Use Mac password to approve" : "Use Touch ID to approve" }
    public static let phoneAnswers = "Use Face ID to approve"
    public static let watchAnswers = "Tap to approve"
    /// Another Mac: Touch ID, or its password if it has none; this Mac isn't told which.
    public static let otherMacAnswers = "Use Touch ID or password to approve"
    public static let noOtherComputers = "Add a Linux server, cloud VM, or another Mac so agents there can ask for passwords."
    public static let sendPractice = "Send Practice Request"
    // A practice request on its way, step by step.
    public static let practiceSending = "Sending…"
    /// Apple took the practice request for the device: it is there, waiting for him.
    static func practiceSent(toWatch: Bool) -> String {
        "Sent to your \(toWatch ? "Apple Watch" : "iPhone"), waiting for your answer"
    }
    public static let practiceHere = "Beside this window, waiting for your answer"
    public static let practiceApproved = "Practice request: Approved"
    public static let practiceDenied = "Practice request: Denied"
    public static let practiceNoAnswer = "Practice request: No answer"
    public static let settingsTitle = "Settings…"
    public static let settingsFooterDetail = "Open at login, analytics, sync and reset."
    public static let moreActions = "More actions"
    public static let remove = "Remove…"
    public static let rename = "Rename…"
    public static let renameTitle = "Rename device"
    public static let renameField = "Device name"
    public static let save = "Save"
    public static func removeTitle(_ name: String) -> String { "Remove \(name)?" }
    public static func removeDevice(_ name: String) -> String { "\(name) will no longer receive password requests or hold copies of your passwords." }
    /// A Mac that approves and whose agents also ask: one Remove takes both.
    public static func removeMac(_ name: String) -> String {
        "\(name) will no longer receive password requests or hold copies of your passwords, and agents on it can no longer ask."
    }
    public static func removeComputer(_ name: String) -> String {
        "Agents on \(name) will no longer be able to ask for your passwords, and it no longer gets copies of your Always Allowed passwords."
    }
    public static let removeConfirm = "Remove"
    /// After Not Now on sending changes: the changes the other devices have not been sent.
    public static func unsentChanges(_ count: Int) -> String {
        count == 1 ? "1 password change isn’t on your other devices yet" : "\(count.formatted()) password changes aren’t on your other devices yet"
    }
    public static let unsentChangesDetail = "They keep your previous list until you send the changes."
    public static let sendUpdates = "Send Updates…"

    // macOS's dialog, after "Agent Keyring is trying to" (page "The request", board "On the Mac").
    /// Making one password Automatic, naming every computer that will get it.
    public static func automaticReason(_ computers: [String], site: String) -> String {
        "let agents on \(list(computers)) use your \(site) password without asking"
    }
    public static func automaticReason(_ computers: [String], count: Int) -> String {
        "let agents on \(list(computers)) use \(count.formatted()) passwords without asking"
    }
    public static func changeReason(site: String, from: String, to: String) -> String { "change \(site) from \(from) to \(to)" }
    public static func changeReason(count: Int) -> String { "change the rules for \(count.formatted()) passwords" }

    /// "a", "a and b", "a, b and c".
    public static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
