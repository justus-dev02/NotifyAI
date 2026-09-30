//
//  DueDateResolverTests.swift
//  NotifyAICoreTests
//

import Foundation
import NotifyAICore
import Testing

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    calendar.firstWeekday = 2
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Wednesday, 30 September 2026, in the afternoon.
private let recordedAt = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15))!

@Suite("Due dates from spoken deadlines")
struct DueDateResolverTests {
    private let resolver = DueDateResolver(calendar: calendar)

    @Test("Relative deadlines", arguments: [
        ("heute", day(2026, 9, 30)),
        ("ASAP", day(2026, 9, 30)),
        ("morgen", day(2026, 10, 1)),
        ("tomorrow", day(2026, 10, 1)),
        ("übermorgen", day(2026, 10, 2)),
        ("bis Freitag", day(2026, 10, 2)),
        ("Friday", day(2026, 10, 2)),
        // Said on a Wednesday, "Mittwoch" means the next one.
        ("Mittwoch", day(2026, 10, 7)),
        ("next Monday", day(2026, 10, 5)),
        ("Ende der Woche", day(2026, 10, 2)),
        ("nächste Woche", day(2026, 10, 9)),
        ("next week", day(2026, 10, 9)),
        ("Ende des Monats", day(2026, 9, 30)),
        ("in 3 Tagen", day(2026, 10, 3)),
        ("in 2 weeks", day(2026, 10, 14)),
        ("in einem Monat", nil),
    ])
    func relative(text: String, expected: Date?) {
        #expect(resolver.resolve(text, relativeTo: recordedAt) == expected)
    }

    @Test("Explicit dates win over relative words", arguments: [
        ("3.10.", day(2026, 10, 3)),
        ("03.10.2027", day(2027, 10, 3)),
        ("1.9.", day(2027, 9, 1)),
        ("3. Oktober", day(2026, 10, 3)),
        ("Freitag (2. Oktober 2026)", day(2026, 10, 2)),
        ("October 5, 2026", day(2026, 10, 5)),
        ("2026-11-02", day(2026, 11, 2)),
        ("31.2.", nil),
        ("irgendwann", nil),
    ])
    func explicit(text: String, expected: Date?) {
        #expect(resolver.resolve(text, relativeTo: recordedAt) == expected)
    }
}
