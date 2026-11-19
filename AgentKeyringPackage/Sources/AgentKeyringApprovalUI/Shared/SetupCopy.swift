// Written by AI on 2026.10.31 by model Claude Opus 5.5; first run, the
// practice request, Passwords and Devices rewritten on 2026.11.19 by model
// claude opus 5.5 from the Paper boards "First run", "Passwords and rules"
// and "Devices" (page "First run and the app").
//
// Every sentence Josh reads on the Mac's setup screens, first run and the
// main window, so each is a one-line change. Requests are in AccessRequestCopy.

import Foundation

public enum SetupCopy {
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

    // MARK: A computer or device being added (the request panel)

    public static func addingComputerLead(agent: String) -> String { "\(agent) on this Mac wants to add" }
    /// A computer joining with a link from `agent-keyring invite`: the agent's name is not known.
    public static let addingLead = "Add to Agent Keyring"
    public static func addingComputerFooter(_ name: String, staysOn: Bool) -> String {
        staysOn ? "Agents on \(name) can ask for your passwords, and \(name) passes requests to your iPhone and Apple Watch. Remove it in Devices."
            : "Agents on \(name) can ask for your passwords. Remove it in Devices."
    }
    public static let addingDeviceLead = "Add to Agent Keyring"
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
    public static let title = "Agent Keyring"
    public static let intro = "AI agents such as Claude Code and Codex sometimes need to sign in to a website to finish a task. Agent Keyring gives an agent your password only when you approve."
    public static let points: [(symbol: String, title: String, body: String)] = [
        ("checkmark.shield", "You approve each request",
         "When an agent needs a password, a request shows you the website, the agent and why it asks. Approve it on your Mac, iPhone or Apple Watch, or deny it and tell the agent what to do instead."),
        ("clock", "One approval covers one task", "The agent can use the password for the task you approved, for 30 minutes at most."),
        ("lock", "Your passwords stay on your devices",
         "Agent Keyring copies them from the Passwords app. It sends a password only to agents you allow."),
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
    public static let useSample = "Use a Sample Password"
    public static let sampleNote = "No passwords yet, or want to look round first? Try everything with a sample password for example.com. When you copy your own, the sample goes."
    public static let copying = "Copying your passwords…"
    public static let cancel = "Cancel"
    public static let copyOwn = "Copy Your Own Passwords"

    // Set up your agents
    public static func copied(_ count: Int) -> String { count == 1 ? "1 password copied" : "\(count) passwords copied" }
    public static let mustAskAny = "An agent must ask you before it uses any of them."
    public static let sampleAdded = "1 sample password added"
    public static let sampleDetail = "example.com, you@example.com, password “hello”."
    public static let setUpTitle = "Set up your agents"
    public static let setUpBody = "Agents such as Claude Code and Codex need Agent Keyring’s command and instructions before they can ask for a password."
    public static let setUpAgentsButton = "Set Up Agents on This Mac"
    public static let setUpAgentsNote = "This adds the agent-keyring command and instructions for Claude Code and Codex. Agents already using an earlier Agent Keyring switch to this one."
    public static let agentsSetUp = "Agents on this Mac can now ask for passwords."
    public static let otherDevicesTitle = "Your other computers, iPhone and Apple Watch"
    public static let otherDevicesBody = "An agent adds these for you. Send it this message, and it asks which ones you want. You can do this later from Devices."
    public static let copyMessage = "Copy Message"
    public static let copied = "Copied"
    public static let continueButton = "Continue"

    // Ready
    public static let ready = "Agent Keyring is ready"
    public static let sampleTitle = "You are using a sample password"
    public static let sampleBody = "example.com is only for trying Agent Keyring. Copy your own passwords when you want your agents to use them."
    public static let readyPoints: [(symbol: String, title: String, body: String)] = [
        ("cursorarrow.rays", "Requests appear beside your pointer",
         "To approve one, click the green button and use Touch ID. To deny it, click Deny, with a reply if you want."),
        ("keyhole", "Agent Keyring stays in the menu bar",
         "Click the keyhole to see requests waiting for you, passwords agents are using now and what happened earlier. Click Stop to end an approval early."),
        ("list.bullet", "Choose which passwords agents must ask for",
         "Agents must ask you before using any password. To change that for one, or to copy more from the Passwords app, click the keyhole in the menu bar and open your list of passwords."),
    ]
    public static let phoneTitle = "Approve on your iPhone and Apple Watch"
    public static let phoneBody = "Install Agent Keyring on your iPhone and open it. It finds this Mac by itself. Requests then reach your iPhone and Apple Watch too, even with the lid closed."
    public static let phoneLaterTitle = "Add your iPhone and Apple Watch later"
    public static let phoneLaterBody = "They need a computer of yours that stays on, such as a Mac mini. To have an agent set one up, click the keyhole in the menu bar, open Devices and copy the message there."
    public static let done = "Done"
    /// Under the menu bar icon after Done.
    public static let staysHere = "Agent Keyring stays here."

    /// The message he sends an agent: something it can run on a Mac where
    /// nothing is installed yet, which prints the skill.
    public static func agentLine(appPath: String) -> String {
        "Set up Agent Keyring for me. Its instructions are inside the app: run \"\(appPath)/Contents/Helpers/agent-keyring\" skill"
    }
    public static var agentLine: String { agentLine(appPath: Bundle.main.bundleURL.path) }
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
    public static let practiceReasonInDialog = "use a practice password for \(practiceSite), \(practiceAccount)"
}

/// The words of the main window: the Passwords and Devices tabs.
public enum MainWindowCopy {
    public static let passwordsTab = "Passwords"
    public static let devicesTab = "Devices"
    public static let search = "Search"
    public static let all = "All"
    public static let copyAgain = "Copy Again"
    public static let noneCopied = "No passwords copied yet."
    public static let sampleOnly = "example.com is a sample password. When you copy your own from the Passwords app, it goes."
    public static let copyFromPasswords = "Copy from Passwords"
    public static func copiedOn(_ date: String) -> String { "Copied from Passwords on \(date). To add newer passwords, copy them again." }

    // The rule bar
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

    // Devices
    public static let youApproveOn = "You approve on"
    public static let agentsAskFrom = "Agents ask from"
    public static let automaticPasswords = "Automatic passwords"
    public static let remove = "Remove"
    public static func this(_ name: String) -> String { "This \(name)" }
    public static let macApproves = "Touch ID"
    public static let phoneApproves = "Face ID"
    public static let watchApproves = "One tap"
    public static let staysOn = "Passes requests to iPhone and Apple Watch"
    public static let ready = "Ready"
    // macOS's dialog, after "Agent Keyring is trying to" (page "The request", board "On the Mac").
    /// The Automatic switch in Devices; `computer` is nil for this Mac.
    public static func automaticReason(_ computer: String?, on: Bool) -> String {
        let name = computer ?? "this Mac"
        return on ? "let agents on \(name) use your Automatic passwords without asking"
            : "stop agents on \(name) using your Automatic passwords"
    }
    /// Making one password Automatic, naming every computer that will get it.
    public static func automaticReason(_ computers: [String], site: String) -> String {
        "let agents on \(list(computers)) use your \(site) password without asking"
    }
    public static func automaticReason(_ computers: [String], count: Int) -> String {
        "let agents on \(list(computers)) use \(count) passwords without asking"
    }
    public static func changeReason(site: String, from: String, to: String) -> String { "change \(site) from \(from) to \(to)" }
    public static func changeReason(count: Int) -> String { "change the rules for \(count) passwords" }
    public static let toAdd = "To add a computer, iPhone or Apple Watch, paste this into any agent on this Mac."

    /// "a", "a and b", "a, b and c".
    public static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
