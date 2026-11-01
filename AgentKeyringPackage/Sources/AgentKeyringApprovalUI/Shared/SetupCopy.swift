// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Every sentence on the setup screens: a machine or iPhone joining, the
// Mac's relay, and the iPhone's pairing. Requests are in AccessRequestCopy.

import Foundation

public enum SetupCopy {
    // MARK: Comparing a code

    public static let allGroupsMustMatch = "All eight groups must match. If any differs, don't approve."
    public static let theyMatch = "They match"
    public static let doesNotMatch = "Doesn't match"

    // MARK: A machine or iPhone joining (Mac panel)

    public static func joiningLead(_ kind: DeviceEnrolment.Kind) -> String {
        switch kind {
        case .machine: "A new machine wants to ask for logins"
        case .approver: "Your iPhone wants to approve requests"
        }
    }

    /// The second line under a joining device's name, in lists.
    public static func joiningDetail(_ enrolment: DeviceEnrolment) -> String {
        if let old = enrolment.replacesPhone { return "Replaces \(old)" }
        return enrolment.kind == .machine ? "Wants to ask for logins" : "Wants to approve requests"
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
        case .machine: "Compare with the code \(enrolment.name) shows:"
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
        "Refused. If you expected \(enrolment.name), start again there; if you didn't, nothing was allowed."
    }

    public static let joiningFailed = "Touch ID didn't confirm. Nothing changed."

    // MARK: The Mac's relay (Machines window)

    public static let relayHeading = "Relay"
    public static let relayNotSetUp = "Agents on other machines ask through the relay on your Mac mini. Set it up once."
    public static let relayAddress = "Relay address"
    /// The relay listens on port 17443 on the Mac mini, so this is usually right as it is.
    public static let defaultRelayAddress = "mac-mini:17443"
    public static let relayAddressExample = "mac-mini:17443"
    public static let relayAddressHint = "The relay's Tailscale name and port."
    public static let connect = "Connect"
    /// RFC 0005, "First approver": setup reads the relay's code over the mini's
    /// trusted SSH connection and brings it to Josh; he never opens a log.
    public static let compareWithSetupCode = "Compare with the relay's code from setup:"
    public static let setupCodeSource = "Setup reads it on your Mac mini and shows it to you."

    public static func relayConnected(_ address: String) -> String { "Connected to \(address)" }
    public static func relayOffline(_ address: String) -> String { "Can't reach \(address). Retrying." }

    public static func queuedAnswers(_ count: Int) -> String {
        count == 1 ? "1 answer waits to send." : "\(count) answers wait to send."
    }

    /// RFC 0005, "Applying a change": shown until the relay acknowledges.
    public static let applying = "Applying changes…"
    public static let waitingToJoin = "Waiting to join"
    public static let machinesThatCanAsk = "Machines that can ask"
    public static let noMachines = "No other machine can ask yet. Run agent-keyring enrol on it to start."
    public static let automaticAllowed = "Automatic logins allowed"
    public static let asksEveryTime = "Asks every time"
    public static let remove = "Remove"
    public static let removeWithTouchID = "Remove with Touch ID"

    public static func removePhoneTitle(_ name: String) -> String { "Remove \(name)?" }
    /// Honest about the limit: removal stops the phone approving, but cannot
    /// reach into it and erase what it already holds.
    public static let removePhoneMessage = "It stops approving requests once your other devices confirm the change. This doesn't erase anything already on it: its stored passwords and two-factor codes stay locked behind its Face ID. If it might be in someone else's hands, change those passwords and set up two-factor again."

    // MARK: Removals waiting for every device to confirm

    public static let waitingForDevices = "Waiting for devices"

    public static func withdrawalProgress(_ withdrawal: PendingWithdrawal) -> String {
        let waiting = "Waiting for \(list(withdrawal.waitingFor))."
        return withdrawal.confirmedOn.isEmpty ? waiting : "Done on \(list(withdrawal.confirmedOn)). " + waiting
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    public static let canApprove = "Can approve requests"
    public static let answersWithTouchID = "Answers with Touch ID"
    public static let answersWithFaceID = "Answers with Face ID"
    public static let review = "Review"

    // MARK: When the Mac asks the iPhone

    public static let phoneDelayFooter = "A request shows on your Mac first. If you don't answer there in time, or your Mac is locked, it comes here. The delay is set on your Mac."
    public static let askPhoneAfterOnMac = "Ask your iPhone after"
    public static let macDelayFooter = "If you don't answer on this Mac by then. When this Mac is locked, it asks your iPhone at once."

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
    public static let pairAgainFooter = "Your approvals are signed with this key, which never leaves the iPhone's Secure Enclave. Pair again to give this iPhone new keys, for example if it was paired before it could keep logins for when your Mac is shut."
    public static let pairIntro = "Pairing lets requests reach this iPhone through the relay on your Mac mini, and lets you answer them here."
    public static let pairButton = "Pair"
    public static let pairingConnecting = "Connecting to the relay…"
    public static let pairingCompareHere = "Compare this code with the one on your Mac:"
    public static let pairingConfirmOnMac = "When every group matches, approve on your Mac with Touch ID. This iPhone carries on by itself."
    public static let pairingPaired = "Paired. Requests now reach this iPhone."
    public static let tryAgain = "Try again"
    public static let notPairedNotice = "Not paired yet, so requests can't reach this iPhone."
}
