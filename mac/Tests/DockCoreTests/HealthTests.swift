import Foundation
import Testing
@testable import DockCore

@Suite struct HealthTests {
    let dir = tempDir()
    let now = LocalTime(Day(2026, 9, 26), 12)

    func log(_ lines: String...) throws {
        for line in lines { CaptureLog.append(line, to: dir) }
    }

    @Test func recentCaptureIsHealthy() throws {
        try log("2026-09-25T09:00:00 error: Couldn't read the Dock's settings.", "2026-09-26T11:00:00 unchanged")
        #expect(recorderHealth(dataDir: dir, now: now) == .healthy)
    }

    @Test func noCaptureForMoreThanADayIsStale() throws {
        try log("2026-09-25T09:00:00 saved")
        #expect(recorderHealth(dataDir: dir, now: now) == .stale(last: LocalTime(Day(2026, 9, 25), 9)))
    }

    @Test func lastCaptureFailingIsReported() throws {
        try log("2026-09-26T10:00:00 saved", "2026-09-26T11:00:00 error: Couldn't read the Dock's settings.")
        #expect(recorderHealth(dataDir: dir, now: now) == .failing("Couldn't read the Dock's settings."))
    }

    @Test func withoutALogTheCheckedDaysTell() throws {
        #expect(recorderHealth(dataDir: dir, now: now) == .healthy)  // just started
        try Store(root: dir).observe(apps("a"), at: LocalTime(Day(2026, 9, 25), 9))
        #expect(recorderHealth(dataDir: dir, now: now) == .healthy)  // yesterday
        #expect(recorderHealth(dataDir: dir, now: LocalTime(Day(2026, 9, 28), 12)) == .stale(last: LocalTime(Day(2026, 9, 25))))
    }

    @Test func onlyTheTailOfALongLogIsRead() throws {
        let old = String(repeating: "2026-01-01T00:00:00 unchanged\n", count: 5000)
        try Data(old.utf8).write(to: dir.appending(path: "capture.log"))
        try log("2026-09-26T11:30:00 saved")
        #expect(CaptureLog.last(in: dir)?.time == LocalTime(Day(2026, 9, 26), 11, 30))
    }
}
