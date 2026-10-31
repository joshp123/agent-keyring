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
        case .approver: "Your iPhone can now approve requests."
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
    public static let connect = "Connect"
    public static let compareWithRelayLog = "Compare with the code the relay printed in its log:"

    public static func relayConnected(_ address: String) -> String { "Connected to \(address)" }
    public static func relayOffline(_ address: String) -> String { "Can't reach \(address). Retrying." }

    public static func queuedAnswers(_ count: Int) -> String {
        count == 1 ? "1 answer waits to send." : "\(count) answers wait to send."
    }

    public static let rulesNotSent = "Rule changes haven't reached the relay, so other machines still see the old ones."
    public static let sendRules = "Send with Touch ID"
    public static let waitingToJoin = "Waiting to join"
    public static let machinesThatCanAsk = "Machines that can ask"
    public static let noMachines = "No other machine can ask yet. Run agent-keyring enrol on it to start."
    public static let automaticAllowed = "Automatic logins allowed"
    public static let asksEveryTime = "Asks every time"
    public static let remove = "Remove"
    public static let review = "Review"

    // MARK: The iPhone's pairing

    public static let pairTitle = "Pair with your Mac"
    public static let pairIntro = "Pairing lets requests reach this iPhone through the relay on your Mac mini, and lets you answer them here."
    public static let pairButton = "Pair"
    public static let pairingConnecting = "Connecting to the relay…"
    public static let pairingCompareHere = "Compare this code with the one on your Mac:"
    public static let pairingConfirmOnMac = "When every group matches, approve on your Mac with Touch ID. This iPhone carries on by itself."
    public static let pairingPaired = "Paired. Requests now reach this iPhone."
    public static let tryAgain = "Try again"
    public static let notPairedNotice = "Not paired yet, so requests can't reach this iPhone."
}
