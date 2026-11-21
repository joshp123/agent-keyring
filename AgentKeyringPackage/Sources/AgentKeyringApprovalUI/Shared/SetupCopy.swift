// Written by AI on 2026.10.31 by model Claude Opus 5.5; first run, the
// practice request, Passwords and Devices rewritten on 2026.11.19 by model
// claude opus 5.5 from the Paper boards "First run", "Passwords and rules"
// and "Devices" (page "First run and the app").
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

    public static let notNow = "Not now"
    public static let allow = "Allow"
    public static let sendImportedTitle = "Let agents on your other computers use the passwords you just copied?"
    public static let sendImportedBody = "Until you allow this, they can only use the list you had before."
    /// After "Agent Keyring is trying to" in macOS's dialog.
    public static let sendImportedReason = "let agents on your other computers use the passwords you just copied"
    /// A password set to Automatic on the iPhone: the computers get their copies only after Touch ID here.
    public static let automaticCopiesTitle = "Let your computers use the passwords you set to Automatic on your iPhone?"
    public static let automaticCopiesBody = "Agents on those computers keep asking for them until you allow this."
    public static let automaticCopiesReason = "let your computers use the passwords you set to Automatic"

    // MARK: A computer or device being added (the request panel)

    public static func addingComputerLead(agent: String) -> String { "\(agent) on this Mac wants to add" }
    /// A computer joining with a link from `agent-keyring invite`: the agent's name is not known.
    public static let addingLead = "Add to Agent Keyring"
    public static func addingComputerFooter(_ name: String, staysOn: Bool) -> String {
        staysOn ? "Agents on \(name) can ask for your passwords, and \(name) passes requests to your iPhone and Apple Watch. Remove it in Devices."
            : "Agents on \(name) can ask for your passwords. Remove it in Devices."
    }
    public static let addingDeviceLead = "Add to Agent Keyring"
    /// While a new device is given its copies, under "Approved".
    public static func filling(_ name: String, done: Int, total: Int) -> String {
        "\(name) added. Copying your passwords to it: \(done) of \(total)."
    }
    public static func fillingStopped(_ name: String, reason: String) -> String {
        "\(name) added, but copying your passwords to it stopped: \(reason) Remove it in Devices and add it again."
    }
    public static func addingDeviceDetail(watch: Bool) -> String { watch ? "Paired with your iPhone" : "Same Apple Account" }
    public static func addingDeviceFooter(watch: Bool) -> String {
        watch ? "It approves requests with one tap while unlocked on your wrist. Remove it in Devices."
            : "It approves requests with Face ID. Remove it in Devices."
    }
    public static func notAdded(_ name: String) -> String { "\(name) was not added." }
}

/// Every sentence of the first-run windows (MacFirstRunView) and the
/// practice request, from the Paper board "First run".
public enum FirstRunCopy {
    // Welcome
    public static let title = "Welcome to Agent Keyring"
    public static let intro = "Agent Keyring gives your AI agents, such as Claude Code and Codex, your passwords, so they can sign in to websites and finish tasks for you. Each time, they ask and you decide."
    public static let points: [(symbol: String, title: String, body: String)] = [
        ("checkmark.shield", "You approve every request",
         "A request shows the website, the agent and why it asks. Approve it on this Mac with Touch ID, or on your iPhone or Apple Watch. Or deny it and tell the agent what to do instead."),
        ("clock", "One approval covers one task", "The agent can use the password for the task you approved, for 30 minutes at most."),
        ("lock", "Locked by this Mac’s security chip",
         "Agent Keyring keeps its copy of your passwords encrypted with a key held in the Secure Enclave, the chip behind Touch ID. The key never leaves the chip, and Agent Keyring opens one password at a time, for one agent’s task."),
    ]
    public static let getStarted = "Get Started"

    // The practice request
    public static let tryPractice = "Try a practice request"
    public static let practiceIntro = "This is how an agent asks for a password. The website and account are made up, and nothing is shared."
    public static let toApprove = "To approve, click the green button, then use Touch ID."
    public static let toDeny = "To deny, click Deny. You can first type what the agent should do instead."
    public static let approveToContinue = "To continue setting up, approve it. This also checks that Touch ID works with Agent Keyring."
    public static let youDeniedIt = "You denied it"
    public static let realAgentWouldRead = "A real agent would get no password and would read your reply:"
    public static let realAgentWouldStop = "A real agent would get no password."
    public static let approveOneToContinue = "To continue setting up, approve a practice request."
    public static let tryAgain = "Try Again"
    public static let addFingerprint = "Add a fingerprint"
    public static let addFingerprintBody = "You approve requests on this Mac with Touch ID, but Touch ID has no fingerprint yet. Add one in System Settings, then come back here."
    public static let openTouchIDSettings = "Open Touch ID Settings"
    public static let openTheLid = "Open the lid"
    public static let openTheLidBody = "Touch ID is on the keyboard, so you can’t use it while the lid is closed. The practice request appears when you open the lid."

    // Copy your passwords
    public static let copyTitle = "Copy your passwords"
    public static let copyBody = "Agent Keyring works from its own copy of your passwords. The Passwords app can send it one."
    /// Markdown: the menu items and buttons are in bold. Step 3 is followed by
    /// this app's row as Passwords' list shows it.
    public static let steps = [
        "In the Passwords app, choose **File > Export All Items to App**, then click **Continue**.",
        "When macOS asks, use Touch ID or enter your Mac’s login password.",
        "Choose this app, click **Continue**, then **Continue in “Agent Keyring”**:",
    ]
    public static let appName = "Agent Keyring"
    public static let earlierVersion = "If you also see “AgentKeyring”, that is the earlier version. Don’t choose it."
    public static let notInList = "Agent Keyring isn’t in the list?"
    public static let allowExportTitle = "Allow export from Passwords"
    public static let allowExportBody = "macOS uses its AutoFill setting to choose which apps Passwords can export to. Agent Keyring never fills in passwords."
    public static let deletesNothing = "Exporting deletes nothing from the Passwords app. Passwords you save later stay there until you copy them again."
    public static let waitingForPasswords = "Waiting for your passwords…"
    public static let noneArrived = "No passwords have arrived yet. In step 3, check that you chose Agent Keyring and clicked Continue in “Agent Keyring”."
    public static let openPasswords = "Open Passwords"
    public static let useSample = "Use the Test Password Only"
    public static let sampleNote = "Agent Keyring always keeps one test password: example.com, you@example.com, password “hello”. You can copy your own passwords later from Passwords."
    public static let copying = "Copying your passwords…"
    public static let cancel = "Cancel"
    public static let copyOwn = "Copy Your Own Passwords"

    // Tell your agents
    public static func copied(_ count: Int) -> String { count == 1 ? "1 password copied." : "\(count) passwords copied." }
    public static let mustAskAny = "An agent must ask you before using any of them."
    public static let sampleAdded = "Test password added."
    public static let sampleDetail = "Agent Keyring always keeps one test password: example.com, you@example.com, password “hello”. You can copy your own passwords later from Passwords."
    public static let tellTitle = "Tell your agents about Agent Keyring"
    public static let tellBody = "Your agents need nothing installed. Give them this note, and when a task needs a website password or a two-factor code, they ask you through Agent Keyring."
    public static func agentNote(appPath: String) -> String {
        "When a task needs a website password or a two-factor code, use Agent Keyring. To learn how, run \"\(appPath)/Contents/Helpers/agent-keyring\" skill"
    }
    public static var agentNote: String { agentNote(appPath: Bundle.main.bundleURL.path) }
    public static let pasteIt = "Paste it into a chat with an agent, or add it to the instructions your agents read every time, such as CLAUDE.md or AGENTS.md. Agent Keyring never changes your agents’ settings."
    public static let tryItNow = "Try it now"
    public static let tryItBody = "Ask an agent to sign in to one of your websites. Its request appears beside your pointer."
    public static let tryItSample = "Send this to an agent: “Use Agent Keyring to get the test password for example.com, to check that Agent Keyring works.” Its request appears beside your pointer."
    public static let noRequestYet = "No request from an agent yet"
    public static func approvedRequest(agent: String, site: String) -> String { "\(agent) asked for \(site), and you approved it." }
    public static let copied = "Copied"
    public static let continueButton = "Continue"
    /// Interim until the board is drawn: the computer that announced itself through iCloud Keychain.
    public static func connectTo(_ name: String) -> String { "Connect to \(name)" }
    // Which devices (interim until the board is drawn)
    public static let chooseTitle = "Which devices will you use?"
    public static let chooseBody = "Agent Keyring sets up only what you choose. You can add the others later, from Devices."
    public static let chooseIPhone = "iPhone, to approve with Face ID"
    public static let chooseWatch = "Apple Watch, to approve with a tap"
    public static let chooseComputers = "Other computers where agents work"
    public static let skip = "Skip"

    // A computer that stays on
    public static let stayingOnTitle = "Approve from your iPhone and Apple Watch"
    public static let stayingOnBody = "This Mac already works on its own. To answer on your iPhone or Apple Watch, or to let agents on other computers ask, Agent Keyring needs a computer of yours that stays on, such as a Mac mini or a home server. It passes requests between your devices, and the part that does this can’t read your passwords."
    public static let itsAddress = "ITS ADDRESS"
    public static let addressPlaceholder = "For example mac-mini.local:17445"
    public static let addressHint = "Enter the name or address of the computer that stays on."
    public static let connect = "Connect"
    public static let isThisMacTitle = "Is this Mac the one that stays on?"
    public static let isThisMacBody = "It can’t pass on requests yet. Choose another computer, or use this Mac alone for now."
    public static let noneStaysOnTitle = "No computer that stays on?"
    public static let noneStaysOnBody = "Agent Keyring works on this Mac with Touch ID. You can add your iPhone, Apple Watch and other computers later, from Devices."
    public static let useThisMacAlone = "Use This Mac Alone"
    public static func approveComputer(_ name: String) -> String { "Approve \(name)" }
    /// After Connect, while macOS's own dialog asks for Touch ID (not drawn: the board draws a panel).
    public static let approveInDialog = "Use Touch ID in the dialog beside your pointer."
    public static let waitingForApproval = "Waiting for your approval"

    // Add your iPhone, Apple Watch and other computers
    public static let phoneTitle = "Add your iPhone"
    public static let phoneBody = "Approve requests with Face ID wherever you are. Your iPhone finds this Mac by itself, through your Apple Account."
    public static let phoneSteps = ["On your iPhone, open Agent Keyring.", "Approve your iPhone here, beside your pointer."]
    public static let waitingForPhone = "Waiting for your iPhone"
    public static func added(_ name: String) -> String { "\(name) added." }
    public static let watchTitle = "Add your Apple Watch"
    public static let watchBody = "Approve requests with one tap on your wrist. Your Apple Watch is added from your iPhone."
    public static let watchSteps = [
        "On your Apple Watch, press the Digital Crown and open Agent Keyring. If it isn’t there, install it from the Watch app on your iPhone, under Available Apps.",
        "Your iPhone asks to add it.",
        "Approve your Apple Watch on your iPhone with Face ID.",
    ]
    public static let waitingForWatch = "Waiting for your Apple Watch"
    public static let computersTitle = "Add other computers"
    public static let computersBody = "For example a Linux server where an agent works. On each computer, run this command. It joins Agent Keyring, and you approve it here."
    public static let copyPrompt = "Copy Prompt for an Agent"
    public static let copyCommand = "Copy Command"
    public static let commandNote = "Each copy works for one computer, for 10 minutes. The computer needs Agent Keyring’s command installed. If an agent works there, copy the prompt instead, and the agent runs it for you."
    /// The one-time command; the computer names itself after its host name.
    public static func enrolCommand(_ link: String) -> String { "agent-keyring enrol --name \"$(hostname -s)\" --invite \"\(link)\"" }
    /// Not drawn: the words around the command for an agent on that computer.
    public static func enrolPrompt(_ command: String) -> String {
        "Join this computer to Agent Keyring. Run this command here. It works once, for 10 minutes, and I approve it on my Mac:\n\(command)\nAfter that, run `agent-keyring skill` and follow it whenever a task needs a password."
    }
    public static func joined(_ name: String) -> String { "\(name) joined." }

    // Try a request on each device
    public static let tryTitle = "Try a request on each device"
    public static let tryBody = "Send a practice request to one device at a time. Approve it, deny it, or deny it with a reply. On iPhone, tap the microphone in the reply box to speak the reply."
    public static let sendPractice = "Send Practice Request"
    public static let thisMac = "This Mac"
    public static func practiceApprovedAt(_ time: String, touchID: Bool) -> String { touchID ? "Approved with Touch ID at \(time)" : "Approved at \(time)" }
    public static func practiceDeniedAt(_ time: String, reply: String) -> String { reply.isEmpty ? "Denied at \(time)" : "Denied at \(time): “\(reply)”" }
    // A practice request on its way, step by step, only what is known.
    public static let practiceSending = "Sending…"
    public static func practiceWithApple(_ time: String) -> String { "With Apple since \(time). On its way to the device." }
    public static func practiceOnWrist(_ time: String) -> String { "On your Apple Watch since \(time). Raise your wrist to answer." }
    public static func practiceOnPhone(_ time: String) -> String { "On your iPhone since \(time). Answer it there." }
    public static let practiceSentHere = "Sent. Answer it beside your pointer."
    public static let practiceUnanswered = "No answer within 10 minutes."

    // Ready
    public static let ready = "Agent Keyring is ready"
    public static let sampleTitle = "You are using the test password only"
    public static let sampleBody = "example.com is only for trying Agent Keyring. Copy your own passwords when you want your agents to use them."
    /// With an iPhone or Apple Watch added.
    public static let readyPoints: [(symbol: String, title: String, body: String)] = [
        ("cursorarrow.rays", "Requests come to you",
         "Each request appears beside your pointer, and on your iPhone and Apple Watch. Answer on whichever is nearest, and the others clear."),
        ("keyhole", "Agent Keyring stays in the menu bar",
         "Click the keyhole to see requests waiting for you, passwords agents are using now and what happened earlier. Click Stop to end an approval early."),
        ("list.bullet", "Choose which passwords agents must ask for",
         "Agents must ask before using any password. To change that for some, open Passwords from the keyhole. Sort with AI lets an agent suggest a rule for each one."),
        ("iphone", "Add, test or remove devices",
         "Open Devices from the keyhole to add an iPhone, Apple Watch or computer, or to send a practice request to one."),
    ]
    /// This Mac alone.
    public static let readyAlonePoints: [(symbol: String, title: String, body: String)] = [
        ("cursorarrow.rays", "Requests appear beside your pointer",
         "To approve one, click the green button and use Touch ID. To deny it, click Deny, with a reply if you want."),
        ("keyhole", "Agent Keyring stays in the menu bar",
         "Click the keyhole to see requests waiting for you, passwords agents are using now and what happened earlier."),
        ("list.bullet", "Choose which passwords agents must ask for",
         "Agents must ask before using any password. To change that for some, open Passwords from the keyhole. Sort with AI lets an agent suggest a rule for each one."),
        ("iphone", "Add your iPhone and Apple Watch later",
         "They need a computer of yours that stays on, such as a Mac mini. Open Devices from the keyhole when you have one."),
    ]
    public static let done = "Done"
    /// Under the menu bar icon after Done.
    public static let staysHere = "Agent Keyring stays here."

    public static let copy = "Copy"

    // The practice request in the panel
    public static let practiceAgent = "Agent Keyring"
    public static let practiceWants = "Practice request: an agent wants"
    public static let practiceSite = "example.com"
    public static let practiceAccount = "you@example.com"
    public static let practiceReason = "You asked me to download October’s invoice."
    public static let practiceFooter = "Practice only. No password is shared."
    public static let practiceApproved = "No real password was used."
    /// After "Agent Keyring is trying to" in macOS's dialog.
}

/// The words of the main window: the Passwords and Devices tabs, from the
/// copy ledger of 21 November 2026 (section 3, "Every day"). Rewritten on
/// 2026.11.21 by model claude opus 5.5 for the direct design: no relay and no
/// computer that stays on.
public enum MainWindowCopy {
    public static let passwordsTab = "Passwords"
    public static let devicesTab = "Devices"

    // Passwords
    public static let rulesExplained = "**Ask:** approve each time (2FA secret stays on your devices). **Automatic:** chosen computers get it without asking (keeps its own encrypted copy, 2FA secret included). **Blocked:** no agent can use it."
    public static func search(_ count: Int) -> String { count == 1 ? "Search 1 password" : "Search \(count) passwords" }
    public static let all = "All"
    /// A filter with its count: "Ask 533".
    public static func filter(_ name: String, _ count: Int) -> String { "\(name) \(count)" }
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
    public static func rulesChange(_ count: Int) -> String { "The rules for \(count) passwords change." }
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
    /// Also first run's device rows (SetupScreens.practiceRows).
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
    public static let doorFailed = "Agent Keyring couldn't open its connection for your other devices. It tries again every 10 seconds."

    // macOS's dialog, after "Agent Keyring is trying to" (page "The request", board "On the Mac").
    /// Making one password Automatic, naming every computer that will get it.
    public static func automaticReason(_ computers: [String], site: String) -> String {
        "let agents on \(list(computers)) use your \(site) password without asking"
    }
    public static func automaticReason(_ computers: [String], count: Int) -> String {
        "let agents on \(list(computers)) use \(count) passwords without asking"
    }
    public static func changeReason(site: String, from: String, to: String) -> String { "change \(site) from \(from) to \(to)" }
    public static func changeReason(count: Int) -> String { "change the rules for \(count) passwords" }

    /// "a", "a and b", "a, b and c".
    public static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
