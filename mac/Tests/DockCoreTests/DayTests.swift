import Testing
@testable import DockCore

@Test func dayRoundTripsAndDoesArithmetic() {
    let d = Day(iso: "2026-02-28")!
    #expect(d.adding(days: 1).iso == "2026-03-01")
    #expect(Day(iso: "2024-02-28")!.adding(days: 1).iso == "2024-02-29")
    #expect(Day(iso: "2026-03-01")!.days(since: Day(iso: "2025-03-01")!) == 365)
    #expect(Day(ordinal: 0).iso == "1970-01-01")
    #expect(Day(iso: "2026-02-30") == nil)
    #expect(Day(iso: "nope") == nil)
}

@Test func dayFormatsLikePythonStrftime() {
    #expect(Day(2026, 5, 20).long == "20 May 2026")
    #expect(Day(2026, 9, 3).short == "3 Sep 2026")
    #expect(Day(2025, 11, 2).monthYear == "November 2025")
}

@Test func localTimeIsoMatchesPythonIsoformat() {
    #expect(LocalTime(Day(2026, 1, 10), 9, 5, 7).iso == "2026-01-10T09:05:07")
}
