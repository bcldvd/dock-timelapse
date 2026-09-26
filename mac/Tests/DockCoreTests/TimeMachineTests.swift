import Foundation
import Testing
@testable import DockCore

let HOME = URL(fileURLWithPath: "/Users/me")

func tmTile(_ label: String) -> [String: Any] {
    ["tile-type": "file-tile", "tile-data": ["file-label": label, "bundle-identifier": label.lowercased(),
                                             "file-data": ["_CFURLString": "file:///Applications/\(label).app/"]]]
}

/// A backup folder like Time Machine writes: APFS nests `<name>/<name>/<volume>`, HFS doesn't.
@discardableResult
func makeBackup(_ folder: URL, _ name: String, _ labels: [String], volume: String = "Macintosh HD - Data",
                nested: Bool = true) throws -> URL {
    let root = nested ? folder.appending(path: name).appending(path: name) : folder.appending(path: name)
    let prefs = root.appending(path: volume).appending(path: "Users/me/Library/Preferences/com.apple.dock.plist")
    try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["persistent-apps": labels.map(tmTile)], format: .binary,
                                       options: 0).write(to: prefs)
    return folder.appending(path: name)
}

func tmApps(_ labels: String...) -> [DockApp] {
    labels.map { DockApp(label: $0, bundleID: $0.lowercased(), path: "/Applications/\($0).app") }
}

@Suite struct TimeMachineTests {
    let dir = tempDir()
    var tm: URL { dir.appending(path: "tm") }
    var store: Store { try! Store(root: dir.appending(path: "data")) }
    func mac() -> FakeMac {
        FakeMac(tmApps("Arc"), installed: Set(["Arc", "Slack", "Cursor", "Linear"].map { "/Applications/\($0).app" }))
    }

    @Test func parsesTimeMachineNames() {
        #expect(backupTime("2026-01-10-093015.backup") == LocalTime(Day(2026, 1, 10), 9, 30, 15))
        #expect(backupTime("2026-01-10-093015") == LocalTime(Day(2026, 1, 10), 9, 30, 15))
        #expect(backupTime("Latest") == nil)
        #expect(backupTime("2026-13-10-093015") == nil)
    }

    @Test func listsDatedBackupsOldestFirst() throws {
        try makeBackup(tm, "2026-02-01-100000.backup", ["Arc"])
        try makeBackup(tm, "2026-01-01-100000.backup", ["Arc"])
        try FileManager.default.createDirectory(at: tm.appending(path: "Latest"), withIntermediateDirectories: true)
        #expect(try backups(in: tm).map(\.when.day.month) == [1, 2])
    }

    @Test func findsDockPlistInBothLayouts() throws {
        let apfs = try makeBackup(tm, "2026-01-01-100000.backup", ["Arc"])
        let hfs = try makeBackup(tm, "2025-01-01-100000", ["Arc"], volume: "Macintosh HD", nested: false)
        for root in [apfs, hfs] {
            #expect(findDockPlist(Backup(when: .now(), root: root), home: HOME)?.lastPathComponent == "com.apple.dock.plist")
        }
        #expect(findDockPlist(Backup(when: .now(), root: tm.appending(path: "nope")), home: HOME) == nil)
    }

    @Test func keepsOneSnapshotPerDayOfChange() throws {
        try makeBackup(tm, "2025-06-01-090000.backup", ["Arc", "Xcode"])
        try makeBackup(tm, "2025-06-01-180000.backup", ["Arc", "Xcode", "Slack"])  // same day: last wins
        try makeBackup(tm, "2025-07-01-090000.backup", ["Arc", "Xcode", "Slack"])  // unchanged: skipped
        try makeBackup(tm, "2025-08-01-090000.backup", ["Arc", "Cursor", "Slack"])
        let r = try importBackups(try backups(in: tm), into: store, mac: mac(), home: HOME)
        #expect(r == ImportResult(backups: 4, read: 4, added: 2, first: "2025-06-01", last: "2025-08-01"))
        let snaps = try store.snapshots()
        #expect(snaps.map(\.date) == ["2025-06-01", "2025-08-01"])
        #expect(snaps[1].changes.map(\.describe) == ["Xcode → Cursor"])
        #expect(snaps.allSatisfy { $0.isImported && $0.wallpaper != nil })
    }

    @Test func deletedAppGetsItsIconFromTheBackup() throws {
        let root = try makeBackup(tm, "2025-06-01-090000.backup", ["Arc", "Xcode"])
        let app = root.appending(path: root.lastPathComponent).appending(path: "Macintosh HD - Data/Applications/Xcode.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let m = mac()
        try importBackups(try backups(in: tm), into: store, mac: m, home: HOME)
        #expect(m.askedIcons.contains(app.path), "\(m.askedIcons) vs \(app.path)")
        let snap = try store.snapshots()[0]
        #expect(try Data(contentsOf: store.root.appending(path: snap.icons["xcode"]!)) == Data("png-Xcode".utf8))
    }

    @Test func liveRecordingContinuesTheStory() throws {
        try makeBackup(tm, "2025-06-01-090000.backup", ["Arc", "Xcode"])
        try store.observe(tmApps("Arc", "Cursor", "Linear"), at: LocalTime(Day(2026, 1, 1), 9))
        try importBackups(try backups(in: tm), into: store, mac: mac(), home: HOME)
        let snaps = try store.snapshots()
        #expect(snaps.map(\.source) == [Snapshot.timeMachine, nil])
        #expect(snaps[1].changes.map(\.describe) == ["Xcode → Cursor", "+ Linear"])
    }

    @Test func emptyFolderAndMissingFolderExplainThemselves() throws {
        try FileManager.default.createDirectory(at: tm, withIntermediateDirectories: true)
        #expect(throws: DockError.noBackupsInFolder(tm.path)) { try backups(in: tm) }
        #expect(throws: DockError.backupsFolderMissing(dir.appending(path: "nope").path)) {
            try backups(in: dir.appending(path: "nope"))
        }
    }

    @Test func backupsWithoutReadableDockPointToFullDiskAccess() throws {
        try FileManager.default.createDirectory(at: tm.appending(path: "2026-01-01-100000.backup"), withIntermediateDirectories: true)
        let error = #expect(throws: DockError.self) {
            try importBackups(try backups(in: tm), into: store, mac: mac(), home: HOME)
        }
        #expect(error == .noReadableDockInBackups(count: 1))
        #expect(error?.recovery == .openFullDiskAccessSettings)
    }

    @Test func unreadableFolderPointsToFullDiskAccess() throws {
        let locked = dir.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(throws: DockError.fullDiskAccessNeeded(path: locked.path)) { try backups(in: locked) }
    }
}
