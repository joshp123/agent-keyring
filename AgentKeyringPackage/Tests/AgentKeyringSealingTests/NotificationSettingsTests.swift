// Written by AI on 2026.11.19 by model claude opus 5.5.
// Whether a request breaks through a Focus, from the iPhone's two settings,
// at the times he would set: quiet hours across midnight.

import AgentKeyringSealing
import Foundation
import Testing

struct NotificationSettingsTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()

    func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: hour, minute: minute))!
    }

    @Test func timeSensitiveByDefault() {
        #expect(NotificationSettings().breaksThroughFocus(at: at(3, 0), calendar: calendar))
    }

    @Test func offMeansNever() {
        var settings = NotificationSettings()
        settings.timeSensitive = false
        #expect(!settings.breaksThroughFocus(at: at(12, 0), calendar: calendar))
    }

    @Test func quietHoursAcrossMidnight() {
        var settings = NotificationSettings()
        settings.quietHours = true  // 23:00 to 07:00
        #expect(!settings.breaksThroughFocus(at: at(23, 0), calendar: calendar))
        #expect(!settings.breaksThroughFocus(at: at(2, 30), calendar: calendar))
        #expect(!settings.breaksThroughFocus(at: at(6, 59), calendar: calendar))
        #expect(settings.breaksThroughFocus(at: at(7, 0), calendar: calendar))
        #expect(settings.breaksThroughFocus(at: at(22, 59), calendar: calendar))
    }
}
