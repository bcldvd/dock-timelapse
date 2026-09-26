import Foundation
import Testing
@testable import DockCore

let today = chars("abcdefghij")

@Test func inventedHistoryEndsWithTodayAndKeepsEnds() {
    let h = inventHistory(today, count: 7, seed: 3)
    #expect(h.count == 7)
    #expect(h.last!.daysAgo == 0 && h.last!.dock == today)
    #expect(h.map(\.daysAgo) == h.map(\.daysAgo).sorted(by: >))
    for (_, dock) in h { #expect(dock.first == today.first && dock.last == today.last) }
    for (a, b) in zip(h, h.dropFirst()) { #expect(a.dock != b.dock) }
}

@Test func inventedHistoryIsDeterministicPerSeed() {
    #expect(inventHistory(today, seed: 5).map(\.dock) == inventHistory(today, seed: 5).map(\.dock))
    #expect(inventHistory(today, seed: 5).map(\.dock) != inventHistory(today, seed: 6).map(\.dock))
}

@Test(arguments: [0, 1, 2, 3, 12]) func inventHistorySurvivesTinyDocks(_ n: Int) {
    for seed in 0..<50 {
        let h = inventHistory(Array(chars("abcdefghijkl").prefix(n)), seed: UInt64(seed))
        #expect(h.last!.dock.count == n)
    }
}

@Test func buildPreviewWritesARenderableHistory() throws {
    let dir = tempDir()
    let mac = FakeMac(today, installed: Set(today.map(\.path) + classicApps.map(\.path)))
    let store = try buildPreview(at: dir, mac: mac, today: Day(2026, 9, 26))
    let snaps = try store.snapshots()
    #expect(snaps.count == 7 && snaps.last!.date == "2026-09-26" && snaps.last!.apps == today)
    #expect(snaps.allSatisfy { s in s.apps.allSatisfy { s.icons[$0.key] != nil } })
    #expect(try Timeline(buildScenes(snaps)).duration > 10)
}
