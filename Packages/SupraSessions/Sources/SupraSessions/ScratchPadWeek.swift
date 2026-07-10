import Foundation

/// One visible week of the ScratchPad header's date strip: seven consecutive days
/// honoring the calendar's `firstWeekday`, with display labels precomputed so the
/// view stays dumb. Pure date math — no store access.
public struct ScratchPadWeek: Equatable, Sendable {
    /// One selectable day in the strip.
    public struct Day: Identifiable, Equatable, Sendable {
        /// Canonical "yyyy-MM-dd" key, matching `ScratchPadController.dayString`.
        public let id: String
        public let date: Date
        /// Abbreviated weekday with a terminal period ("Thu.").
        public let weekdayLabel: String
        /// Zero-padded day of month ("09").
        public let dayNumber: String
        public let isToday: Bool
        /// Days after today can't be billed; the strip renders them disabled.
        public let isFuture: Bool
    }

    public let days: [Day]
    /// The strip heading. Weeks spanning a month boundary name both months so a
    /// selected edge day can never appear to belong to the wrong month.
    public let monthLabel: String

    public var containsToday: Bool { days.contains(where: \.isToday) }

    /// The week containing `date`.
    public static func containing(_ date: Date, today: Date, calendar: Calendar) -> ScratchPadWeek {
        let calendar = canonicalCalendar(from: calendar)
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let dayFormatter = formatter("yyyy-MM-dd", calendar: calendar, posix: true)
        let weekdayFormatter = formatter("EEE", calendar: calendar)
        let numberFormatter = formatter("dd", calendar: calendar, posix: true)
        let todayStart = calendar.startOfDay(for: today)
        let days: [Day] = (0..<7).compactMap { offset in
            guard let dayDate = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return Day(
                id: dayFormatter.string(from: dayDate),
                date: dayDate,
                weekdayLabel: abbreviated(weekdayFormatter.string(from: dayDate)),
                dayNumber: numberFormatter.string(from: dayDate),
                isToday: calendar.isDate(dayDate, inSameDayAs: today),
                isFuture: calendar.startOfDay(for: dayDate) > todayStart
            )
        }
        return ScratchPadWeek(days: days, monthLabel: monthLabel(for: days, today: today, calendar: calendar))
    }

    /// The week containing a canonical "yyyy-MM-dd" day, or nil if unparseable.
    public static func containing(dayString: String, today: Date, calendar: Calendar) -> ScratchPadWeek? {
        guard let date = date(dayString: dayString, calendar: calendar) else {
            return nil
        }
        return containing(date, today: today, calendar: calendar)
    }

    /// The week `weeks` away from this one (the chevrons pass ±1).
    public func advanced(by weeks: Int, today: Date, calendar: Calendar) -> ScratchPadWeek {
        let calendar = Self.canonicalCalendar(from: calendar)
        guard let anchor = days.first?.date,
              let shifted = calendar.date(byAdding: .day, value: weeks * 7, to: anchor) else { return self }
        return Self.containing(shifted, today: today, calendar: calendar)
    }

    /// Converts user calendar preferences into the Gregorian calendar required by
    /// persisted ScratchPad day keys while retaining display and week conventions.
    static func canonicalCalendar(from preferences: Calendar) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = preferences.locale
        calendar.timeZone = preferences.timeZone
        calendar.firstWeekday = preferences.firstWeekday
        calendar.minimumDaysInFirstWeek = preferences.minimumDaysInFirstWeek
        return calendar
    }

    static func dayString(_ date: Date, calendar: Calendar) -> String {
        formatter("yyyy-MM-dd", calendar: canonicalCalendar(from: calendar), posix: true).string(from: date)
    }

    static func date(dayString: String, calendar: Calendar) -> Date? {
        formatter("yyyy-MM-dd", calendar: canonicalCalendar(from: calendar), posix: true).date(from: dayString)
    }

    /// Formats a day total for the indicator row: whole tenths read as billing
    /// tenths ("3.0", "0.5"); real hundredths (0.25h increments) survive ("1.25");
    /// float-summation noise normalizes away.
    public static func hoursLabel(_ hours: Double) -> String {
        let hundredths = (hours * 100).rounded() / 100
        let tenths = (hours * 10).rounded() / 10
        if abs(hundredths - tenths) < 0.0001 {
            return String(format: "%.1f", tenths)
        }
        return String(format: "%.2f", hundredths)
    }

    /// Guarantees a terminal period on an "EEE" symbol ("Thu" -> "Thu."); locales
    /// whose abbreviation already ends in punctuation (fr "jeu.") pass through.
    private static func abbreviated(_ symbol: String) -> String {
        guard let last = symbol.last, last.isLetter || last.isNumber else { return symbol }
        return symbol + "."
    }

    private static func monthLabel(for days: [Day], today: Date, calendar: Calendar) -> String {
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        let firstMonth = calendar.component(.month, from: first)
        let lastMonth = calendar.component(.month, from: last)
        let firstYear = calendar.component(.year, from: first)
        let lastYear = calendar.component(.year, from: last)
        let todayYear = calendar.component(.year, from: today)

        if firstMonth == lastMonth, firstYear == lastYear {
            let format = firstYear == todayYear ? "MMMM" : "MMMM yyyy"
            return formatter(format, calendar: calendar).string(from: first)
        }
        if firstYear == lastYear {
            let firstName = formatter("MMMM", calendar: calendar).string(from: first)
            let lastName = formatter("MMMM", calendar: calendar).string(from: last)
            let year = formatter("yyyy", calendar: calendar).string(from: last)
            return "\(firstName) - \(lastName) \(year)"
        }
        let firstName = formatter("MMMM yyyy", calendar: calendar).string(from: first)
        let lastName = formatter("MMMM yyyy", calendar: calendar).string(from: last)
        return "\(firstName) - \(lastName)"
    }

    /// Machine formats (`posix: true`) pin en_US_POSIX so day keys/numbers are
    /// stable Western digits; display formats follow the calendar's locale.
    private static func formatter(_ format: String, calendar: Calendar, posix: Bool = false) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = posix ? Locale(identifier: "en_US_POSIX") : (calendar.locale ?? .current)
        formatter.dateFormat = format
        return formatter
    }
}
