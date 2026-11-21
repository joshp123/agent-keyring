// Written by AI on 2026.10.31 by model Claude Opus 5.5; first run, the
// practice request, Passwords and Devices rewritten on 2026.11.19 by model
// claude opus 5.5; first run, the device sheets, the join card and sending
// changes rewritten on 2026.11.21 by the same model from the copy ledger of
// that day.
//
// Every sentence Josh reads on the Mac's setup screens, first run and the
// main window, so each is a one-line change. Requests are in AccessRequestCopy.

import Foundation

public enum SetupCopy {
    public static let appName = "Agent Keyring"
    public static let ok = "OK"
    public static let tryAgain = "Try again"
    /// The approve button outside the request panel.
    public static func touchIDTo(_ action: String) -> String { "Touch ID or Apple Watch to \(action)" }
    /// Under a joining device's name in the menu bar.
    public static func joiningDetail(_ enrolment: DeviceEnrolment) -> String {
        enrolment.kind == .machine ? "Wants its agents to ask for your passwords" : "Wants to approve requests"
    }

    public static let notNow = "Not Now"
    public static let allow = "Allow"
    /// A password set to Automatic on the iPhone: the computers get their copies only after Touch ID here.
    public static let automaticCopiesTitle = "Let your computers use the passwords you set to Automatic on your iPhone?"
    public static let automaticCopiesBody = "Agents on those computers keep asking for them until you allow this."
    public static let automaticCopiesReason = "let your computers use the passwords you set to Automatic"

    // MARK: Sending changes to the other devices, after a copy from Passwords

    public static func sendChangesTitle(_ total: Int) -> String {
        total == 1 ? "Send 1 password change to your other devices?" : "Send \(total.formatted()) password changes to your other devices?"
    }
    /// "You copied 12 new, 2 changed and 1 removed password from the Passwords app.", leaving out what is none.
    public static func sendChangesBody(added: Int, changed: Int, removed: Int) -> String {
        let counts = [added > 0 ? "\(added.formatted()) new" : nil, changed > 0 ? "\(changed.formatted()) changed" : nil, removed > 0 ? "\(removed.formatted()) removed" : nil]
        let what = added == 0 && changed == 0
            ? "You removed \(removed == 1 ? "1 password" : "\(removed.formatted()) passwords") from the Passwords app."
            : "You copied \(MainWindowCopy.list(counts.compactMap { $0 })) \(added + changed + removed == 1 ? "password" : "passwords") from the Passwords app."
        return what + " Confirm with Touch ID to update your other devices. If you choose Not Now, they keep your previous list until you update them."
    }
    /// After "Agent Keyring is trying to" in macOS's dialog.
    public static let sendChangesReason = "send your password changes to your other devices"

    // MARK: A computer or device asking to join (the card beside the window)

    public static let addIPhoneLead = "Add this iPhone to Agent Keyring?"
    public static let addWatchLead = "Add this Apple Watch to Agent Keyring?"
    public static let addComputerLead = "Add this computer to Agent Keyring?"
    public static let addIPhoneBody = "It gets its own encrypted copy of your passwords, locked in its Secure Enclave, and can approve password requests with Face ID."
    public static let addWatchBody = "It approves password requests with one tap on your wrist, and each request carries the one encrypted copy it needs."
    public static let addComputerBody = "Agents on this computer will be able to ask you for passwords. You approve each Ask password before it is shared."
    public static let denyNotePrompt = "Optional note if you deny"
    public static func copyingTo(done: Int, total: Int) -> String {
        "Copying your passwords to it: \(done.formatted()) of \(total.formatted()). You can remove it later in Devices."
    }
    public static func stoppedCopying(done: Int, total: Int, reason: String) -> String {
        "Stopped copying after \(done.formatted()) of \(total.formatted()) passwords. \(reason) Remove it in Devices and add it again."
    }
    public static func added(_ name: String) -> String { "\(name) added" }
    public static let addedPhoneDetail = "It can approve password requests with Face ID."
    public static func addedComputerDetail(_ name: String) -> String { "Agents on \(name) can now ask you for passwords." }
    public static func notAdded(_ name: String) -> String { "\(name) wasn’t added." }
}

/// Every sentence of the Mac's first run, from the copy ledger of 21 November
/// (Paper page "Agent Keyring (Holistic)", board 1).
public enum FirstRunCopy {
    public static let setupHeading = "Setup on this Mac"
    public static let steps = ["Try a request", "Copy passwords", "Connect an agent", "Ready"]
    public static let back = "Back"
    public static let continueButton = "Continue"

    // MARK: Welcome

    public static let title = "Welcome to Agent Keyring"
    public static let intro = "Your agents ask. You tap yes."
    public static let points: [(symbol: String, title: String, body: String)] = [
        ("lock.fill", "End-to-end encrypted, locked in Secure Enclave",
         "Your passwords stay encrypted with keys inside your devices’ Secure Enclave and signed against tampering. Nothing can open a password except an agent you approve, one at a time, with each approval lasting up to 30 minutes."),
        ("checkmark.shield.fill", "You approve every password request",
         "Approve on this Mac with Touch ID, on iPhone with Face ID, or on Apple Watch with one tap. Or deny and tell the agent what to do instead."),
        ("number.square.fill", "Two-factor codes included",
         "If the Passwords app holds a two-factor code for a website, an approved agent gets the current code too, while the secret stays on your devices for Ask passwords."),
    ]
    public static let getStarted = "Get Started"

    // MARK: Step 1 of 4: Try a password request

    public static let practiceTitle = "Try a password request"
    public static let practiceBody = "See how an AI agent asks for a password. This practice request doesn’t share any passwords."
    public static let practiceTrigger = "Click **Send Practice Request** to open a sample approval card beside this window."
    public static let sendPractice = "Send Practice Request"
    public static let sendAnother = "Send Another Practice Request"
    public static let howToApprove = "**Approve:** Click the green button, then use Touch ID."
    public static let howToDeny = "**Deny:** Click Deny, or type what the agent should do instead first."
    public static let youApproved = "You approved it"
    public static let youApprovedDetail = "A real agent would now have this password, with each approval lasting up to 30 minutes."
    public static let youDenied = "You denied it"
    public static let youDeniedDetail = "A real agent would be told no and carry on without the password."
    public static let youDeniedAndReplied = "You denied it and replied"
    public static func youDeniedAndRepliedDetail(_ reply: String) -> String { "A real agent would get your reply: “\(reply)”" }
    public static let lidClosed = "Open the lid to use Touch ID, then send the practice request."
    public static let needsFingerprint = "Touch ID isn’t set up on this Mac. Add a fingerprint in System Settings, then come back here."
    public static let openTouchIDSettings = "Open Touch ID Settings"

    // MARK: Step 2 of 4: Copy your passwords

    public static let copyTitle = "Copy your passwords"
    public static let copyBody = "Click Open Passwords below, then step through this 5-part guide at your own pace. Copying deletes nothing from Passwords."
    public static func guideStep(_ number: Int) -> String { "Guide step \(number) of 5" }
    /// Markdown: the menu items and buttons are in bold.
    public static let guide = [
        "In Passwords, choose **File > Export All Items to App…**",
        "Click **Continue** on Apple’s notice about passkeys, then **Continue** on **Export Passwords**.",
        "Unlock with Touch ID or your Mac password.",
        "In **Select a Destination**, choose **Agent Keyring** (blue keyhole), then click **Continue**.",
        "Click **Continue** in “Agent Keyring” on the final confirmation sheet.",
    ]
    public static let earlierVersion = "If you also see “AgentKeyring”, that is an earlier version. Don’t choose it."
    public static let previous = "Previous"
    public static let next = "Next"
    public static let notInList = "Agent Keyring isn’t in the list?"
    public static let openPasswords = "Open Passwords"
    public static let useTestPasswordOnly = "Use Test Password Only"
    public static let cancel = "Cancel"
    public static let noneArrived = "No passwords have arrived yet. In Select a Destination, make sure you chose Agent Keyring with the blue keyhole (not an earlier version), or check that Agent Keyring is turned on in AutoFill Settings."
    public static let copying = "Copying passwords…"
    public static func copied(_ count: Int) -> String {
        (count == 1 ? "1 password copied." : "\(count.formatted()) passwords copied.") + " Every password starts as Ask, so an agent must ask you before using it."
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
public enum DeviceSheetCopy {
    public static let addIPhoneTitle = "Add your iPhone"
    public static let addIPhoneBody = "Approve password requests from your AI agents with Face ID anywhere. Each password is end-to-end encrypted for your iPhone’s Secure Enclave and signed against tampering. Both devices need Tailscale turned on."
    /// TestFlight's page in the App Store: the code he scans.
    public static let testFlightLink = "https://apps.apple.com/app/testflight/id899247664"
    public static let addIPhoneSteps = [
        "Scan to get TestFlight from the App Store, then open Agent Keyring inside TestFlight.",
        "Make sure Tailscale is on for both devices, then tap **Connect** on your iPhone.",
        "Approve your iPhone beside this window with Touch ID.",
    ]
    public static let phoneNoTailscale = "Tailscale isn’t running on this Mac. Turn on Tailscale on your Mac and iPhone so they can connect."
    public static func approveBeside(_ name: String) -> String { "Approve \(name) beside this window with Touch ID." }
    public static func copyingTo(_ name: String, done: Int, total: Int) -> String { "Copying your passwords to \(name): \(done.formatted()) of \(total.formatted())." }
    public static let checkAgain = "Check Again"
    public static let doThisLater = "Do This Later"
    public static let done = "Done"

    public static let addComputerTitle = "Add another computer"
    public static let addComputerBody = "Send this note to an agent on a Linux server or another Mac on your Tailscale network. The invite works once, for 10 minutes, and you approve it beside this window with Touch ID."
    public static let computerNoTailscale = "Tailscale isn’t running on this Mac. Turn on Tailscale on both computers before creating an invite."
    public static func enrolCommand(_ link: String) -> String { "agent-keyring enrol --name \"$(hostname -s)\" --invite \"\(link)\"" }
    public static func enrolPrompt(_ command: String) -> String { "Connect this computer to Agent Keyring by running: \(command)" }
    public static let copyPrompt = "Copy Prompt for Agent"
    public static let copyCommand = "Copy Command"
    public static func worksUntil(_ time: String) -> String { "This invite works once, until \(time)." }
    public static let expired = "This invite expired. Create a new one to add another computer."
    public static let withdrawn = "Two computers tried to use this invite, so it was cancelled for safety. Create a new invite and try again."
    public static let createNewInvite = "Create New Invite"
}

/// The words of the main window: the Passwords and Devices tabs, from the
/// copy ledger of 21 November 2026 (section 3, "Every day"). Rewritten on
/// 2026.11.21 by model claude opus 5.5 for the direct design: no relay and no
/// computer that stays on.
public enum MainWindowCopy {
    public static let passwordsTab = "Passwords"
    public static let devicesTab = "Devices"

    // Passwords
    /// Each rule, then two-factor codes: one line each, as on the iPhone.
    public static let rulesExplained = [
        "**Ask:** you approve each time an agent wants it.",
        "**Automatic:** agents on the computers you choose get it without asking you.",
        "**Blocked:** no agent can ever use it.",
        "**Two-factor codes:** for Ask passwords, the secret stays on your devices and agents get only the current code. For Automatic passwords, the chosen computer holds its own encrypted copy.",
    ]
    public static func search(_ count: Int) -> String { count == 1 ? "Search 1 password" : "Search \(count.formatted()) passwords" }
    public static let all = "All"
    /// A filter with its count: "Ask 533".
    public static func filter(_ name: String, _ count: Int) -> String { "\(name) \(count.formatted())" }
    public static let website = "Website"
    public static let asked = "Asked"
    public static let approved = "Approved"
    public static let denied = "Denied"
    public static let rule = "Rule"
    /// The tag beside example.com, the password Agent Keyring always keeps.
    public static let testPassword = "Test password"
    public static func copiedOn(_ date: String) -> String { "Copied from the Passwords app on \(date)." }
    public static let noneCopied = "No passwords copied yet."
    public static let sampleOnly = "Only the example.com test password so far."
    public static let copyAgain = "Copy Again"
    public static let copyFromPasswords = "Copy from Passwords"

    // The bar shown while rules are changed, saved together with one Touch ID
    public static let cancel = "Cancel"
    public static let saveWithTouchID = "Save with Touch ID"
    public static let useTouchIDToSave = "Use Touch ID to save"
    public static func rulesChange(_ count: Int) -> String { "The rules for \(count.formatted()) passwords change." }
    public static func ruleChange(site: String, from: String, to: String) -> String { "\(site) changes from \(from) to \(to)." }
    public static let stillKnown = " An agent that has already received its password still knows it."
    /// Names every computer that will get the password without asking.
    public static func automaticTo(_ computers: [String], count: Int) -> String {
        " Agents on \(list(computers)) will get \(count == 1 ? "it" : "them") without asking."
    }
    public static let didNotFinish = "That didn't finish. Nothing changed."

    // Sort with AI
    public static let sortWithAI = "Sort with AI…"
    public static let sortTitle = "Sort your passwords with AI"
    public static let sortBody = "Copy a safe prompt for your AI agent with website names and account names only. No passwords or two-factor codes are included. Review every suggested rule before applying."
    public static let copyPrompt = "Copy Prompt"
    public static let promptCopied = "Copied"
    public static let applySuggestions = "Apply Suggestions…"
    /// After Copy Prompt: what to do with the agent's answer.
    public static let applyHow = "When your agent answers, copy its whole reply, then click Apply Suggestions. Nothing changes until you save with Touch ID."
    public static let noSuggestions = "No suggested changes found in what you copied. Copy the agent's whole reply, then try again."
    /// Not drawn: what Copy Prompt copies for an agent. Names only, never a password.
    public static func sortPrompt(_ rows: [(site: String, account: String, rule: String)]) -> String {
        "Help me choose a rule for each of my saved passwords in Agent Keyring. The rules: Ask (an agent asks me each time), "
            + "Automatic (agents on the computers I choose get it without asking) and Blocked (no agent can use it). Suggest Automatic only for low-risk sites "
            + "an agent of mine uses often, Blocked for banks, email, government and anything that can move money or reset other accounts, "
            + "and Ask for the rest. Reply with one line for each password whose rule you would change, and nothing else: "
            + "the website, a tab, the account, a tab, then Ask, Automatic or Blocked.\n\n"
            + rows.map { "\($0.site)\t\($0.account)\t\($0.rule)" }.joined(separator: "\n")
    }

    // Devices
    public static let addDevice = "Add Device…"
    public static let addIPhone = "Add iPhone…"
    public static let addComputer = "Add Another Computer…"
    public static let whereYouApprove = "Where you approve password requests"
    public static let otherComputers = "Other computers"
    public static func thisMacName(_ name: String) -> String { "\(name) (this Mac)" }
    public static let thisMac = "This Mac"
    /// In a sentence: "Agents on this Mac and Mac mini".
    public static let thisMacInSentence = "this Mac"
    public static let macAnswers = "Approves with Touch ID"
    public static let phoneAnswers = "Approves with Face ID"
    public static let watchAnswers = "Approves with one tap · added on your iPhone"
    public static let noOtherComputers = "Let agents on a Linux server or another Mac ask too."
    public static let sendPractice = "Send Practice Request"
    // A practice request on its way, step by step.
    public static let practiceSending = "Sending…"
    public static let practiceWithApple = "With Apple"
    public static let practiceOnPhone = "On your iPhone, waiting for your answer"
    public static let practiceOnWatch = "On your Apple Watch, waiting for your answer"
    public static let practiceHere = "Beside this window, waiting for your answer"
    public static let practiceApproved = "Approved"
    public static let practiceDenied = "Denied"
    public static let practiceNoAnswer = "No answer"
    public static let remove = "Remove…"
    public static func removeTitle(_ name: String) -> String { "Remove \(name)?" }
    public static func removeDevice(_ name: String) -> String { "\(name) will no longer receive password requests or hold copies of your passwords." }
    public static func removeComputer(_ name: String) -> String {
        "Agents on \(name) will no longer be able to ask for your passwords, and it no longer gets copies of your Automatic passwords."
    }
    public static let removeConfirm = "Remove"
    /// The door could not be opened, such as when another program holds its port.
    /// After Not Now on sending changes: the changes the other devices have not been sent.
    public static func unsentChanges(_ count: Int) -> String {
        count == 1 ? "1 password change isn’t on your other devices yet" : "\(count.formatted()) password changes aren’t on your other devices yet"
    }
    public static let unsentChangesDetail = "They keep your previous list until you send the changes."
    public static let sendUpdates = "Send Updates…"
    public static let doorFailed = "Agent Keyring couldn't open its connection for your other devices. It tries again every 10 seconds."

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
