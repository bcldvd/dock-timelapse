import Foundation

/// The Dock on one day it changed. Same JSON shape as the Python engine's `snapshots.json`.
public struct Snapshot: Equatable, Sendable, Codable {
    public var date: String
    public var capturedAt: String
    public var apps: [DockApp]
    public var changes: [Change]
    public var screenshot: String?
    public var icons: [String: String]
    public var wallpaper: String?
    /// nil = recorded live; "time-machine" = imported from a backup.
    public var source: String?

    public init(date: String, capturedAt: String, apps: [DockApp], changes: [Change] = [],
                screenshot: String? = nil, icons: [String: String] = [:], wallpaper: String? = nil,
                source: String? = nil) {
        self.date = date
        self.capturedAt = capturedAt
        self.apps = apps
        self.changes = changes
        self.screenshot = screenshot
        self.icons = icons
        self.wallpaper = wallpaper
        self.source = source
    }

    public var day: Day { Day(iso: date) ?? Day(1970, 1, 1) }
    public var isImported: Bool { source == Snapshot.timeMachine }
    public static let timeMachine = "time-machine"

    enum CodingKeys: String, CodingKey {
        case date, capturedAt = "captured_at", apps, changes, screenshot, icons, wallpaper, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        guard Day(iso: date) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .date, in: c, debugDescription: "invalid date \(date)")
        }
        capturedAt = try c.decodeIfPresent(String.self, forKey: .capturedAt) ?? date
        apps = try c.decode([DockApp].self, forKey: .apps)
        changes = try c.decodeIfPresent([Change].self, forKey: .changes) ?? []
        screenshot = try c.decodeIfPresent(String.self, forKey: .screenshot)
        icons = try c.decodeIfPresent([String: String].self, forKey: .icons) ?? [:]
        wallpaper = try c.decodeIfPresent(String.self, forKey: .wallpaper)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(apps, forKey: .apps)
        try c.encode(changes, forKey: .changes)
        try c.encode(screenshot, forKey: .screenshot)
        try c.encode(icons, forKey: .icons)
        try c.encode(wallpaper, forKey: .wallpaper)
        try c.encodeIfPresent(source, forKey: .source)
    }
}

/// On-disk history: one snapshot per day on which the Dock changed.
///
///     snapshots.json   ordered snapshots (the source of truth for rendering)
///     checks.json      every day the Dock was inspected
///     icons/           app icons as PNG, content-addressed so icon redesigns are kept
///     wallpapers/      desktop wallpapers seen over time
///     .lock            flock'd around every read-modify-write, shared with the Python engine
public final class Store: Sendable {
    public let root: URL
    private let snapFile: URL
    private let checksFile: URL
    private let lockFile: URL

    public init(root: URL) throws {
        self.root = root
        snapFile = root.appending(path: "snapshots.json")
        checksFile = root.appending(path: "checks.json")
        lockFile = root.appending(path: ".lock")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw DockError.storageUnavailable(root.path)
        }
    }

    // MARK: persistence

    public func snapshots() throws -> [Snapshot] {
        try loadSnapshots()
    }

    /// Run `body` holding an exclusive lock on the data dir, across threads and processes alike.
    private func exclusively<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw DockError.storageUnavailable(root.path) }
        defer { close(fd) }  // releases the lock
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw DockError.storageUnavailable(root.path) }
        }
        return try body()
    }

    private func loadSnapshots() throws -> [Snapshot] {
        guard let data = try? Data(contentsOf: snapFile) else { return [] }
        do {
            return try JSONDecoder().decode([Snapshot].self, from: data)
        } catch {
            throw DockError.corruptHistory(snapFile.path)
        }
    }

    private func save(_ snaps: [Snapshot]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(snaps)
        do {
            try data.write(to: snapFile, options: .atomic)
        } catch {
            throw DockError.storageUnavailable(root.path)
        }
    }

    private func checks() -> [String] {
        guard let data = try? Data(contentsOf: checksFile),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
    }

    public func checkedOn(_ day: Day) -> Bool {
        checks().contains(day.iso)
    }

    private func markChecked(_ day: Day) {
        var list = checks()
        guard !list.contains(day.iso) else { return }
        list.append(day.iso)
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) {
            try? data.write(to: checksFile, options: .atomic)
        }
    }

    // MARK: behaviour

    /// Record what the Dock shows now. Returns the new/updated snapshot, or nil if unchanged.
    @discardableResult
    public func observe(_ apps: [DockApp], at now: LocalTime, icons: [String: String] = [:],
                        wallpaper: String? = nil) throws -> Snapshot? {
        try exclusively { try observeLocked(apps, at: now, icons: icons, wallpaper: wallpaper) }
    }

    private func observeLocked(_ apps: [DockApp], at now: LocalTime, icons: [String: String],
                               wallpaper: String?) throws -> Snapshot? {
        let today = now.day.iso
        var snaps = try loadSnapshots()
        markChecked(now.day)
        if let last = snaps.last, last.apps == apps { return nil }
        // A same-day change folds into today's snapshot (diffed against the previous day).
        if let last = snaps.last, last.date == today {
            snaps.removeLast()
            if let prev = snaps.last, prev.apps == apps {  // reverted to yesterday's state
                try save(snaps)
                return nil
            }
        }
        let snap = Snapshot(date: today, capturedAt: now.iso, apps: apps,
                            changes: diffDocks(snaps.last?.apps ?? [], apps), icons: icons, wallpaper: wallpaper)
        snaps.append(snap)
        try save(snaps)
        return snap
    }

    /// Fold snapshots from elsewhere (e.g. backups) into the history. Returns how many were added.
    ///
    /// A live recording wins over an import on the same day. When two consecutive snapshots show the same
    /// Dock, the earlier one is kept (that is when the state began) and inherits the later one's extras.
    /// Changes are recomputed across the whole history.
    @discardableResult
    public func merge(_ incoming: [Snapshot]) throws -> Int {
        try exclusively { try mergeLocked(incoming) }
    }

    private func mergeLocked(_ incoming: [Snapshot]) throws -> Int {
        let existing = try loadSnapshots()
        var byDay: [String: Snapshot] = [:]
        for s in existing { byDay[s.date] = s }
        for s in incoming {
            if let current = byDay[s.date], current.source != s.source { continue }
            byDay[s.date] = s
        }
        var merged: [Snapshot] = []
        for var s in byDay.values.sorted(by: { $0.date < $1.date }) {
            if var keep = merged.last, keep.apps == s.apps {
                keep.screenshot = keep.screenshot ?? s.screenshot
                keep.icons = s.icons.merging(keep.icons) { _, kept in kept }
                merged[merged.count - 1] = keep
                continue
            }
            s.changes = diffDocks(merged.last?.apps ?? [], s.apps)
            merged.append(s)
        }
        try save(merged)
        struct Key: Hashable { let date: String; let source: String? }
        let old = Set(existing.map { Key(date: $0.date, source: $0.source) })
        return merged.filter { !old.contains(Key(date: $0.date, source: $0.source)) }.count
    }

    /// Write `data` under `folder/` named after `stem` plus a content hash; identical content is stored once.
    public func contentAddressed(folder: String, stem: String, suffix: String, data: Data) throws -> String {
        let rel = "\(folder)/\(safeName(stem))-\(sha256Hex(data).prefix(10))\(suffix)"
        let url = root.appending(path: rel)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return rel
    }
}

func safeName(_ stem: String) -> String {
    var out = ""
    var inRun = false
    for scalar in stem.unicodeScalars {
        let ok = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        if ok {
            out.unicodeScalars.append(scalar)
            inRun = false
        } else if !inRun {
            out += "_"
            inRun = true
        }
    }
    return out
}
