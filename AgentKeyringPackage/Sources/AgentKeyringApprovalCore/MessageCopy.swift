// Written by AI on 2026.11.20 by model claude opus 5.5.
//
// Every sentence Josh reads that is made outside a view: the problems shown
// in Agent Keyring's windows and panels, macOS's Touch ID dialog sentences,
// and the reminder notification. The views' own sentences are in SetupCopy,
// FirstRunCopy, MainWindowCopy and AccessRequestCopy. Messages to agents are
// not here: they stay with the code that sends them.

import Foundation

public enum MessageCopy {
    /// For an error with no sentence of its own.
    public static let somethingWentWrong = "Something went wrong. Try again."
    /// An agent that gave no name.
    public static let anAgent = "An agent"

    // MARK: macOS's dialog, after "Agent Keyring is trying to"

    /// The computer is named only when it is not this Mac.
    public static func useYourPassword(site: String, account: String, agent: String, computer: String? = nil) -> String {
        let site = URL(string: site)?.host() ?? site
        let who = (agent.isEmpty ? "an agent" : agent) + (computer.map { " on \($0)" } ?? "")
        return "let \(who) use your \(site) password, \(account)"
    }
    public static let practiceInDialog = "use a practice password for example.com, you@example.com"
    public static func add(_ name: String) -> String { "add \(name)" }
    public static let addADevice = "add a device"
    public static func remove(_ name: String) -> String { "remove \(name)" }

    // MARK: Approving with Touch ID or Apple Watch

    public static let approvalUnavailable = "Approval isn't available. Check Touch ID or Apple Watch, then try again."
    public static func declined(_ owner: String) -> String { "\(owner) declined the request." }
    public static let approvalInterrupted = "Approval was interrupted. Try again."
    public static let approvalNotConfirmed = "Approval didn't confirm. Try again."
    public static let expired = "The request expired with no answer."
    public static let approvalFailed = "Couldn't approve the password. Nothing was shared."
    public static let alreadyApproving = "An approval is already in progress on this Mac."
    public static let practiceKeysFailed = "Couldn't verify this Mac's Secure Enclave key. Try again."

    // MARK: Rules

    public static let confirmationInterrupted = "Confirmation was interrupted. Try again."
    public static let touchIDUnavailable = "Touch ID or Apple Watch isn't available. Check that one is ready and try again."
    public static let macOSCouldNotConfirm = "macOS couldn't confirm you. Try again."
    public static let rulesNotSaved = "Agent Keyring couldn't save the rules. Try again. If it keeps happening, restart Agent Keyring."
    public static let rulesBeingSaved = "Access rules are already being saved. Wait for that save to finish."
    public static let rulesUnreadable = "The saved rules could not be read. Every password asks first until you set them again."
    public static let unknownPassword = "The change included an unknown password. No rule was changed."

    // MARK: Passwords

    public static let passwordGone = "The password is no longer available."
    public static let passwordBlocked = "This password is now blocked for agents."
    public static let copyUnreadable = "Agent Keyring's copy of your passwords could not be opened. Passwords was not changed."
    public static let passwordsWontOpen = "Passwords could not be opened."
    public static let exportSentNothing = "Passwords opened Agent Keyring without sending your passwords. Try the export again."
    public static func exportFailed(_ kind: ExportFailure, hadEarlierCopy: Bool) -> String {
        let sentence = switch kind {
        case .notSent: "Passwords did not send your passwords. Start the export again in Passwords."
        case .unfinished: "Passwords could not finish sending your passwords. Start the export again in Passwords."
        case .other: "Passwords could not send your passwords. Try the export again."
        }
        return sentence + (hadEarlierCopy ? " Your earlier copy was not changed." : "")
    }
    public enum ExportFailure: Sendable { case notSent, unfinished, other }
    public static func notLockedAway(hadEarlierCopy: Bool) -> String {
        "Passwords sent your passwords, but Agent Keyring could not lock them away." + (hadEarlierCopy ? " Your earlier copy was not changed." : "")
    }
    public static let leasesNotEnded = "Couldn't stop active access. Try again."
    public static let endsByItself = "Access on another computer ends by itself 30 minutes after approval."

    // MARK: The reminder to copy again

    public static func copyIsOld(days: Int) -> String { "Agent Keyring's copy of your passwords is \(days) days old." }
    public static let exportInstruction = "File > Export All Items to App"
    public static let updateFromPasswords = "Update from Passwords"

    // MARK: Devices and computers

    public static let noKeysYet = "This Mac has no keys yet."
    public static let noIPhoneOrWatch = "This Mac has no iPhone or Apple Watch added yet."
    public static let notATailscaleAddress = "That address isn't on Tailscale. Check that Tailscale is on for both devices."
    public static let nothingJoining = "Nothing is waiting to join with that name."
    /// This Mac has no Tailscale address: Tailscale is not installed, not running, or signed out.
    public static let noTailscale = "Tailscale is off on this Mac, so your iPhone, Apple Watch and other computers can't reach it. Turn on Tailscale, then try again."
    /// Said when a device or computer is added: both ends need Tailscale.
    public static func bothNeedTailscale(_ name: String) -> String { "This Mac and \(name) both need Tailscale turned on to reach each other." }
    public static func doorClosed(_ reason: String) -> String { "This Mac couldn't start listening for your devices: \(reason)" }
    public static let noPushKey = "This Mac can't notify your iPhone or Apple Watch yet: it has no push key. An agent adds it with agent-keyring push-key."
    public static func noPushAddress(_ name: String) -> String { "\(name) hasn't given this Mac its notification address yet. Open Agent Keyring on it." }
    public static let joinRanOut = "This request to join ran out after ten minutes. Ask again from the other device."
    public static let invalidPushKey = "That isn't Apple's push key (a .p8 file)."

    // MARK: Reaching another device or computer

    public static let unreachable = "Couldn't reach the other device. Check that Tailscale is on for both and that it's awake."
    public static let connectionEnded = "The connection to the other device ended. Try again."
    public static let notOnTailscale = "That device isn't on Tailscale. Check that Tailscale is on for both devices."
    public static let messageTooLarge = "That message is too large to send."
    public static let unreadableReply = "The other device sent something Agent Keyring couldn't read. Try again."
    public static let unacceptedKey = "The other device's key isn't one Agent Keyring accepts."

    // MARK: Answering another computer's request

    public static let noCopyOnThisMac = "This Mac has no copy of this password. Copy your passwords again from Passwords."
    public static func answerNotDelivered(_ computer: String) -> String {
        "Your answer didn't reach \(computer). Check that it's awake and on Tailscale, then try again, or answer on your iPhone."
    }
    public static func answerRefused(_ computer: String, _ words: String) -> String { "\(computer) didn't take your answer: \(words)" }
}
