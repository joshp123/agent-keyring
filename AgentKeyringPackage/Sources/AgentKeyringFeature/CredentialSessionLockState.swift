import AppKit
import CoreGraphics
import Foundation

@MainActor
public protocol CredentialSessionLockState {
    var isLocked: Bool { get }
    var isDisplayAsleep: Bool { get }
    var changes: AsyncStream<Void> { get }
}

public extension CredentialSessionLockState {
    var isDisplayAsleep: Bool { false }
    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }
}

public struct SystemCredentialSessionLockState: CredentialSessionLockState {
    public init() {}

    public var isDisplayAsleep: Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
    public var isLocked: Bool {
        isDisplayAsleep || Self.isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    public var changes: AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let observers = SessionStateObservers(notifications: [
            (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ], continuation: continuation)
        continuation.onTermination = { _ in observers.stop() }
        return stream
    }

    static func isLocked(session: [String: Any]?) -> Bool {
        guard let session else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

// NotificationCenter supports removing observers from the stream's termination callback.
private final class SessionStateObservers: @unchecked Sendable {
    private let observers: [(NotificationCenter, NSObjectProtocol)]
    init(notifications: [(NotificationCenter, Notification.Name)], continuation: AsyncStream<Void>.Continuation) {
        observers = notifications.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { _ in continuation.yield(()) })
        }
    }
    func stop() { for (center, observer) in observers { center.removeObserver(observer) } }
}
