import Foundation

enum AppCalendar {
    static var current: Calendar {
        gregorian(matching: .current)
    }

    static func gregorian(matching calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.locale = calendar.locale
        gregorian.timeZone = calendar.timeZone
        gregorian.firstWeekday = calendar.firstWeekday
        gregorian.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        return gregorian
    }

    static func dateFormatter(calendar: Calendar = current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = gregorian(matching: calendar)
        return formatter
    }

    static func mediaYearRange(now: Date = Date(), calendar: Calendar = current) -> ClosedRange<Int> {
        1950...max(1950, gregorian(matching: calendar).component(.year, from: now))
    }
}
