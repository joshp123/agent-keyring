// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Every sentence on the setup screens: a machine or iPhone joining, the
// Mac's relay, and the iPhone's pairing. Requests are in AccessRequestCopy.

import Foundation

public enum SetupCopy {
    // MARK: Comparing a code

    public static let allGroupsMustMatch = "Approve only if all eight groups match."
    public static let theyMatch = "They match"
    public static let doesNotMatch = "Doesn't match"

    // MARK: A machine or iPhone joining (Mac panel)

    public static func joiningLead(_ enrolment: DeviceEnrolment) -> String {
        switch enrolment.kind {
        case .machine: "Let agents on \(enrolment.name) ask for your logins?"
        case .approver: "Let your iPhone approve agents' requests?"
        }
    }

    /// The second line under a joining device's name, in lists.
    public static func joiningDetail(_ enrolment: DeviceEnrolment) -> String {
        if let old = enrolment.replacesPhone { return "Replaces \(old)" }
        return enrolment.kind == .machine ? "Wants its agents to ask for your logins" : "Wants to approve requests"
    }

    /// In the panel, under the new iPhone's name.
    public static func replacesPhone(_ old: String) -> String {
        "Replaces the iPhone paired as \(old). That one loses access: it can't approve requests any more."
    }

    public static func tailnetNode(_ node: String) -> String {
        "On your tailnet as \(node)"
    }

    public static func compareWith(_ enrolment: DeviceEnrolment) -> String {
        switch enrolment.kind {
        case .machine: "The agent setting up \(enrolment.name) shows you a code. Compare it with this one:"
        case .approver: "Compare with the code on your iPhone:"
        }
    }

    public static let allowAutomatic = "Let it use Automatic logins"
    public static let allowAutomaticOff = "Off: it asks you for every login, even Automatic ones."

    public static func joined(_ enrolment: DeviceEnrolment) -> String {
        switch enrolment.kind {
        case .machine: "\(enrolment.name) can now ask for logins."
        case .approver: enrolment.replacesPhone.map { "Your iPhone can now approve requests. The one paired as \($0) can't." }
            ?? "Your iPhone can now approve requests."
        }
    }

    public static func refused(_ enrolment: DeviceEnrolment) -> String {
        "Refused. Nothing was allowed. To try again, start again on \(enrolment.name)."
    }

    public static let joiningFailed = "Confirmation didn't finish. Nothing changed."

    // MARK: The Mac's relay (Machines window)

    public static let relayHeading = "Requests from other machines"
    public static let relayNotSetUp = "Agents on your other machines send their requests through Agent Keyring on your Mac mini. Connect this Mac to it once."
    public static let relayAddress = "Mac mini address"
    /// The relay listens on port 17443 on the Mac mini, so this is usually right as it is.
    public static let defaultRelayAddress = "mac-mini:17443"
    public static let relayAddressExample = "mac-mini:17443"
    public static let relayAddressHint = "Its Tailscale name and port."
    public static let connect = "Connect"
    /// The agent setting up the mini checks its code for Josh (it reads it over
    /// SSH and the Mac app compares), so he only makes the decision itself.
    public static let connectToMiniTitle = "Let agents on your other machines use your logins?"
    public static let connectToMiniBody = "You still approve each request. Their requests reach you through your Mac mini."
    public static let notNow = "Not now"
    public static let sendImportedTitle = "Let agents on your other machines use the logins you just imported?"
    public static let sendImportedBody = "Until you allow this, they can only use the list you had before."
    public static let allow = "Allow"
    public static let dontAllow = "Don't allow"

    public static func relayConnected(_ address: String) -> String { "Connected to \(address)" }
    public static func relayConnecting(_ address: String) -> String { "Connecting to \(address)…" }
    public static func relayOffline(_ address: String) -> String { "Can't reach \(address). Retrying." }

    public static func queuedAnswers(_ count: Int) -> String {
        count == 1 ? "1 answer will be sent when it's back." : "\(count) answers will be sent when it's back."
    }

    /// RFC 0005, "Applying a change": shown until the relay acknowledges.
    public static let applying = "Sending changes to your Mac mini…"
    public static let waitingToJoin = "Waiting to join"
    public static let machinesThatCanAsk = "Machines whose agents can ask for your logins"
    public static let noMachines = "None yet. To add a machine, ask an agent on it to set up Agent Keyring."
    public static let automaticAllowed = "Can use Automatic logins"
    public static let asksEveryTime = "Asks you for every login"
    public static let remove = "Remove"

    public static func removePhoneAction(_ name: String) -> String { "stop \(name) approving agents' requests" }
    public static func removeMachineAction(_ name: String) -> String { "stop agents on \(name) using your logins" }
    /// Honest about the limit: removal stops the phone approving, but cannot
    /// reach into it and erase what it already holds.
    public static let removePhoneMessage = "It stops approving once your other devices confirm. Passwords and two-factor codes already on it stay there, locked behind its Face ID. If someone else might have it, change those passwords and set up two-factor again."

    // MARK: Removals waiting for every device to confirm

    public static let waitingForDevices = "Waiting for devices"

    #if os(macOS)
    public static func withdrawalProgress(_ withdrawal: PendingWithdrawal) -> String {
        let waiting = "Waiting for \(list(withdrawal.waitingFor))."
        return withdrawal.confirmedOn.isEmpty ? waiting : "Done on \(list(withdrawal.confirmedOn)). " + waiting
    }
    #endif

    /// "a", "a and b", "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    public static let canApprove = "Where you approve requests"
    public static let answersWithTouchID = "Answers on this Mac"
    public static let answersWithFaceID = "Answers with Face ID"
    public static let review = "Review"

    // MARK: When the Mac asks the iPhone

    public static let phoneDelayFooter = "A request shows on your Mac first. If you don't answer there in time, or your Mac is locked, it comes here. The delay is set on your Mac."
    public static let askPhoneAfterOnMac = "Ask your iPhone after"
    public static let macDelayFooter = "If you haven't answered on this Mac by then. If this Mac is locked, your iPhone is asked straight away."

    /// "30 seconds", "1 minute", "9 minutes".
    public static func delay(_ delay: Duration) -> String {
        let seconds = Int(delay.components.seconds)
        return seconds < 60 ? "\(seconds) seconds" : seconds < 120 ? "1 minute" : "\(seconds / 60) minutes"
    }

    /// Home's empty state; the Lock Screen is mentioned only once it works.
    public static func nothingWaiting(_ status: PhoneNotifications) -> String {
        switch status {
        case .on: "When your Mac asks this iPhone, the request appears here and on your Lock Screen."
        case .notSetUp: "When your Mac asks this iPhone, the request appears here. Notifications aren't set up yet, so open Agent Keyring to check."
        case .off: "When your Mac asks this iPhone, the request appears here. Notifications are off, so open Agent Keyring to check."
        }
    }

    public static func notifications(_ status: PhoneNotifications) -> String {
        switch status {
        case .notSetUp: "Not set up yet"
        case .off: "Off in iPhone Settings"
        case .on: "On"
        }
    }

    // MARK: The iPhone's pairing

    public static let pairTitle = "Pair with your Mac"
    /// Fresh keys through the same comparison; the Mac drops this iPhone's old key.
    public static let pairAgain = "Pair again"
    public static let pairAgainFooter = "Your approvals are signed with this key, which never leaves this iPhone's Secure Enclave. Pair again to make new keys, for example if this iPhone was paired before it could keep logins for when your Mac is shut."
    public static let pairIntro = "Pair this iPhone to answer requests when you're away from your Mac. Requests reach it through Agent Keyring on your Mac mini."
    public static let pairButton = "Pair"
    public static let pairingConnecting = "Connecting to your Mac mini…"
    public static let pairingCompareHere = "Compare this code with the one on your Mac:"
    public static let pairingConfirmOnMac = "If every group matches, approve on your Mac. This screen moves on by itself."
    public static func pairingThrough(_ address: String) -> String { "Through \(address)" }
    public static let pairingPaired = "Paired. Requests now reach this iPhone."
    public static let tryAgain = "Try again"
    public static let notPairedNotice = "Not paired yet, so requests can't reach this iPhone."
}

/// Every sentence of the first-run window (MacFirstRunView).
public enum FirstRunCopy {
    public static let title = "Let your agents sign in as you"
    public static let intro = "When an agent needs a login, it asks Agent Keyring for one from Apple Passwords. You approve each request with Touch ID or your Watch."
    public static let importHeading = "First, bring in your logins"
    public static let allowBody = "macOS asks you once to let Apple Passwords send logins to Agent Keyring."
    public static let allowButton = "Allow"
    public static let exportBody = "In Passwords, choose File › Export All Items to App › Agent Keyring. Agent Keyring keeps an encrypted copy on this Mac, and reads nothing from Passwords except what you export."
    public static let exportButton = "Open Passwords"
    public static let importing = "Importing your logins…"
    public static let blockedBody = "Apple Passwords can't send logins to this copy of Agent Keyring. It needs a different Apple developer profile."

    public static let readyTitle = "Ready"
    public static func readyIntro(_ count: Int) -> String {
        "Agents can now ask for any of your \(count) logins. You're asked every time, unless you change a login's rule."
    }
    public static let whenAgentAsksHeading = "When an agent asks"
    public static let whenAgentAsksBody = "A request appears near the window you're working in. Approve it with Touch ID or your Watch, or press Deny. To tell the agent what to do instead, type it before you press Deny."
    public static let tellAgentsHeading = "Tell your agents"
    public static let tellAgentsBody = "Paste this into AGENTS.md or CLAUDE.md."
    public static let copy = "Copy"
    public static let copied = "Copied"
    public static func imported(_ ago: String) -> String { "Imported from Apple Passwords \(ago)." }
    public static let importAgain = "Import Again…"
    public static let rules = "Rules…"
}
