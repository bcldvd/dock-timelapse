import Foundation

/// Built-in apps every Mac has: plausible "before" states for an invented past.
public let classicApps = [
    DockApp(label: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app"),
    DockApp(label: "Mail", bundleID: "com.apple.mail", path: "/System/Applications/Mail.app"),
    DockApp(label: "Music", bundleID: "com.apple.Music", path: "/System/Applications/Music.app"),
    DockApp(label: "Photos", bundleID: "com.apple.Photos", path: "/System/Applications/Photos.app"),
    DockApp(label: "Terminal", bundleID: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app"),
    DockApp(label: "Maps", bundleID: "com.apple.Maps", path: "/System/Applications/Maps.app"),
    DockApp(label: "FaceTime", bundleID: "com.apple.FaceTime", path: "/System/Applications/FaceTime.app"),
    DockApp(label: "Contacts", bundleID: "com.apple.AddressBook", path: "/System/Applications/Contacts.app"),
    DockApp(label: "Podcasts", bundleID: "com.apple.podcasts", path: "/System/Applications/Podcasts.app"),
    DockApp(label: "TextEdit", bundleID: "com.apple.TextEdit", path: "/System/Applications/TextEdit.app"),
]

/// A small deterministic generator (SplitMix64), so a seed always invents the same past.
public struct SeededRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Uniform in 0..<n.
    public mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    /// Uniform in a...b.
    public mutating func int(_ a: Int, _ b: Int) -> Int { a + below(b - a + 1) }

    public mutating func weighted<T>(_ options: [T], _ weights: [Double]) -> T {
        var r = unit() * weights.reduce(0, +)
        for (o, w) in zip(options, weights) {
            if r < w { return o }
            r -= w
        }
        return options[options.count - 1]
    }
}

/// Walk backwards from today's Dock, undoing made-up additions, replacements and removals.
/// Returns (days ago, dock) pairs, oldest first; the last one is `current` at day 0.
/// The first and last Dock items (usually the browser and Settings) stay put.
public func inventHistory(_ current: [DockApp], count n: Int = 7, seed: UInt64 = 7,
                          classics: [DockApp] = classicApps) -> [(daysAgo: Int, dock: [DockApp])] {
    var rng = SeededRandom(seed: seed)
    let keys = Set(current.map(\.key))
    var pool = classics.filter { !keys.contains($0.key) }
    var states = [current]
    var dock = current
    enum Op { case remove, replace, insert }
    for _ in 0..<max(0, n - 1) {
        let edits = 1 + (rng.unit() < 0.3 ? 1 : 0)
        for _ in 0..<edits {
            let hasMiddle = dock.count > 2
            var op: Op? = hasMiddle ? rng.weighted([Op.remove, .replace, .insert], [5, 4, 1]) : .insert
            if (op == .replace || op == .insert) && pool.isEmpty { op = hasMiddle ? .remove : nil }
            switch op {
            case .remove? where dock.count > 2:  // forward in time: this app was added
                dock.remove(at: rng.int(1, dock.count - 2))
            case .replace? where dock.count > 2:  // forward: a classic got replaced
                dock[rng.int(1, dock.count - 2)] = pool.remove(at: rng.below(pool.count))
            case .insert?, .replace?, .remove?:  // forward: a classic got removed
                guard !pool.isEmpty else { break }
                let at = min(rng.int(1, max(1, dock.count - 1)), dock.count)
                dock.insert(pool.remove(at: rng.below(pool.count)), at: at)
            case nil:
                break
            }
        }
        if dock == states.last! {
            if !pool.isEmpty { dock.insert(pool.removeLast(), at: min(1, dock.count)) }
            else if dock.count > 2 { dock.remove(at: 1) }
        }
        states.append(dock)
    }
    states.reverse()
    let gaps = (0..<max(0, n - 1)).map { _ in rng.int(28, 64) }
    let days = (0..<max(0, n - 1)).map { gaps[$0...].reduce(0, +) } + [0]
    return Array(zip(days, states)).map { (daysAgo: $0.0, dock: $0.1) }
}

/// Write an invented past ending with today's real Dock into `root`, so anyone can preview on day one.
@discardableResult
public func buildPreview(at root: URL, mac: MacSystem, today: Day = LocalTime.now().day, seed: UInt64 = 7,
                         current: [DockApp]? = nil) throws -> Store {
    let store = try Store(root: root)
    let dock = try current ?? mac.currentDock()
    let wallpaper = try saveWallpaper(store: store, mac: mac)
    var iconCache: [String: String] = [:]
    for (daysAgo, apps) in inventHistory(dock, seed: seed) {
        for app in apps where iconCache[app.key] == nil {
            if let png = mac.iconPNG(for: app) {
                iconCache[app.key] = try store.contentAddressed(folder: "icons", stem: app.key, suffix: ".png", data: png)
            }
        }
        let icons = iconCache.filter { key, _ in apps.contains { $0.key == key } }
        try store.observe(apps, at: LocalTime(today.adding(days: -daysAgo), 10), icons: icons, wallpaper: wallpaper)
    }
    return store
}
