import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class AppCalendarTests: XCTestCase {
    private let identifiers: [Calendar.Identifier] = [
        .gregorian, .buddhist, .chinese, .coptic, .ethiopicAmeteMihret,
        .ethiopicAmeteAlem, .hebrew, .iso8601, .indian, .islamic,
        .islamicCivil, .japanese, .persian, .republicOfChina,
        .islamicTabular, .islamicUmmAlQura
    ]

    func testMediaYearsStayGregorianForEverySystemCalendar() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z"))
        for identifier in identifiers {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            let years = AppCalendar.mediaYearRange(now: now, calendar: calendar)
            XCTAssertEqual(years, 1950...2026, "\(identifier)")
            XCTAssertEqual(Array(years.reversed()).first, 2026)
            XCTAssertEqual(Array(years.reversed()).last, 1950)
        }
    }

    func testMediaYearRangeRemainsValidWithAnEarlyDeviceDate() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "1900-01-01T12:00:00Z"))
        XCTAssertEqual(AppCalendar.mediaYearRange(now: now), 1950...1950)
    }

    func testGregorianCalendarPreservesRegionalWeekAndTimeZonePreferences() throws {
        var calendar = Calendar(identifier: .islamic)
        calendar.locale = Locale(identifier: "ar_SA")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Riyadh"))
        calendar.firstWeekday = 7
        calendar.minimumDaysInFirstWeek = 4
        let gregorian = AppCalendar.gregorian(matching: calendar)
        XCTAssertEqual(gregorian.identifier, .gregorian)
        XCTAssertEqual(gregorian.locale, calendar.locale)
        XCTAssertEqual(gregorian.timeZone, calendar.timeZone)
        XCTAssertEqual(gregorian.firstWeekday, calendar.firstWeekday)
        XCTAssertEqual(gregorian.minimumDaysInFirstWeek, calendar.minimumDaysInFirstWeek)
    }

    func testFormattersParseAndDisplayGregorianDatesWithNonGregorianLocales() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z"))
        for identifier in ["en_US@calendar=buddhist", "en_US@calendar=japanese", "en_US@calendar=islamic", "en_US@calendar=hebrew"] {
            let locale = Locale(identifier: identifier)
            let formatter = AppCalendar.dateFormatter(calendar: locale.calendar)
            formatter.locale = locale
            formatter.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
            formatter.dateFormat = "yyyy-MM-dd"
            XCTAssertEqual(formatter.string(from: now), "2026-10-04", identifier)
            let parsed = try XCTUnwrap(formatter.date(from: "2026-10-04"))
            XCTAssertEqual(AppCalendar.current.component(.year, from: parsed), 2026, identifier)
            let style = Date.FormatStyle(
                date: .abbreviated,
                time: .shortened,
                locale: locale,
                calendar: AppCalendar.gregorian(matching: locale.calendar),
                timeZone: formatter.timeZone
            )
            XCTAssertTrue(now.formatted(style).contains("2026"), identifier)
        }
    }

    func testScheduleWindowsIgnoreNonGregorianCalendarIdentifiers() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T06:00:00Z"))
        for timeZone in ["America/New_York", "Asia/Tokyo", "Pacific/Kiritimati"] {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
            for identifier in identifiers {
                var calendar = Calendar(identifier: identifier)
                calendar.timeZone = gregorian.timeZone
                for days in [1, 7, 30, 366] {
                    XCTAssertEqual(
                        ScheduleDateWindow.envelope(dayCount: days, now: now, localCalendar: calendar),
                        ScheduleDateWindow.envelope(dayCount: days, now: now, localCalendar: gregorian),
                        "\(identifier) \(timeZone) \(days)"
                    )
                }
            }
        }
    }
}
