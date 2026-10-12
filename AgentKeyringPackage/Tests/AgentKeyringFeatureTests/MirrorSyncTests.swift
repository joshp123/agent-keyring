import Foundation
import Testing
@testable import AgentKeyringFeature

@MainActor
final class FakeSyncNotifier: MirrorSyncNotifying {
    var ages: [Int] = []
    func post(ageDays: Int) async throws { ages.append(ageDays) }
}

@Suite("Mirror freshness")
@MainActor
struct MirrorSyncTests {
    @Test("Daily reminders respect age and local hours", arguments: [8, 9, 20, 21])
    func window(hour: Int) async throws {
        let settings = UserDefaults(suiteName: UUID().uuidString)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: hour))!
        let notifier = FakeSyncNotifier()
        let reminders = MirrorSyncReminders(settings: settings, notifier: notifier, now: { date }, calendar: calendar)
        try await reminders.check(importedAt: date.addingTimeInterval(-7 * 86_400))
        #expect(notifier.ages.isEmpty)
        try await reminders.check(importedAt: date.addingTimeInterval(-7 * 86_400 - 1))
        #expect(notifier.ages == ((9..<21).contains(hour) ? [7] : []))
    }

    @Test("A restart cannot post twice on one day; the next day can post")
    func cadence() async throws {
        let settings = UserDefaults(suiteName: UUID().uuidString)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        let imported = date.addingTimeInterval(-93 * 86_400)
        let notifier = FakeSyncNotifier()
        let reminders = MirrorSyncReminders(settings: settings, notifier: notifier, now: { date }, calendar: calendar)
        try await reminders.check(importedAt: imported)
        try await reminders.check(importedAt: imported)
        let restarted = MirrorSyncReminders(settings: settings, notifier: notifier, now: { date }, calendar: calendar)
        try await restarted.check(importedAt: imported)
        #expect(notifier.ages == [93])
        date = date.addingTimeInterval(86_400)
        try await restarted.check(importedAt: imported)
        #expect(notifier.ages == [93, 94])
    }
}
