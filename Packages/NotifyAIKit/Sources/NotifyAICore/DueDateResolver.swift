//
//  DueDateResolver.swift
//  NotifyAICore
//

import Foundation

/// Turns a spoken deadline ("bis Freitag", "3. Oktober", "next week") into a calendar day,
/// relative to the day the note was recorded.
///
/// Deadlines are stored as text because that is how they were said. Filtering tasks by due
/// date needs a date, and computing it with fixed calendar rules is reliable where a small
/// language model is not. Explicit dates win over relative words, because the summary adds
/// the calendar date to relative deadlines ("Freitag (3. Oktober 2026)").
///
/// Supported (German and English): ISO dates, `3.10.2026`, `3.10.`, `3. Oktober 2026`,
/// `October 3`, heute/today, morgen/tomorrow, übermorgen, weekdays (the next such day after
/// the recording), Ende der Woche/end of the week, nächste Woche/next week, Ende des
/// Monats/end of the month, in N Tagen/Wochen/Monaten, in N days/weeks/months (N also as a
/// word from two to twelve).
public struct DueDateResolver {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The start of the day the task is due, or `nil` if the text names no day.
    public func resolve(_ text: String, relativeTo reference: Date) -> Date? {
        let folded = " " + text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss") + " "
        let referenceDay = calendar.startOfDay(for: reference)

        if let date = explicitDate(in: folded, reference: referenceDay) {
            return date
        }
        return relativeDate(in: folded, reference: referenceDay)
    }

    // MARK: - Explicit dates

    private static let monthNames: [(names: [String], month: Int)] = [
        (["januar", "jan", "january", "janner"], 1),
        (["februar", "feb", "february"], 2),
        (["marz", "mar", "march", "maerz"], 3),
        (["april", "apr"], 4),
        (["mai", "may"], 5),
        (["juni", "jun", "june"], 6),
        (["juli", "jul", "july"], 7),
        (["august", "aug"], 8),
        (["september", "sep", "sept"], 9),
        (["oktober", "okt", "october", "oct"], 10),
        (["november", "nov"], 11),
        (["dezember", "dez", "december", "dec"], 12),
    ]

    private func explicitDate(in text: String, reference: Date) -> Date? {
        // 2026-10-03
        if let match = text.firstMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/),
           let date = makeDate(year: Int(match.1), month: Int(match.2), day: Int(match.3)) {
            return date
        }
        // 3.10.2026, 3.10.26, 3.10.
        if let match = text.firstMatch(of: /(?:^|[^\d.])(\d{1,2})\.(\d{1,2})\.(\d{2,4})?(?!\d)/) {
            let day = Int(match.1)
            let month = Int(match.2)
            let year = match.3.flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
            if let date = dateWithOptionalYear(day: day, month: month, year: year, reference: reference) {
                return date
            }
        }
        // 3. Oktober 2026, 3 October. Other words after a number ("in 3 Tagen") are skipped.
        for match in text.matches(of: /(?:^|\D)(\d{1,2})\.?\s+([a-z]+)\.?(?:\s+(\d{4}))?/) {
            if let month = Self.month(named: String(match.2)),
               let date = dateWithOptionalYear(day: Int(match.1), month: month, year: match.3.flatMap { Int($0) }, reference: reference) {
                return date
            }
        }
        // October 3, 2026
        for match in text.matches(of: /([a-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?(?!\d)/) {
            if let month = Self.month(named: String(match.1)),
               let date = dateWithOptionalYear(day: Int(match.2), month: month, year: match.3.flatMap { Int($0) }, reference: reference) {
                return date
            }
        }
        return nil
    }

    private static func month(named name: String) -> Int? {
        monthNames.first { $0.names.contains(name) }?.month
    }

    /// Without a year, the next occurrence on or after the recording day.
    private func dateWithOptionalYear(day: Int?, month: Int?, year: Int?, reference: Date) -> Date? {
        if let year {
            return makeDate(year: year, month: month, day: day)
        }
        let referenceYear = calendar.component(.year, from: reference)
        guard let thisYear = makeDate(year: referenceYear, month: month, day: day) else { return nil }
        return thisYear >= reference ? thisYear : makeDate(year: referenceYear + 1, month: month, day: day)
    }

    private func makeDate(year: Int?, month: Int?, day: Int?) -> Date? {
        guard let year, let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil } // rejects 31.2.
        return calendar.startOfDay(for: date)
    }

    // MARK: - Relative dates

    private static let weekdays: [(names: [String], weekday: Int)] = [
        ([" sonntag", " sunday"], 1),
        ([" montag", " monday"], 2),
        ([" dienstag", " tuesday"], 3),
        ([" mittwoch", " wednesday"], 4),
        ([" donnerstag", " thursday"], 5),
        ([" freitag", " friday"], 6),
        ([" samstag", " sonnabend", " saturday"], 7),
    ]

    /// Spelled-out counts in "in zwei Wochen". "ein"/"einem" are left out on purpose: "in
    /// einem Monat" is usually meant vaguely and stays unresolved.
    private static let numberWords: [String: Int] = [
        "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "fuenf": 5, "sechs": 6, "sieben": 7, "acht": 8,
        "neun": 9, "zehn": 10, "elf": 11, "zwolf": 12, "zwoelf": 12,
        "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    private func relativeDate(in text: String, reference: Date) -> Date? {
        func contains(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        func days(_ count: Int) -> Date? { calendar.date(byAdding: .day, value: count, to: reference) }

        if let match = text.firstMatch(of: /\bin\s+([a-z]+|\d{1,3})\s+(tag|tagen|day|days|woche|wochen|week|weeks|monat|monaten|month|months)\b/),
           let count = Int(match.1) ?? Self.numberWords[String(match.1)] {
            let unit = String(match.2)
            if unit.hasPrefix("tag") || unit.hasPrefix("day") { return days(count) }
            if unit.hasPrefix("woche") || unit.hasPrefix("week") { return days(count * 7) }
            return calendar.date(byAdding: .month, value: count, to: reference)
        }
        if contains([" ubermorgen", " uebermorgen", " day after tomorrow"]) { return days(2) }
        if contains([" morgen ", " morgen,", " morgen.", " tomorrow"]) { return days(1) }
        if contains([" heute", " today", " sofort", " asap", " immediately"]) { return reference }
        if contains([" monatsende", " ende des monats", " ende monat", " end of the month", " end of month"]) {
            return endOfMonth(reference)
        }
        if contains([" nachste woche", " naechste woche", " kommende woche", " next week"]) {
            return days(7).flatMap { endOfWorkWeek($0) }
        }
        if contains([" ende der woche", " diese woche", " end of the week", " end of week", " this week", " wochenende"]) {
            return endOfWorkWeek(reference)
        }
        for entry in Self.weekdays where entry.names.contains(where: { text.contains($0) }) {
            return next(weekday: entry.weekday, after: reference)
        }
        return nil
    }

    /// The next such weekday strictly after `reference`: "bis Freitag", said on a Friday,
    /// means the following Friday.
    private func next(weekday: Int, after reference: Date) -> Date? {
        let current = calendar.component(.weekday, from: reference)
        var distance = (weekday - current + 7) % 7
        if distance == 0 { distance = 7 }
        return calendar.date(byAdding: .day, value: distance, to: reference)
    }

    /// Friday of the week containing `date` (or `date` itself on a weekend).
    private func endOfWorkWeek(_ date: Date) -> Date? {
        let weekday = calendar.component(.weekday, from: date)
        let friday = 6
        if weekday == 7 || weekday == 1 { return date }
        return calendar.date(byAdding: .day, value: friday - weekday, to: date)
    }

    private func endOfMonth(_ date: Date) -> Date? {
        guard let range = calendar.range(of: .day, in: .month, for: date),
              let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))
        else { return nil }
        return calendar.date(byAdding: .day, value: range.count - 1, to: start)
    }
}
