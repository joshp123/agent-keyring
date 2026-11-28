// Written by AI on 2026.11.19 by model Claude Opus 5.5.
//
// The iPhone's two notification settings (Paper, "On iPhone and Apple
// Watch", iPhone, Settings). The iPhone's notification service extension
// and Apple Watch's both read them to decide whether a request may break
// through a Focus.

import Foundation

public struct NotificationSettings: Hashable, Sendable {
    /// Requests may break through a Focus, such as Sleep.
    public var timeSensitive = true
    /// During quiet hours requests arrive without breaking through a Focus.
    public var quietHours = false
    /// Minutes after midnight, local time.
    public var quietFrom = 23 * 60
    public var quietTo = 7 * 60

    public init() {}

    /// Whether a request arriving at `date` should be Time Sensitive.
    public func breaksThroughFocus(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard timeSensitive else { return false }
        guard quietHours else { return true }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let inQuiet = quietFrom <= quietTo ? (now >= quietFrom && now < quietTo) : (now >= quietFrom || now < quietTo)
        return !inQuiet
    }
}
