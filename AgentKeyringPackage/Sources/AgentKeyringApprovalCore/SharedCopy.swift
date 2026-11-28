// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// Single source of truth for product vocabulary shared across Mac, iPhone, and
// Apple Watch so copy cannot drift between platforms.

import Foundation

public enum SharedCopy {
    public static let appName = "Agent Keyring"

    // MARK: Rules

    public static let ruleAskFirst = "Ask First"
    public static let ruleAlwaysAllowed = "Always Allowed"
    public static let ruleBlocked = "Blocked"

    public static let ruleAskFirstShort = "You approve each request."
    public static let ruleAlwaysAllowedShort = "Agents get it without asking."
    public static let ruleBlockedShort = "No agent can use it. Its copy here is deleted."

    // MARK: Navigation & Sections

    public static let activity = "Activity"
    public static let passwords = "Passwords"
    public static let devices = "Devices"
    public static let categories = "Categories"
    public static let settings = "Settings"
    public static let all = "All"

    public static let waiting = "Waiting"
    public static let today = "Today"
    public static let recent = "Recent"

    public static let whereYouApprove = "Where you approve"
    public static let agentComputers = "Agent computers"

    // MARK: Request Actions & Status

    public static let approve = "Approve"
    public static let deny = "Deny"
    public static let denyAndReply = "Deny & Reply"
    public static let denyAndSend = "Deny & Send"
    public static let replyPlaceholder = "Reply…"

    public static let approved = "Approved"
    public static let denied = "Denied"
    public static let ended = "Ended"
    public static let noAnswer = "No answer"
    public static let cancelled = "Cancelled"
    public static let sending = "Sending…"
    public static let waitingForMac = "Waiting for Mac…"

    public static let noRequestsWaiting = "No requests waiting"
    public static func requestsWaiting(_ count: Int) -> String {
        count == 1 ? "1 request waiting" : "\(count.formatted()) requests waiting"
    }

    // MARK: Common Actions

    public static let cancel = "Cancel"
    public static let close = "Close"
    public static let done = "Done"
    public static let ok = "OK"
    public static let save = "Save"
    public static let remove = "Remove"

    // MARK: Honest Analytics Disclosure (matches VersionCheck.swift)

    public static let analyticsTitle = "Share anonymous user count"
    public static let analyticsDetail = "Sends one anonymous ping a day so we know Agent Keyring is in use. We don’t send any passwords, sites, IP addresses, or any other usage data."
}
