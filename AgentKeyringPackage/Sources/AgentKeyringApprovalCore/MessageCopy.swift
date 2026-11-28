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
    public static func removeDeviceReason(_ name: String) -> String { "remove \(name)" }
    public static func renameDeviceReason(_ name: String, to next: String) -> String { "rename \(name) to \(next)" }

    // MARK: Approving with Touch ID, Apple Watch or the Mac password

    public static var approvalUnavailable: String {
        MacApprovalMode.current == .devicePassword ? "Approval isn't available. Check that this Mac has a login password, then try again."
            : "Approval isn't available. Check that your Touch ID keyboard is connected or your Apple Watch is nearby, then try again."
    }
    public static func declined(_ owner: String) -> String { "\(owner) declined the request." }
    public static let approvalInterrupted = "Approval was interrupted. Try again."
    public static let approvalNotConfirmed = "Approval didn't confirm. Try again."
    public static let expired = "The request expired with no answer."
    public static let approvalFailed = "Couldn't approve the password. Nothing was shared."
    public static let alreadyApproving = "An approval is already in progress on this Mac."
    public static let practiceKeysFailed = "Couldn't verify this Mac's Secure Enclave key. Try again."

    // MARK: Rules

    public static let confirmationInterrupted = "Confirmation was interrupted. Try again."
    public static var touchIDUnavailable: String {
        MacApprovalMode.current == .devicePassword ? "macOS couldn't ask for your Mac password. Try again."
            : "Touch ID or Apple Watch isn't available. Connect your Touch ID keyboard or check your Apple Watch, then try again."
    }
    public static let macOSCouldNotConfirm = "macOS couldn't confirm you. Try again."
    public static let rulesNotSaved = "Agent Keyring couldn't save the rules. Try again. If it keeps happening, restart Agent Keyring."
    public static let rulesBeingSaved = "Access rules are already being saved. Wait for that save to finish."
    public static let rulesUnreadable = "The saved rules could not be read. Every password asks first until you set them again."
    public static let unknownPassword = "The change included an unknown password. No rule was changed."

    // MARK: Passwords

    public static let passwordGone = "The password is no longer available."
    public static let passwordBlocked = "This password is now blocked for agents."
    /// To an agent asking for a password unblocked since: nothing to ask the user to approve.
    public static let secretDeletedForAgent = "This password was deleted from Agent Keyring when it was blocked. Ask the user to copy their passwords again from Passwords, then ask again."
    public static let copyUnreadable = "Agent Keyring's copy of your passwords could not be opened. Passwords was not changed."
    public static let passwordsWontOpen = "Passwords could not be opened."
    public static let exportSentNothing = "Passwords opened Agent Keyring without sending your passwords. Try the export again."
    public static let exportOnlyPasskeys = "Those items had only passkeys, not passwords. Select a login with a password in Passwords and try again."
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

    public static func copyIsOld(days: Int) -> String { "Agent Keyring's copy of your passwords is \(days.formatted()) days old." }
    public static let exportInstruction = "File > Export Selected Items to App (or Export All)"
    public static let updateFromPasswords = "Update from Passwords"

    // MARK: Devices and computers

    public static let noKeysYet = "This Mac has no keys yet."
    /// This Mac's saved keys could not be read. They are never replaced, so it says what to try.
    public static func keysUnreadable(_ error: Error) -> String {
        "Agent Keyring couldn't read this Mac's keys: \(reason(error)) Restart your Mac, then open Agent Keyring again."
    }
    public static let noMacPassword = "This Mac has no login password, so macOS can’t ask for one. Set a password for your user in System Settings, Users & Groups, then try again."
    public static func keysNotMade(_ error: Error) -> String {
        "Agent Keyring couldn't make this Mac's keys in its Secure Enclave: \(reason(error))"
    }
    private static func reason(_ error: Error) -> String {
        let words = (error as? LocalizedError)?.errorDescription ?? (error as NSError).localizedDescription
        return words.hasSuffix(".") ? words : words + "."
    }
    public static let noIPhoneOrWatch = "This Mac has no iPhone or Apple Watch added yet."
    public static let nothingJoining = "Nothing is waiting to join with that name."
    public static let noICloud = "This Mac isn't signed in to iCloud, so it can't keep your iPhone and Apple Watch in step. Sign in to iCloud in System Settings."
    /// Said to an agent whose computer tried to join with a code while it was already added or already waiting.
    public static func answeredElsewhere(_ computer: String) -> String { "Another of your devices answered \(computer)'s request first." }
    public static let alreadyAdded = "This computer is already added, or already waiting to be. Nothing changed."
    /// Before an agent uses an approval: the relay could not say whether a device stopped it.
    public static let stopNotChecked = "Agent Keyring couldn't check that this approval wasn't stopped, so it wasn't used. Try again in a moment."
    public static func stoppedOn(_ device: String) -> String { "The user stopped it on \(device)." }
    /// After "Agent Keyring is trying to" in macOS's dialog, right after a copy from Passwords.
    /// What is sent, so he sees what he confirms: "send 3 added, 1 changed and 2 removed passwords to your other devices".
    public static func sendChangesReason(added: Int, changed: Int, removed: Int) -> String {
        let parts = [(added, "added"), (changed, "changed"), (removed, "removed")].filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)" }
        guard let last = parts.last else { return "send your password changes to your other devices" }
        let listed = parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
        return "send \(listed) \(added + changed + removed == 1 ? "password" : "passwords") to your other devices"
    }
    public static let noPushKey = "This Mac can't notify your iPhone or Apple Watch yet: it has no push key. An agent adds it with agent-keyring push-key."
    public static func noPushAddress(_ name: String) -> String { "Finish setting up notifications in Agent Keyring on \(name)." }
    public static let joinRanOut = "This request to join ran out after ten minutes. Ask again from the other device."
    public static let invalidPushKey = "That isn't Apple's push key (a .p8 file)."

    // MARK: Another device's key

    public static let unacceptedKey = "The other device's key isn't one Agent Keyring accepts."

    // MARK: Answering another computer's request

    public static let noCopyOnThisMac = "This Mac has no copy of this password. Copy your passwords again from Passwords."
    public static let secretNotDeleted = "Agent Keyring couldn't delete a blocked password from this Mac. It will try again when it next opens."
    public static let secretDeletedOnThisMac = "This password was deleted when it was blocked. Copy your passwords again from Passwords to use it."
    public static func answerNotDelivered(_ computer: String) -> String {
        "Your answer didn't reach \(computer). Check that this Mac is online, then try again, or answer on your iPhone."
    }
}
