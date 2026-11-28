// Written by AI on 2026.10.31 by model Claude Opus 5.5.
//
// Request words the Mac's request panel and menu bar use.

import AgentKeyringApprovalCore
import Foundation

public enum AccessRequestCopy {
    public static let letAskAgain = "Let it ask again"

    // The request panel
    /// Concise requester line: "Codex · Mac mini", or "Codex · This Mac".
    public static func wants(_ agent: RequestingAgent) -> String {
        let name = agent.name.prefix(1).uppercased() + agent.name.dropFirst()
        return agent.isLocal ? "\(name) · This Mac" : "\(name) · \(agent.machine)"
    }
    public static func replyPlaceholder(_ agent: String) -> String {
        SharedCopy.replyPlaceholder
    }
    public static let replyPlaceholderShort = SharedCopy.replyPlaceholder
    /// The practice request's agent, in "You told the agent: …".
    public static let theAgent = "the agent"
    /// In place of the green button while the lid is shut.
    public static let openTheLid = "Touch ID isn’t available while your MacBook lid is closed. Open the lid to approve."
    public static let approveElsewhere = "Touch ID isn’t available while your MacBook lid is closed. Approve on your iPhone or Apple Watch, or open the lid."
    public static let deny = SharedCopy.deny
    public static let denyAndReply = SharedCopy.denyAndReply
    public static let approve = SharedCopy.approve
    public static let denying = "Denying…"
    public static let approving = "Approving…"
    public static let clickForTouchID = "Click to approve with Touch ID"
    public static let useTouchID = "Use Touch ID…"
    public static let clickForWatch = "Click to approve on Apple Watch"
    public static let useWatch = "Approve on Apple Watch…"
    public static let clickForPassword = "Click to approve with Mac password"
    public static let usePassword = "Enter Mac password…"
    public static let noApprover = "Touch ID and Apple Watch aren’t available"
    public static func moreWaiting(_ count: Int) -> String { "+\(count.formatted()) waiting" }
    /// In place of the green button while a Mac with Touch ID keys has no Touch ID keyboard connected.
    public static let connectTouchID = "Connect your Touch ID keyboard to approve"
    /// When macOS can't ask at all.
    public static func approverUnavailable(_ mode: MacApprovalMode = .current) -> String {
        mode == .devicePassword ? "macOS couldn’t ask for your Mac password. Try again."
            : "Touch ID or Apple Watch isn’t available. Check that one is ready."
    }
    #if os(macOS)
    /// The green button, before and after the click; nil when nothing can approve here.
    public static func approveTitle(_ approver: MacApproverKind, waiting: Bool) -> String? {
        switch approver {
        case .touchID: waiting ? useTouchID : clickForTouchID
        case .watch: waiting ? useWatch : clickForWatch
        case .password: waiting ? usePassword : clickForPassword
        case .none: nil
        }
    }

    /// The biometric glyph shown beside Approve on the Mac.
    public static func approveSymbol(_ approver: MacApproverKind) -> String? {
        switch approver {
        case .touchID: "touchid"
        case .watch: "applewatch"
        case .password: "key.fill"
        case .none: nil
        }
    }
    #endif
    public static func footer(_ agent: String) -> String { "\(agent) can use this password for this task." }
    public static let approved = SharedCopy.approved
    public static let approvedOnPhone = "Approved on your iPhone"
    public static let approvedOnWatch = "Approved on your Apple Watch"
    public static let denied = SharedCopy.denied
    public static let noAnswer = SharedCopy.noAnswer
    public static let cancelled = SharedCopy.cancelled
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
        case .sendingAnswer: SharedCopy.sending
        case .waitingForMac: SharedCopy.waitingForMac
        case .approved, .expired, .released: SharedCopy.approved
        case .denied: SharedCopy.denied
        case .unanswered: SharedCopy.noAnswer
        case .cancelled: SharedCopy.cancelled
        case .ended: SharedCopy.ended
        case .blockedByRule: SharedCopy.ruleBlocked
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

/// The words of the menu bar window (MacMenuBarView), from the copy ledger of
/// 21 November 2026 ("Mac Menu Bar Popover"). Rewritten on 2026.11.21 by model
/// claude opus 5.5 for the direct design: no relay and no computer that stays on.
public enum MenuBarCopy {
    public static let appName = SharedCopy.appName
    public static func waiting(_ count: Int) -> String { SharedCopy.requestsWaiting(count) }
    public static let allQuiet = SharedCopy.noRequestsWaiting
    public static let waitingForYou = SharedCopy.waiting
    public static let earlierToday = SharedCopy.today
    public static let nothing = SharedCopy.noRequestsWaiting
    public static let show = "Show"
    public static let dontAdd = "Don’t Add"
    public static let add = "Add"
    public static let deny = SharedCopy.deny
    public static let denyAndReply = SharedCopy.denyAndReply
    public static let approve = SharedCopy.approve
    public static let autoApproved = "Auto-approved"
    public static let sendReply = SharedCopy.denyAndSend
    public static let replyPrompt = SharedCopy.replyPlaceholder
    public static let passwordsTitle = SharedCopy.passwords
    public static func passwords(_ count: Int) -> String { count == 1 ? "1 password" : "\(count.formatted()) passwords" }
    public static let devices = SharedCopy.devices
    public static let activity = SharedCopy.activity
    public static let openApp = "Open Agent Keyring"
    public static let more = "More"
    public static let copyAgain = "Add from Apple Passwords…"
    public static let checkForUpdates = "Check for Updates…"
    public static let quit = "Quit Agent Keyring"
    /// On a denial that still holds the password off for that computer (right-click).
    public static let letAskAgain = "Let It Ask Again"

    // How a request earlier today ended
    public static let approved = SharedCopy.approved
    public static let denied = SharedCopy.denied
    public static let automatic = SharedCopy.ruleAlwaysAllowed
    public static let stopped = SharedCopy.ended
    public static let noAnswer = SharedCopy.noAnswer
    public static let cancelled = SharedCopy.cancelled
    public static let blocked = SharedCopy.ruleBlocked
    public static let sending = SharedCopy.sending
    public static let waitingForMac = SharedCopy.waitingForMac

    /// "Codex · Mac mini", "Claude Code · This Mac".
    public static func who(_ request: AccessRequest) -> String {
        "\(request.agent.name) · \(request.agent.isLocal ? "This Mac" : request.agent.machine)"
    }

    /// "Codex on Mac mini · You asked me to download October’s invoice."
    public static func waitingDetail(_ request: AccessRequest) -> String {
        request.agentReason.isEmpty ? who(request) : "\(who(request)) · \(request.agentReason)"
    }

    /// "shop.example · 13:40".
    public static func earlier(_ request: AccessRequest) -> String { "\(request.login.site) · \(AccessRequestCopy.clock(request.askedAt))" }
}

extension AccessRequest {
    /// First run's practice request on the Mac, in FirstRunCopy's words.
    public static func practiceAccessRequest(id: String, state: AccessRequestState) -> AccessRequest {
        AccessRequest(id: id, login: RequestedLogin(site: FirstRunCopy.practiceSite, account: FirstRunCopy.practiceAccount),
            agent: RequestingAgent(name: FirstRunCopy.practiceAgent, machine: "", address: "", isLocal: true),
            access: .practice, agentReason: FirstRunCopy.practiceReason, askedAt: .now, state: state)
    }
}
