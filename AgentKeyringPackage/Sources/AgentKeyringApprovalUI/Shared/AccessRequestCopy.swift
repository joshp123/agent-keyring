// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Every sentence the request screens show, in one place, so the words can
// change without touching a view. British English, plain, short.

import Foundation

public enum AccessRequestCopy {
    // MARK: The question

    /// The line above the site: "Codex wants to sign in to".
    public static func headlineLead(_ request: AccessRequest) -> String {
        switch request.access {
        case .signIn: "\(request.agent.name) wants to sign in to"
        case let .program(command): "\(request.agent.name) wants to give \(programName(command)) the password for"
        case .agentProcess: "\(request.agent.name) wants the password itself for"
        }
    }

    public static func headlineAccount(_ request: AccessRequest) -> String {
        "as \(request.login.account)"
    }

    // MARK: Facts Agent Keyring observed

    public static let machineLabel = "Machine"
    public static let accessLabel = "Access"
    public static let commandLabel = "Command"

    public static func machine(_ agent: RequestingAgent) -> String {
        "\(agent.machine) · \(agent.address)"
    }

    public static func access(_ request: AccessRequest) -> String {
        switch request.access {
        case .signIn: "Sign-in only, up to 30 min"
        case let .program(command): "Password to \(programName(command)), up to 30 min"
        case .agentProcess: "Password to \(request.agent.name)'s own code, up to 30 min"
        }
    }

    /// "gh" from "gh auth login --with-token" or "/usr/local/bin/gh auth …".
    public static func programName(_ command: String) -> String {
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        return executable.split(separator: "/").last.map(String.init) ?? executable
    }

    // MARK: The agent's claim

    public static func claimHeading(_ agent: RequestingAgent) -> String {
        "\(agent.name) says"
    }

    public static func claimFolder(_ folder: String) -> String {
        "Working in \(folder)"
    }

    /// Covers the agent's name, folder and reason: all come from the agent.
    public static let claimFootnote = "From the agent. Agent Keyring can't check it."

    // MARK: Answering

    public static let approve = "Approve"
    public static let deny = "Deny"
    public static let denyAndReply = "Deny and reply…"
    public static func replySheetTitle(_ agent: RequestingAgent) -> String { "Reply to \(agent.name)" }
    public static let replyPlaceholder = "Why not, or what to do instead"
    public static let denyAndSend = "Deny and send"
    public static let sending = "Sending…"
    public static let endNow = "End now"
    public static func askAgainUntil(_ date: Date) -> String {
        "New requests from this machine are held off until \(clock(date))."
    }
    public static let letAskAgain = "Let it ask again"

    // MARK: States

    public static let waitingForYou = "Waiting for you"

    public static func remaining(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }

    public static func minutesLeft(until deadline: Date, now: Date) -> String {
        let minutes = max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(minutes) min left"
    }

    /// One sentence for a request that has an outcome. Nil while waiting.
    public static func outcome(_ request: AccessRequest) -> String? {
        let agent = request.agent.name
        switch request.state {
        case .waitingForYou:
            return nil
        case .sendingAnswer(.approve):
            return "Approving…"
        case .sendingAnswer(.deny):
            return "Denying…"
        case let .approved(.automaticRule, until):
            return "Approved by rule. \(agent) can use it until \(clock(until))."
        case let .approved(_, until):
            return "Approved. \(agent) can use it until \(clock(until)), or until it says it's done."
        case let .denied(_, reply, _):
            return reply == nil ? "Denied. \(agent) was told." : "Denied. \(agent) got your reply."
        case .unanswered:
            return "Nobody answered, so \(agent) stopped waiting."
        case .cancelled:
            return "\(agent) stopped asking before you answered."
        case let .expired(at):
            return "Ended at \(clock(at)) after 30 minutes. \(agent) has to ask again."
        case let .released(at):
            return "\(agent) finished with it at \(clock(at))."
        case let .ended(at):
            return "You ended it at \(clock(at))."
        case .blockedByRule:
            return "Blocked by this login's rule. You weren't asked."
        }
    }

    /// One word for history rows.
    public static func outcomeWord(_ state: AccessRequestState) -> String {
        switch state {
        case .waitingForYou: "Waiting"
        case .sendingAnswer: "Sending"
        case .approved(.automaticRule, _): "Automatic"
        case .approved: "In use"
        case .denied: "Denied"
        case .unanswered: "Unanswered"
        case .cancelled: "Withdrawn"
        case .expired: "Expired"
        case .released: "Done"
        case .ended: "Ended"
        case .blockedByRule: "Blocked"
        }
    }

    public static func surface(_ surface: ApprovalSurface) -> String {
        switch surface {
        case .mac: "on your Mac"
        case .iPhone: "on this iPhone"
        case .automaticRule: "by rule"
        }
    }

    // MARK: Time

    /// 24-hour clock, whatever the region: "02:41".
    public static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// "Today 02:41", "Yesterday 23:50", "Tue 28 Oct 14:02".
    public static func dayAndClock(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today \(clock(date))" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(clock(date))" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + clock(date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
