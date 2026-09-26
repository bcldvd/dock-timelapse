import Foundation
import Testing
@testable import DockCore

let D1 = LocalTime(Day(2026, 1, 10), 9)
let D2 = LocalTime(Day(2026, 1, 11), 9)

func imported(_ day: String, _ ids: String...) -> Snapshot {
    Snapshot(date: day, capturedAt: "\(day)T12:00:00", apps: apps(ids), source: Snapshot.timeMachine)
}

@Suite struct StoreTests {
    let dir = tempDir()
    var store: Store { try! Store(root: dir) }

    @Test func firstObservationCreatesSnapshot() throws {
        let snap = try store.observe(apps("a", "b"), at: D1)
        #expect(snap?.date == "2026-01-10")
        #expect(snap?.changes.map(\.kind) == [.added, .added])
        #expect(try store.snapshots()[0].apps == apps("a", "b"))
    }

    @Test func unchangedDockMarksDayCheckedWithoutSnapshot() throws {
        try store.observe(apps("a"), at: D1)
        #expect(try store.observe(apps("a"), at: D2) == nil)
        #expect(try store.snapshots().count == 1)
        #expect(store.checkedOn(D2.day))
    }

    @Test func changeCreatesSnapshotWithDiff() throws {
        try store.observe(apps("a", "vscode"), at: D1)
        let snap = try store.observe(apps("a", "cursor"), at: D2)
        #expect(snap?.changes.map(\.describe) == ["VSCODE → CURSOR"])
    }

    @Test func sameDayChangeFoldsIntoToday() throws {
        try store.observe(apps("a"), at: D1)
        try store.observe(apps("a", "b"), at: D2)
        try store.observe(apps("a", "b", "c"), at: LocalTime(D2.day, 15))
        let snaps = try store.snapshots()
        #expect(snaps.count == 2)
        #expect(snaps.last!.changes.map(\.describe) == ["+ B", "+ C"])
    }

    @Test func sameDayRevertDropsToday() throws {
        try store.observe(apps("a"), at: D1)
        try store.observe(apps("a", "b"), at: D2)
        try store.observe(apps("a"), at: LocalTime(D2.day, 15))
        #expect(try store.snapshots().count == 1)
    }

    @Test func iconsAndWallpaperAreRecorded() throws {
        try store.observe(apps("a"), at: D1, icons: ["a": "icons/a-123.png"], wallpaper: "wallpapers/w.jpg")
        let s = try store.snapshots()[0]
        #expect(s.icons == ["a": "icons/a-123.png"] && s.wallpaper == "wallpapers/w.jpg")
    }

    @Test func mergePrependsImportedHistoryAndRecomputesChanges() throws {
        try store.observe(apps("a", "cursor"), at: D1)
        let added = try store.merge([imported("2025-06-01", "a", "xcode"), imported("2025-09-01", "a", "vscode")])
        let snaps = try store.snapshots()
        #expect(added == 2)
        #expect(snaps.map(\.date) == ["2025-06-01", "2025-09-01", "2026-01-10"])
        #expect(snaps.last!.changes.map(\.describe) == ["VSCODE → CURSOR"])
        #expect(snaps[0].isImported && snaps.last!.source == nil)
    }

    @Test func mergeDropsConsecutiveDuplicatesKeepingEarliest() throws {
        try store.observe(apps("a", "b"), at: D1, icons: ["a": "icons/a.png"])
        try store.merge([imported("2025-12-01", "a", "b")])
        let snaps = try store.snapshots()
        #expect(snaps.map(\.date) == ["2025-12-01"])
        #expect(snaps[0].icons == ["a": "icons/a.png"])  // inherits the later snapshot's extras
    }

    @Test func mergeLiveRecordingWinsOnSameDay() throws {
        try store.observe(apps("a", "b"), at: D1)
        #expect(try store.merge([imported("2026-01-10", "a")]) == 0)
        #expect(try store.snapshots()[0].source == nil)
    }

    @Test func mergeIsIdempotent() throws {
        try store.observe(apps("a", "b"), at: D1)
        #expect(try store.merge([imported("2025-06-01", "a"), imported("2025-09-01", "b")]) == 2)
        #expect(try store.merge([imported("2025-06-01", "a"), imported("2025-09-01", "b")]) == 0)
        #expect(try store.snapshots().count == 3)
    }

    @Test func contentAddressedStoresIdenticalDataOnce() throws {
        let a = try store.contentAddressed(folder: "icons", stem: "com.x/y z", suffix: ".png", data: Data([1, 2]))
        let b = try store.contentAddressed(folder: "icons", stem: "com.x/y z", suffix: ".png", data: Data([1, 2]))
        #expect(a == b && a.hasPrefix("icons/com.x_y_z-") && a.hasSuffix(".png"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "icons").path).count == 1)
    }

    @Test func damagedHistoryIsReportedNotOverwritten() throws {
        try Data("{not json".utf8).write(to: dir.appending(path: "snapshots.json"))
        #expect(throws: DockError.corruptHistory(dir.appending(path: "snapshots.json").path)) {
            try store.observe(apps("a"), at: D1)
        }
        #expect(try String(contentsOf: dir.appending(path: "snapshots.json"), encoding: .utf8) == "{not json")
    }

    /// A data dir written by the Python engine loads, and a Swift write keeps every field Python reads.
    @Test func readsAndRoundTripsPythonData() throws {
        let f = try fixture("store") as! [String: String]
        try Data(f["snapshots_json"]!.utf8).write(to: dir.appending(path: "snapshots.json"))
        try Data(f["checks_json"]!.utf8).write(to: dir.appending(path: "checks.json"))
        let snaps = try store.snapshots()
        #expect(snaps.map(\.date) == ["2025-06-01", "2026-01-10", "2026-01-11"])
        #expect(snaps[0].isImported)
        #expect(snaps[2].changes.map(\.describe) == ["VSCODE → CURSOR", "+ LINEAR"])
        #expect(store.checkedOn(Day(2026, 1, 11)))
        // Force a rewrite, then compare with Python's JSON semantically.
        try store.merge([])
        let python = try JSONSerialization.jsonObject(with: Data(f["snapshots_json"]!.utf8)) as! NSArray
        let swift = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "snapshots.json"))) as! NSArray
        #expect(python == swift)
    }
}
