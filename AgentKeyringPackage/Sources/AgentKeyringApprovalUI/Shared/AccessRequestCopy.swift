// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Request words the Mac's request panel and menu bar use.

import Foundation

public enum AccessRequestCopy {
    public static let letAskAgain = "Let it ask again"

    // The request panel
    /// "Codex on Mac mini wants"; with no name for who is asking, "An agent on Mac mini wants".
    public static func wants(_ agent: RequestingAgent) -> String {
        let name = agent.name.prefix(1).uppercased() + agent.name.dropFirst()
        return agent.isLocal ? "\(name) on this Mac wants" : "\(name) on \(agent.machine) wants"
    }
    public static func replyPlaceholder(_ agent: String) -> String {
        agent == "an agent" ? replyPlaceholderShort : "What should \(agent) do instead?"
    }
    public static let replyPlaceholderShort = "What should it do instead?"
    /// In place of the green button while the lid is shut.
    public static let openTheLid = "Open the lid to approve"
    public static let approveElsewhere = "Approve on your Apple Watch or iPhone"
    public static let lidClosed = "With the lid closed, this Mac can’t use Touch ID."
    public static let deny = "Deny"
    public static let denying = "Denying…"
    public static let approving = "Approving…"
    /// Josh's own words for the green button, before and after the click.
    public static let clickForTouchID = "Click to approve with Touch ID"
    public static let useTouchID = "Use Touch ID to approve"
    public static let clickForWatch = "Click to approve with Apple Watch"
    public static let useWatch = "Approve on your Apple Watch"
    public static let noApprover = "Touch ID and Apple Watch aren’t available"
    public static func footer(_ agent: String) -> String { "\(agent) can use this password for this task, 30 minutes at most." }
    public static let approved = "Approved"
    public static let approvedOnPhone = "Approved on your iPhone"
    public static let denied = "Denied"
    public static let noAnswer = "No answer"
    public static let cancelled = "Cancelled"
    public static func stopped(_ agent: String) -> String { "\(agent) stopped asking before you answered." }
    /// After a computer or device is approved: "Mac mini added."
    public static func added(_ name: String) -> String { "\(name) added." }
    public static func canUseUntil(_ agent: String, _ time: String) -> String { "\(agent) can use this password until \(time) at the latest." }
    public static func youTold(_ agent: String, _ reply: String) -> String { "You told \(agent): “\(reply)”" }
    public static func wasTold(_ agent: String) -> String { "\(agent) was told." }
    public static func ended(_ agent: String) -> String { "The request ended after 10 minutes. \(agent) can ask again." }

    /// One word for history rows.
    public static func outcomeWord(_ state: AccessRequestState) -> String {
        switch state {
        case .waitingForYou: "Waiting"
        case .sendingAnswer: "Sending"
        case .waitingForMac: "Waiting for your Mac"
        case .approved(.automaticRule, _): "Automatic"
        case .approved: "In use"
        case .denied: "Denied"
        case .unanswered: "No answer"
        case .cancelled: "Cancelled"
        case .expired, .released: "Approved"
        case .ended: "Ended by you"
        case .blockedByRule: "Blocked"
        }
    }

    /// 24-hour clock, whatever the region: "02:41".
    public static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// The words of the menu bar window (MacMenuBarView), from the Paper board "In the menu bar".
public enum MenuBarCopy {
    public static let waitingForYou = "Waiting for you"
    public static let inUse = "In use"
    public static let earlierToday = "Earlier today"
    public static let nothing = "Nothing waiting. Nothing in use."
    public static let show = "Show"
    public static let stop = "Stop"
    public static func passwords(_ count: Int) -> String { count == 1 ? "1 password" : "\(count) passwords" }
    public static let devices = "Devices"
    /// A password the agent got by its Automatic rule, without asking.
    public static let automatic = "Automatic"
    public static let open = "Open Agent Keyring"
    public static let quit = "Quit Agent Keyring"
    public static let more = "More"
    /// When the computer that stays on has no name this Mac knows.
    public static let relayComputer = "The computer that stays on"
    public static func offline(_ computer: String) -> String { "\(computer) is offline, so requests can’t get to your iPhone or Apple Watch." }
    public static let paused = "Agents are paused on this Mac. Agent Keyring can’t read its record of what agents are using. Reset it to let them ask again. Your passwords and rules stay."
    public static let reset = "Reset…"

    /// "Codex on Mac mini · bookkeeping", "Claude Code on this Mac".
    public static func who(_ request: AccessRequest, project: Bool = true) -> String {
        let place = request.agent.isLocal ? "this Mac" : request.agent.machine
        let base = "\(request.agent.name) on \(place)"
        guard project, let name = request.agent.project, !name.isEmpty else { return base }
        return "\(base) · \(name)"
    }

    /// "Claude Code on this Mac · until 14:32".
    public static func inUseDetail(_ request: AccessRequest) -> String {
        guard case let .approved(_, until) = request.state else { return who(request, project: false) }
        return "\(who(request, project: false)) · until \(AccessRequestCopy.clock(until))"
    }
}
