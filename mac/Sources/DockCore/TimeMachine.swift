import Foundation

/// One Time Machine backup: when it was taken and the folder that holds its volumes.
public struct Backup: Hashable, Sendable {
    public let when: LocalTime
    public let root: URL

    public init(when: LocalTime, root: URL) {
        self.when = when
        self.root = root
    }
}

/// "2026-01-10-093015.backup" → 2026-01-10 09:30:15
public func backupTime(_ name: String) -> LocalTime? {
    let chars = Array(name)
    guard chars.count >= 17, chars[4] == "-", chars[7] == "-", chars[10] == "-",
          let day = Day(iso: String(chars[0..<10])),
          let hh = Int(String(chars[11..<13])), let mm = Int(String(chars[13..<15])),
          let ss = Int(String(chars[15..<17])),
          chars[11..<17].allSatisfy(\.isASCII) && chars[11..<17].allSatisfy(\.isNumber),
          hh < 24, mm < 60, ss < 60 else { return nil }
    return LocalTime(day, hh, mm, ss)
}

/// Dated backups among `paths`, oldest first (one per timestamp).
public func backups(from paths: [URL]) -> [Backup] {
    var found: [LocalTime: Backup] = [:]
    for p in paths {
        if let when = backupTime(p.lastPathComponent) { found[when] = Backup(when: when, root: p) }
    }
    return found.keys.sorted().map { found[$0]! }
}

/// Backups in a folder: a machine folder of a backup disk, or a single backup.
public func backups(in folder: URL) throws -> [Backup] {
    if backupTime(folder.lastPathComponent) != nil { return backups(from: [folder]) }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
        throw DockError.backupsFolderMissing(folder.path)
    }
    let children: [URL]
    do {
        children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    } catch {
        throw DockError.fullDiskAccessNeeded(path: folder.path)
    }
    let found = backups(from: children)
    if found.isEmpty { throw DockError.noBackupsInFolder(folder.path) }
    return found
}

/// The Dock prefs inside a backup. Volumes sit one or two levels down depending on the backup format.
public func findDockPlist(_ backup: Backup, home: URL) -> URL? {
    let rel = String(home.path.drop { $0 == "/" }) + "/Library/Preferences/com.apple.dock.plist"
    let fm = FileManager.default
    func children(_ url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    var levels = [[backup.root]]
    levels.append(levels[0].flatMap(children))
    levels.append(levels[1].flatMap(children))
    for level in levels {
        if let hit = level.map({ $0.appending(path: rel) }).first(where: { fm.fileExists(atPath: $0.path) }) {
            return hit
        }
    }
    return nil
}

public struct ImportResult: Equatable, Sendable {
    public let backups: Int
    public let read: Int
    public let added: Int
    public let first: String?
    public let last: String?
}

/// Read the Dock from each backup and fold one snapshot per day of change into the store.
/// Apps deleted since get their icon from their copy inside the backup; today's wallpaper stands in for
/// past ones (they can't be recovered).
public func importBackups(_ backups: [Backup], into store: Store, mac: MacSystem,
                          home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> ImportResult {
    var states: [(when: LocalTime, apps: [DockApp], volume: URL)] = []
    let homeDepth = home.pathComponents.count  // ["/", "Users", "me"]
    for (k, b) in backups.enumerated() {
        progress?(k, backups.count)
        guard let plist = findDockPlist(b, home: home) else { continue }
        guard let data = FileManager.default.contents(atPath: plist.path) else {
            throw DockError.fullDiskAccessNeeded(path: plist.path)
        }
        guard let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { continue }
        let apps = parseDockPrefs(prefs)
        if apps.isEmpty { continue }
        // <volume>/Users/<me>/Library/Preferences/com.apple.dock.plist → <volume>
        var volume = plist
        for _ in 0..<(homeDepth + 2) { volume.deleteLastPathComponent() }
        states.append((b.when, apps, volume))
    }
    progress?(backups.count, backups.count)
    if !backups.isEmpty && states.isEmpty { throw DockError.noReadableDockInBackups(count: backups.count) }

    // One state per day (the last backup of the day wins), and only the days where it changed.
    var byDay: [Day: (when: LocalTime, apps: [DockApp], volume: URL)] = [:]
    for s in states.sorted(by: { $0.when < $1.when }) { byDay[s.when.day] = s }
    var kept: [(when: LocalTime, apps: [DockApp], volume: URL)] = []
    for day in byDay.keys.sorted() {
        let s = byDay[day]!
        if kept.last?.apps != s.apps { kept.append(s) }
    }

    var icons: [String: String] = [:]
    for s in kept.reversed() {  // newest first: the most recent icon of an app wins
        for app in s.apps where icons[app.key] == nil {
            var png = mac.iconPNG(for: app)
            if png == nil && !app.path.isEmpty {
                var inBackup = app
                inBackup.path = s.volume.appending(path: String(app.path.drop { $0 == "/" })).path
                png = mac.iconPNG(for: inBackup)
            }
            if let png {
                icons[app.key] = try store.contentAddressed(folder: "icons", stem: app.key, suffix: ".png", data: png)
            }
        }
    }
    let wallpaper = kept.isEmpty ? nil : try saveWallpaper(store: store, mac: mac)
    let snaps = kept.map { s in
        Snapshot(date: s.when.day.iso, capturedAt: s.when.iso, apps: s.apps,
                 icons: icons.filter { key, _ in s.apps.contains { $0.key == key } },
                 wallpaper: wallpaper, source: Snapshot.timeMachine)
    }
    let added = snaps.isEmpty ? 0 : try store.merge(snaps)
    return ImportResult(backups: backups.count, read: states.count, added: added,
                        first: snaps.first?.date, last: snaps.last?.date)
}
