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
    // The first window
    public static let title = "Agent Keyring"
    public static let intro = "Your AI agents ask before they use your passwords. You approve or deny."
    public static let copyHeading = "Copy from the Passwords app"
    public static let copyDetail = "The copy is kept locked on your own devices."
    public static let steps = ["In Passwords, choose File > Export All Items to App.", "Choose Agent Keyring."]
    public static let openPasswords = "Open Passwords"
    public static let notInList = "Don’t see Agent Keyring in Passwords?"

    // Only from that link, before macOS's AutoFill question
    public static let autoFillTitle = "Allow export from Passwords"
    public static let autoFillBody = "macOS uses its AutoFill setting to choose which apps Passwords can export to. Agent Keyring never fills in passwords."
    public static let autoFillNotNow = "Turn on AutoFill for Agent Keyring so Passwords can export to it. Agent Keyring never fills in passwords."
    public static let continueButton = "Continue"

    public static let noneArrived = "No passwords copied yet. In Passwords, choose File > Export All Items to App, then Agent Keyring."
    public static let copying = "Copying your passwords…"
    public static let needsFingerprint = "Add a fingerprint in System Settings to approve requests on this Mac."
    public static let openSystemSettings = "Open System Settings"
    public static let openTheLid = "Open the lid to approve with Touch ID."

    // When the passwords arrive
    public static func copied(_ count: Int) -> String { count == 1 ? "1 password copied" : "\(count) passwords copied" }
    public static let alwaysAsk = "Agents always ask before using one."
    public static let tryPractice = "Try a practice request"
    public static let approveIt = "Approve it to finish setting up."
    public static let approveOne = "Approve one to finish setting up."
    public static let tryAgain = "Try Again"

    // After he approves
    public static let setUpTitle = "You’re set up on this Mac"
    public static let setUpBody = "A request appears beside your pointer whenever an agent needs a password."
    public static let tellAgents = "Tell your agents"
    public static let tellAgentsBody = "Paste this into any agent on this Mac. It sets up your agents here, and can add your iPhone, Apple Watch and other computers."
    public static let copy = "Copy"
    public static let copied = "Copied"
    public static let done = "Done"
    /// Under the menu bar icon after Done.
    public static let staysHere = "Agent Keyring stays here."

    /// The line Josh pastes into an agent: something it can run on a Mac where
    /// nothing is installed yet, which prints the skill.
    public static func agentLine(appPath: String) -> String {
        "Set up Agent Keyring: run \"\(appPath)/Contents/Helpers/agent-keyring\" skill"
    }
    public static var agentLine: String { agentLine(appPath: Bundle.main.bundleURL.path) }

    // The practice request
    public static let practiceAgent = "Agent Keyring"
    public static let practiceSite = "example.com"
    public static let practiceAccount = "you@example.com"
    public static let practiceReason = "This is a practice request. No real password is used."
    /// Where a real request shows the project.
    public static let practicePlace = "Practice"
    public static let practiceFooter = "An approval lasts for one task, 30 minutes at most."
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
