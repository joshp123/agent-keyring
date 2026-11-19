// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Request words the Mac's menu bar and request panel share.

import Foundation

public enum AccessRequestCopy {
    /// Where a request came from, in lists: "This Mac" or the machine's name.
    public static func origin(_ agent: RequestingAgent) -> String {
        agent.isLocal ? "This Mac" : agent.machine
    }

    public static let letAskAgain = "Let it ask again"

    // The menu bar
    public static let waitingForYou = "Waiting for you"
    public static let inUse = "In use"
    public static let earlierToday = "Earlier today"
    public static let nothing = "Nothing waiting. Nothing in use."
    public static let show = "Show"
    public static let stop = "Stop"

    // The request panel
    public static func wants(_ agent: RequestingAgent) -> String {
        agent.isLocal ? "\(agent.name) on this Mac wants" : "\(agent.name) on \(agent.machine) wants"
    }
    public static func replyPlaceholder(_ agent: String) -> String { "What should \(agent) do instead?" }
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
    public static func canUseUntil(_ agent: String, _ time: String) -> String { "\(agent) can use this password until \(time) at the latest." }
    public static func youTold(_ agent: String, _ reply: String) -> String { "You told \(agent): “\(reply)”" }
    public static func wasTold(_ agent: String) -> String { "\(agent) was told." }
    public static func ended(_ agent: String) -> String { "The request ended after 10 minutes. \(agent) can ask again." }

    public static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d to answer", seconds / 60, seconds % 60)
    }

    public static func minutesLeft(until deadline: Date, now: Date) -> String {
        let minutes = max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(minutes) min left"
    }

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
        case .expired, .released: "Used"
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
