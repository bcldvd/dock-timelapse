import Foundation
import Testing
@testable import DockCore

@Suite struct CaptureTests {
    let dir = tempDir()
    var store: Store { try! Store(root: dir) }
    let now = LocalTime(Day(2026, 3, 1), 10)

    @Test func firstRunSavesSnapshotIconsAndWallpaper() throws {
        #expect(try runCapture(store: store, mac: FakeMac(), now: now) == .saved)
        let snap = try store.snapshots()[0]
        #expect(try Data(contentsOf: dir.appending(path: snap.icons["arc"]!)) == Data("png-ARC".utf8))
        #expect(try Data(contentsOf: dir.appending(path: snap.wallpaper!)) == Data("jpg".utf8))
        #expect(snap.wallpaper!.hasPrefix("wallpapers/Fresh_Grass-"))
    }

    @Test func unchangedRunsAreCheapNoops() throws {
        let mac = FakeMac()
        try runCapture(store: store, mac: mac, now: now)
        mac.askedIcons = []
        #expect(try runCapture(store: store, mac: mac, now: LocalTime(now.day, 11)) == .unchanged)
        #expect(try runCapture(store: store, mac: mac, now: LocalTime(now.day.adding(days: 1), 9)) == .unchanged)
        #expect(mac.askedIcons.isEmpty)
        #expect(try store.snapshots().count == 1)
        #expect(store.checkedOn(now.day.adding(days: 1)))
    }

    @Test func laterSameDayChangeIsCaughtAndFolded() throws {
        let mac = FakeMac()
        try runCapture(store: store, mac: mac, now: now)
        try runCapture(store: store, mac: mac, now: LocalTime(now.day.adding(days: 1), 9))
        mac.dock += apps("linear")
        #expect(try runCapture(store: store, mac: mac, now: LocalTime(now.day.adding(days: 1), 15)) == .saved)
        #expect(try store.snapshots().map(\.date) == ["2026-03-01", "2026-03-02"])
    }

    @Test func identicalIconsAreStoredOnce() throws {
        let mac = FakeMac(apps("arc", "slack"), installed: Set(apps("arc", "slack", "linear").map(\.path)))
        try runCapture(store: store, mac: mac, now: now)
        mac.dock += apps("linear")
        try runCapture(store: store, mac: mac, now: LocalTime(now.day.adding(days: 1), 9))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "icons").path).count == 3)
    }

    @Test func missingIconAndWallpaperStillSaveTheDock() throws {
        let mac = FakeMac(apps("gone"), installed: [])
        mac.wallpaperData = nil
        #expect(try runCapture(store: store, mac: mac, now: now) == .saved)
        let s = try store.snapshots()[0]
        #expect(s.icons.isEmpty && s.wallpaper == nil && s.apps == apps("gone"))
    }

    @Test func unreadableDockSurfacesATypedError() {
        let mac = FakeMac()
        mac.failDock = true
        #expect(throws: DockError.dockUnreadable) { try runCapture(store: store, mac: mac, now: now) }
    }
}
