// Written by AI on 2026.11.21 by model Claude Opus 5.5.

#if os(watchOS)
import AgentKeyringWatchCore
import Foundation

/// Every word Apple Watch shows, from master-copy-audit-21-nov.md. Apple Watch keeps no passwords, so no line
/// says it receives or syncs them.
public enum WatchCopy {
    public static func page(_ setup: WatchSetup) -> (title: String, detail: String?) {
        switch setup {
        case .noPasscode: ("Passcode needed", "Turn on a passcode for this Watch in Apple’s Watch app.")
        case .setUpIPhone: ("Set up iPhone first", "Set up Agent Keyring on your iPhone, then tap Add Apple Watch in Devices.")
        case .startOnIPhone: ("Start on your iPhone", "Open Agent Keyring on your iPhone, go to Devices, and tap Add Apple Watch.")
        case .readyToAdd: ("Add this Watch?", "Approve password requests on your wrist.")
        case .preparing: ("Preparing your Watch…", nil)
        case .notifications: ("Turn on notifications", "Allow notifications so requests reach your wrist.")
        case .notificationsOff: ("Notifications are off", "Turn them on in Settings on your Watch.")
        case .settingUpNotifications: ("Setting up notifications", "Apple is connecting this Watch for notifications. This usually takes a few seconds.")
        case .addedOfferPractice: ("Apple Watch added", "Ready for password requests.")
        case .practiceWaiting: ("Waiting for practice request…", nil)
        case .ready: ("Ready", "Requests appear here as notifications. Tap Approve or Deny.")
        }
    }
    static let continueButton = "Continue"
    static let add = "Add"
    static let tryPractice = "Try Practice"
    static let done = "Done"
    static let cancel = "Cancel"
    static let checkAgain = "Check Again"
    /// Not in the ledger: when Try Practice cannot reach the iPhone, or the iPhone cannot reach the Mac.
    static let practiceNotAsked = "Couldn’t send a practice request. Make sure your iPhone and Mac are awake with Tailscale on."
    static let deny = "Deny"
    static let approve = "Approve"
    static let denyAndExplain = "Deny and Explain"
    static let whatInstead = "What should the agent do instead?"
    static let unreadable = "Open Agent Keyring on your iPhone to see this request."
    static let practiceLead = "Practice request"
    public static func answered(approve: Bool, _ result: WatchAnswerResult) -> String {
        switch (approve, result) {
        case (_, .alreadyAnswered): "Already answered"
        case (true, .sent): "Approved"
        case (false, .sent): "Denied"
        case (true, .failed): "Not approved. Try on your iPhone."
        case (false, .failed): "Not sent. Try on your iPhone."
        }
    }
    static let inUse = "In use"
    static let stop = "Stop"
    /// Not in the ledger: when Stop can't reach the iPhone.
    static let stopFailed = "Couldn’t stop it. Try on your iPhone."
    static func until(_ date: Date) -> String {
        "until " + date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
    }
}
#endif
