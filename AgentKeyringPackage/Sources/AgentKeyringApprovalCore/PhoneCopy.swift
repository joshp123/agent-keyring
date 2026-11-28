// Written by AI on 2026.11.18 by model Claude Opus 5.5; edited on 2026.11.27 by model claude opus 5.5.
//
// The iPhone's words that its backend says too: what Face ID asks for, why a
// change failed, how each device approves, and the practice request. The rest
// of the iPhone's words extend this table in AgentKeyringApprovalUI.

import Foundation

public enum PhoneCopy {
    public static let alreadySetUpElsewhere = "Agent Keyring is already set up on another device with your Apple Account. Add this iPhone from there instead."
    public static let copyFailed = "Your passwords weren’t added. Export again from Apple Passwords."
    public static let reminderBody = "Open Apple Passwords, tap the More button, then Export Data to Another App."
    public static let addComputerFailed = "The computer wasn’t added. Make a new code and try again."
    public static let addComputerDeliveryFailed = "The computer was added, but couldn’t be reached yet. Try again."
    public static let watchNotReached = "Your Apple Watch didn’t receive them"
    public static let passwordsNotHereYet = "Some passwords aren’t on this iPhone yet"
    /// With no computer: "Practice request: an agent wants".
    public static let practiceAgent = "Practice request: an agent"
    public static let practiceSite = "example.com"
    public static let practiceAccount = "you@example.com"
    public static let practiceReason = "You asked me to download October’s invoice."
    public static func rule(_ rule: LoginRule) -> String {
        switch rule {
        case .ask: SharedCopy.ruleAskFirst
        case .automatic: SharedCopy.ruleAlwaysAllowed
        case .blocked: SharedCopy.ruleBlocked
        }
    }
    /// Face ID's sentence when a password becomes Always Allowed.
    public static func automaticReason(site: String, from: LoginRule, computers: [String]) -> String {
        "\(site) changes from \(rule(from)) to Always Allowed. Agents on \(list(computers)) will get it without asking."
    }
    /// "A", "A and B", "A, B and C".
    public static func list(_ names: [String]) -> String {
        names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    public static let answersWithFaceID = "Use Face ID to approve"
    public static let answersWithTap = "Tap to approve"
    /// A Mac approves with Touch ID, or with its password if it has no Touch ID; the iPhone isn't told which.
    public static let answersWithTouchID = "Use Touch ID or password to approve"
    // MARK: What Face ID says it is for

    public static let faceIDPractice = "Approve the practice request."
    public static func faceIDApprove(agent: String, computer: String, site: String) -> String {
        "Let \(agent) on \(computer) use \(site)."
    }
    public static func faceIDRemove(_ name: String) -> String { "Remove \(name)." }
    public static let faceIDAddWatch = "Let your Apple Watch approve requests."
    public static let faceIDSetUpHere = "Keep your passwords on this iPhone."
    public static let faceIDSaveCopy = "Save the passwords you added from Apple Passwords."
    public static func faceIDAddComputer(_ name: String) -> String { "Let agents on \(name) ask you for passwords." }
    public static func faceIDAddDevice(_ name: String) -> String { "Let \(name) keep your passwords and approve requests." }
    public static func faceIDSetRule(site: String, rule: LoginRule) -> String { "Set \(site) to \(self.rule(rule))." }
    public static let faceIDSendUpdates = "Send your password changes to your other devices."
    public static let anAgent = "An agent"
    public static let passwordNotOnThisIPhone = "This password isn’t on this iPhone yet. Add from Apple Passwords, then try again."
    public static let passwordDeletedWhenBlocked = "This password was deleted when it was blocked. Update from Apple Passwords to use it."
    public static func quoted(_ reason: String) -> String { "“\(reason)”" }
    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}

public enum DeviceSheetCopy {
    /// Finds the command where the install put it if it is not on the path yet.
    public static func enrolCommand(_ code: String) -> String {
        "\"$(command -v agent-keyring || echo ~/.local/bin/agent-keyring)\" enrol --name \"$(hostname -s)\" --code \"\(code)\""
    }
}
