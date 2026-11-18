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
        case .approved(.automaticRule, _): "Used"
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
