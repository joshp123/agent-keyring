#if os(macOS)
import AgentKeyringApprovalCore
import Foundation
import Observation
import UserNotifications
import OSLog

@MainActor
public protocol StalePasswordsReminderNotifying {
    /// Asks macOS to let Agent Keyring post notifications; true if it may.
    func requestPermission() async throws -> Bool
    func post(ageDays: Int) async throws
}

/// "Remind me to update passwords": off until he turns it on. Then, once the
/// copy is a week old, one notification, and no other for a week after it.
@MainActor
@Observable
public final class StalePasswordsReminders {
    /// A copy older than this is stale: the Passwords tab says so, and a reminder may come.
    static let staleAfter: TimeInterval = 7 * 86_400
    static let enabledKey = "remindToUpdatePasswords"
    static let lastKey = "mirrorSyncLastNotification"

    public private(set) var isEnabled: Bool
    @ObservationIgnored private let settings: UserDefaults
    @ObservationIgnored private let notifier: any StalePasswordsReminderNotifying
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var isPosting = false

    public init(settings: UserDefaults = .standard, notifier: any StalePasswordsReminderNotifying,
                now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.settings = settings
        self.notifier = notifier
        self.now = now
        self.calendar = calendar
        isEnabled = settings.bool(forKey: Self.enabledKey)
    }

    public static func isStale(importedAt: Date?, now: Date = .now) -> Bool {
        guard let importedAt else { return false }
        return now.timeIntervalSince(importedAt) > staleAfter
    }

    /// Turning it on asks macOS for permission to notify, and stays off if refused.
    public func setEnabled(_ on: Bool) async {
        if on, (try? await notifier.requestPermission()) != true {
            isEnabled = false
        } else {
            isEnabled = on
        }
        settings.set(isEnabled, forKey: Self.enabledKey)
    }

    public func check(importedAt: Date) async throws {
        let date = now()
        guard isEnabled, !isPosting, Self.isStale(importedAt: importedAt, now: date),
              (9..<21).contains(calendar.component(.hour, from: date)) else { return }
        if let last = settings.object(forKey: Self.lastKey) as? Date, date.timeIntervalSince(last) < Self.staleAfter { return }
        isPosting = true
        defer { isPosting = false }
        try await notifier.post(ageDays: max(0, Int(date.timeIntervalSince(importedAt) / 86_400)))
        settings.set(date, forKey: Self.lastKey)
    }
}

@MainActor
public final class SystemStalePasswordsReminderNotifier: NSObject, StalePasswordsReminderNotifying, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let openExport: () -> Void
    /// A computer's request pushed to this Mac: shown in the panel, never as a banner of its own.
    public var onRequest: (@MainActor ([AnyHashable: Any]) -> Void)?

    public init(openExport: @escaping () -> Void) {
        self.openExport = openExport
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: "export", title: MessageCopy.updateFromPasswords, options: .foreground)
        center.setNotificationCategories([UNNotificationCategory(identifier: "mirror-sync", actions: [action], intentIdentifiers: [])])
    }

    public func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func post(ageDays: Int) async throws {
        guard await center.notificationSettings().authorizationStatus == .authorized else {
            throw AgentBridgeFailure(.internalError, "Enable Agent Keyring notifications to ask \(MacOwner.firstName) to update the copy.")
        }
        let content = UNMutableNotificationContent()
        content.title = MessageCopy.copyIsOld(days: ageDays)
        content.body = MessageCopy.exportInstruction
        content.categoryIdentifier = "mirror-sync"
        try await center.add(UNNotificationRequest(identifier: "mirror-sync", content: content, trigger: nil))
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        if content.categoryIdentifier == "REQUEST" || content.userInfo["akr"] != nil {
            let info = SendableUserInfo(content.userInfo)
            Task { @MainActor in self.onRequest?(info.value) }
        } else if response.actionIdentifier == "export" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in self.openExport() }
        }
        completionHandler()
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        guard content.categoryIdentifier == "REQUEST" || content.userInfo["akr"] != nil else { return completionHandler([.banner, .list]) }
        let info = SendableUserInfo(content.userInfo)
        Task { @MainActor in self.onRequest?(info.value) }
        completionHandler([])
    }
}

/// A notification's user info, carried to the main actor.
struct SendableUserInfo: @unchecked Sendable {
    let value: [AnyHashable: Any]
    init(_ value: [AnyHashable: Any]) { self.value = value }
}

extension MacKeyringEngine {
    public func checkPasswordCopyFreshness() async {
        do {
            if let metadata = try await store.loadCurrentMetadata() {
                try await syncReminders?.check(importedAt: metadata.createdAt)
            }
        } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Sync").error("Vault freshness check failed: \(String(describing: error), privacy: .private)")
        }
    }
}
#endif
