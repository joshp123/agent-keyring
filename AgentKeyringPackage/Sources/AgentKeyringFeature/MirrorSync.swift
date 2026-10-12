import Foundation
import UserNotifications
import OSLog

@MainActor
public protocol MirrorSyncNotifying {
    func post(ageDays: Int) async throws
}

@MainActor
public final class MirrorSyncReminders {
    public static let exportInstruction = "File → Export All Items to App → Agent Keyring"
    private let settings: UserDefaults
    private let notifier: any MirrorSyncNotifying
    private let now: () -> Date
    private let calendar: Calendar
    private var isPosting = false

    public init(settings: UserDefaults = .standard, notifier: any MirrorSyncNotifying,
                now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.settings = settings
        self.notifier = notifier
        self.now = now
        self.calendar = calendar
    }

    public func check(importedAt: Date) async throws {
        let date = now()
        let hour = calendar.component(.hour, from: date)
        guard date.timeIntervalSince(importedAt) > 7 * 86_400,
              (9..<21).contains(hour) else { return }
        try await notify(importedAt: importedAt)
    }

    func notify(importedAt: Date, immediately: Bool = false) async throws {
        let date = now()
        guard !isPosting else { return }
        if !immediately, let last = settings.object(forKey: "mirrorSyncLastNotification") as? Date,
           calendar.isDate(last, inSameDayAs: date) { return }
        isPosting = true
        defer { isPosting = false }
        try await notifier.post(ageDays: max(0, Int(date.timeIntervalSince(importedAt) / 86_400)))
        settings.set(date, forKey: "mirrorSyncLastNotification")
    }
}

@MainActor
public final class SystemMirrorSyncNotifier: NSObject, MirrorSyncNotifying, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let openExport: () -> Void

    public init(openExport: @escaping () -> Void) {
        self.openExport = openExport
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: "export", title: "Update from Passwords", options: .foreground)
        center.setNotificationCategories([UNNotificationCategory(identifier: "mirror-sync", actions: [action], intentIdentifiers: [])])
    }

    public func post(ageDays: Int) async throws {
        guard try await center.requestAuthorization(options: [.alert, .sound]) else {
            throw AgentBridgeFailure(.internalError, "Enable Agent Keyring notifications to ask Josh to update the copy.")
        }
        let content = UNMutableNotificationContent()
        content.title = "Agent Keyring's copy of your passwords is \(ageDays) days old."
        content.body = MirrorSyncReminders.exportInstruction
        content.categoryIdentifier = "mirror-sync"
        try await center.add(UNNotificationRequest(identifier: "mirror-sync", content: content, trigger: nil))
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "export" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in self.openExport() }
        }
        completionHandler()
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

extension MirrorAppModel {
    public func checkMirrorFreshness() async {
        do {
            if let metadata = try await store.loadCurrentMetadata() {
                try await syncReminders?.check(importedAt: metadata.createdAt)
            }
        } catch {
            Logger(subsystem: "com.agentkeyring.app", category: "Sync").error("Mirror freshness check failed: \(String(describing: error), privacy: .private)")
        }
    }
}
