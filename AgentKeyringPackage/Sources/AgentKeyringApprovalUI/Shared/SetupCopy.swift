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

    public static let review = "Review"
    public static let notNow = "Not now"
    public static let allow = "Allow"
    public static let sendImportedTitle = "Let agents on your other computers use the passwords you just copied?"
    public static let sendImportedBody = "Until you allow this, they can only use the list you had before."
    /// After "Agent Keyring is trying to" in macOS's dialog.
    public static let sendImportedReason = "let agents on your other computers use the passwords you just copied"

    // MARK: A computer or device being added (the request panel)

    public static func addingComputerLead(agent: String) -> String { "\(agent) on this Mac wants to add" }
    public static let addingLead = "An agent wants to add"
    public static func addingComputerFooter(_ name: String, staysOn: Bool) -> String {
        staysOn ? "Agents on \(name) can then ask for your passwords, and requests reach your iPhone through it. Remove it at any time in Devices."
            : "Agents on \(name) can then ask for your passwords. Remove it at any time in Devices."
    }
    public static func addingDeviceLead(watch: Bool) -> String { "Agent Keyring on \(watch ? "Apple Watch" : "iPhone") wants to add" }
    public static func addingDeviceDetail(watch: Bool) -> String { watch ? "Paired with your iPhone" : "Same Apple Account" }
    public static func addingDeviceFooter(watch: Bool) -> String {
        watch ? "It approves requests with one tap while it is unlocked on your wrist. Remove it at any time in Devices."
            : "It approves requests with Face ID. Remove it at any time in Devices."
    }
    public static func notAdded(_ name: String) -> String { "\(name) was not added." }
}

/// Every sentence of the first-run windows (MacFirstRunView) and the
/// practice request, from the Paper board "First run".
public enum FirstRunCopy {
    // The first window
    public static let title = "Agent Keyring"
    public static let intro = "Your AI agents ask before they use one of your passwords. You approve or deny."
    public static let copyHeading = "Copy your passwords from Passwords"
    public static let copyDetail = "Agent Keyring keeps its copy locked until you approve a request."
    public static let steps = ["In Passwords, choose File > Export All Items to App.", "Choose Agent Keyring."]
    public static let openPasswords = "Open Passwords"
    public static let notInList = "Agent Keyring isn’t in the list?"

    // Only from that link, before macOS's AutoFill question
    public static let autoFillTitle = "Let Passwords export to Agent Keyring"
    public static let autoFillBody = "macOS uses its AutoFill setting to decide which apps Passwords can export to. Agent Keyring never fills in a password for you."
    public static let autoFillNotNow = "Passwords can’t export to Agent Keyring until AutoFill is on for it. Agent Keyring never fills in a password for you."
    public static let continueButton = "Continue"

    public static let noneArrived = "No passwords have arrived. In Passwords, choose File > Export All Items to App, then Agent Keyring."
    public static let copying = "Copying your passwords…"

    // When the passwords arrive
    public static func copied(_ count: Int) -> String { count == 1 ? "1 password copied" : "\(count) passwords copied" }
    public static let alwaysAsk = "Agents always ask before using one."
    public static let tryPractice = "Try a practice request"
    public static let approveIt = "Approve it to finish setting up."
    public static let approveOne = "Approve one to finish setting up."
    public static let sendAnother = "Send Another"

    // After he approves
    public static let setUpTitle = "You’re set up on this Mac"
    public static let setUpBody = "A request appears beside your pointer whenever an agent needs a password."
    public static let tellAgents = "Tell your agents"
    public static let tellAgentsBody = "Paste this into any agent on this Mac. It learns how to ask for a password, and can set up your iPhone, Apple Watch and other computers."
    public static let copy = "Copy"
    public static let copied = "Copied"
    public static let done = "Done"

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
    public static let approveOnPhone = "Approve it on your iPhone"
    public static let waitingForPhone = "Waiting for your iPhone"
    public static func rulesChange(_ count: Int) -> String { "The rules for \(count) passwords change." }
    public static func ruleChange(site: String, from: String, to: String) -> String { "\(site) changes from \(from) to \(to)." }
    public static let stillKnown = " An agent that has already received its password still knows it."
    /// Names every computer that will get the password without asking.
    public static func automaticTo(_ computers: [String], count: Int) -> String {
        " Agents on \(list(computers)) will get \(count == 1 ? "it" : "them") without asking."
    }
    public static func stillOnPhone(_ sites: [String]) -> String {
        sites.count == 1 ? "\(sites[0]) is still set to Ask on iPhone or Apple Watch."
            : "\(sites.count) passwords are still set to Ask on iPhone or Apple Watch."
    }
    public static let deniedOnPhone = "Denied on your iPhone. "
    public static let noAnswerOnPhone = "No answer on your iPhone after 10 minutes. "
    public static let notSentToPhone = "The change could not be sent to your iPhone."
    public static let didNotFinish = "That didn't finish. Nothing changed."

    // Devices
    public static let youApproveOn = "You approve on"
    public static let agentsAskFrom = "Agents ask from"
    public static let automaticPasswords = "Automatic passwords"
    public static let remove = "Remove"
    public static func this(_ name: String) -> String { "This \(name)" }
    public static let macApproves = "Touch ID, with the lid open"
    public static let phoneApproves = "Face ID"
    public static let watchApproves = "One tap, unlocked on your wrist"
    public static let staysOn = "Requests reach your iPhone through it"
    public static let ready = "Ready"
    /// After "Agent Keyring is trying to"; `computer` is nil for this Mac.
    public static func automaticReason(_ computer: String?, on: Bool) -> String {
        let agents = computer.map { "agents on \($0)" } ?? "agents on this Mac"
        return on ? "let \(agents) get Automatic passwords without asking" : "stop \(agents) getting Automatic passwords"
    }
    public static let toAdd = "To add a computer, iPhone or Apple Watch, paste this into any agent on this Mac."

    /// "a", "a and b", "a, b and c".
    public static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
}
