import Foundation

// MARK: easing

@inline(__always) public func clamp01(_ x: Double) -> Double { x < 0 ? 0 : x > 1 ? 1 : x }

public func easeInOut(_ x: Double) -> Double {
    let x = clamp01(x)
    return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}

public func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }

/// Underdamped spring: overshoots a little, settles at exactly 1.
public func spring(_ x: Double) -> Double {
    let x = clamp01(x)
    if x >= 1 { return 1 }
    return 1 - exp(-6.5 * x) * cos(10.5 * x)
}

/// (slot, scale) of an appearing icon: room opens first, the icon springs in without overlapping.
func grow(_ x: Double) -> (Double, Double) {
    let slot = easeOut(x)
    return (slot, min(spring(x), slot * 1.1))
}

/// Python's `round()`: half to even.
@inline(__always) func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

// MARK: model

public struct Scene: Sendable {
    public let date: Day
    public let day: Int
    public let apps: [DockApp]
    public let changes: [Change]
    public let icons: [String: String]
    public let wallpaper: String?
}

public struct Tile: Sendable {
    public let app: DockApp
    public var pos: Double  // leading edge, in icon slots from the start of the dock
    public let slot: Double  // 0..1 how much room it takes
    public let scale: Double  // icon drawing scale (can overshoot)
    public let alpha: Double
    public let icon: String?
    public var highlight: Double = 0  // 0..1, app involved in the current scene's changes

    public var center: Double { pos + slot / 2 }
}

public struct Label: Sendable {
    public let change: Change
    public let alpha: Double
    public let anchor: Double  // center position (slots) of the tile it refers to
    public let icon: String?
    public let oldIcon: String?
}

public enum Phase: String, Sendable { case intro, hold, transition, outro }

public struct FrameState: Sendable {
    public let t: Double
    public let sceneIndex: Int
    public let phase: Phase
    public let p: Double
    public let tiles: [Tile]
    public let length: Double
    public let day: Double
    public let date: Day
    public let labels: [Label]
    public let progress: Double
    public let outro: Double
    public let title: Double
    public let wallpaper: String?
    public let wallpaperFrom: String?
    public let wallpaperMix: Double
}

public struct Timing: Sendable {
    public var intro = 1.6
    public var transition = 0.9
    public var holdBase = 1.4
    public var holdPerChange = 0.35
    public var outro = 3.0
    public init() {}
}

public func buildScenes(_ snapshots: [Snapshot]) -> [Scene] {
    guard let first = snapshots.first?.day else { return [] }
    return snapshots.map {
        Scene(date: $0.day, day: $0.day.days(since: first) + 1, apps: $0.apps, changes: $0.changes,
              icons: $0.icons, wallpaper: $0.wallpaper)
    }
}

public struct Timeline: Sendable {
    public let scenes: [Scene]
    public let timing: Timing
    public let sceneStarts: [Double]
    public let outroStart: Double
    public let duration: Double
    public let spanDays: Int
    private let fallbackIcons: [String: String]

    public init(_ scenes: [Scene], timing: Timing = Timing()) throws {
        guard !scenes.isEmpty else { throw DockError.noHistory }
        self.scenes = scenes
        self.timing = timing
        var starts: [Double] = []
        var t = 0.0
        for i in scenes.indices {
            starts.append(t)
            t += i == 0 ? timing.intro : timing.transition
            t += Timeline.hold(i, scenes, timing)
        }
        sceneStarts = starts
        outroStart = t
        duration = t + timing.outro
        spanDays = max(1, scenes.last!.day - scenes.first!.day)
        var icons: [String: String] = [:]
        for sc in scenes { icons.merge(sc.icons) { first, _ in first } }
        fallbackIcons = icons
    }

    static func hold(_ i: Int, _ scenes: [Scene], _ timing: Timing) -> Double {
        let n = i == 0 ? 0 : scenes[i].changes.count
        return timing.holdBase + timing.holdPerChange * Double(n)
    }

    public func hold(_ i: Int) -> Double { Timeline.hold(i, scenes, timing) }

    func icon(_ scene: Scene, _ app: DockApp) -> String? {
        scene.icons[app.key] ?? fallbackIcons[app.key]
    }

    func locate(_ t: Double) -> (Int, Phase, Double) {
        let t = min(max(t, 0), duration)
        if t >= outroStart { return (scenes.count - 1, .outro, clamp01((t - outroStart) / timing.outro)) }
        let i = sceneStarts.indices.last { sceneStarts[$0] <= t }!
        let local = t - sceneStarts[i]
        let lead = i == 0 ? timing.intro : timing.transition
        if local < lead { return (i, i == 0 ? .intro : .transition, local / lead) }
        return (i, .hold, clamp01((local - lead) / hold(i)))
    }

    func tiles(_ i: Int, _ phase: Phase, _ p: Double) -> [Tile] {
        let new = scenes[i]
        let changed: Set<String> = i > 0 ? Set(new.changes.map(\.app.key)) : []
        var hl = 0.0
        if i > 0 && (phase == .transition || phase == .hold) {
            hl = phase == .transition ? easeOut((p - 0.4) / 0.6) : 1 - easeInOut((p - 0.6) / 0.4)
        }

        if phase == .intro {  // dock builds up icon by icon
            let n = new.apps.count
            let tiles = new.apps.enumerated().map { k, app -> Tile in
                let start = 0.1 + 0.55 * (Double(k) / Double(max(1, n - 1)))
                let x = (p - start) / 0.35
                let (slot, scale) = grow(x)
                return Tile(app: app, pos: 0, slot: slot, scale: scale, alpha: clamp01(x * 2), icon: icon(new, app))
            }
            return layout(tiles)
        }

        if phase != .transition {
            return layout(new.apps.map {
                Tile(app: $0, pos: 0, slot: 1, scale: 1, alpha: 1, icon: icon(new, $0),
                     highlight: changed.contains($0.key) ? hl : 0)
            })
        }

        let old = scenes[i - 1]
        let outX = p / 0.6, inX = (p - 0.3) / 0.7
        var tiles: [Tile] = []
        let matcher = SequenceMatcher(a: old.apps.map(\.key), b: new.apps.map(\.key))
        for op in matcher.opcodes() {
            if op.tag == .equal {
                tiles += new.apps[op.j1..<op.j2].map {
                    Tile(app: $0, pos: 0, slot: 1, scale: 1, alpha: 1, icon: icon(new, $0),
                         highlight: changed.contains($0.key) ? hl : 0)
                }
                continue
            }
            for a in old.apps[op.i1..<op.i2] {
                let s = 1 - easeInOut(outX)
                tiles.append(Tile(app: a, pos: 0, slot: s, scale: s, alpha: clamp01(s * 1.5), icon: icon(old, a)))
            }
            for a in new.apps[op.j1..<op.j2] {
                let (slot, scale) = grow(inX)
                tiles.append(Tile(app: a, pos: 0, slot: slot, scale: scale, alpha: clamp01(inX * 2),
                                  icon: icon(new, a), highlight: hl))
            }
        }
        return layout(tiles)
    }

    func layout(_ tiles: [Tile]) -> [Tile] {
        var x = 0.0
        return tiles.map { tile in
            var t = tile
            t.pos = x
            x += t.slot
            return t
        }
    }

    func labels(_ i: Int, _ phase: Phase, _ p: Double, _ tiles: [Tile]) -> [Label] {
        if i == 0 && phase != .transition { return [] }
        var labels: [Label] = []

        func anchor(_ change: Change, _ sceneIndex: Int) -> Double {
            // Prefer the live tile of the (new) app; removed apps point to the gap they left.
            var cands = tiles.filter { $0.app.key == change.app.key }
            if change.kind == .removed && cands.isEmpty {
                let old = scenes[sceneIndex - 1].apps
                let newKeys = Set(scenes[sceneIndex].apps.map(\.key))
                guard let k = old.firstIndex(where: { $0.key == change.app.key }) else { return 0 }
                return Double(old[..<k].filter { newKeys.contains($0.key) }.count)
            }
            if change.kind != .removed {
                let live = cands.filter { $0.alpha > 0 || $0.slot > 0 }
                cands = Array((live.isEmpty ? cands : live).suffix(1))
            }
            return cands.first?.center ?? 0
        }

        func add(_ k: Int, _ alpha: Double) {
            guard alpha > 0 else { return }
            let scene = scenes[k]
            for c in scene.changes {
                labels.append(Label(change: c, alpha: alpha, anchor: anchor(c, k), icon: icon(scene, c.app),
                                    oldIcon: c.old.flatMap { icon(scene, $0) }))
            }
        }

        switch phase {
        case .transition:
            if i > 1 { add(i - 1, 1 - easeInOut(p / 0.35)) }
            add(i, easeOut((p - 0.45) / 0.55))
        case .hold:
            add(i, 1)
        case .outro where i > 0:
            add(i, 1 - easeInOut(p / 0.25))
        default:
            break
        }
        return labels
    }

    public func at(_ t: Double) -> FrameState {
        let (i, phase, p) = locate(t)
        let sc = scenes[i]
        let tiles = tiles(i, phase, p)
        let day: Double, wpFrom: String?, mix: Double
        if phase == .transition {
            let prev = scenes[i - 1]
            let e = easeInOut(p)
            day = Double(prev.day) + Double(sc.day - prev.day) * e
            (wpFrom, mix) = (prev.wallpaper, e)
        } else {
            (day, wpFrom, mix) = (Double(sc.day), sc.wallpaper, 1)
        }
        let date = scenes[0].date.adding(days: pyRound(day) - 1)
        var title = 1.0
        if i > 0 || phase == .outro {
            title = (i == 1 && phase == .transition) ? 1 - easeInOut(p / 0.5) : 0
        }
        if scenes.count == 1 && phase == .outro { title = 1 - easeInOut(p / 0.3) }
        let outro = phase == .outro ? easeInOut(p / 0.5) : 0
        return FrameState(
            t: t, sceneIndex: i, phase: phase, p: p, tiles: tiles,
            length: tiles.reduce(0) { $0 + $1.slot },
            day: day, date: date,
            labels: labels(i, phase, p, tiles),
            progress: scenes.count > 1 ? (day - Double(scenes[0].day)) / Double(spanDays) : 1,
            outro: outro, title: title,
            wallpaper: sc.wallpaper, wallpaperFrom: wpFrom, wallpaperMix: mix
        )
    }
}

// MARK: summary

public struct Summary: Sendable {
    public let days: Int
    public let changeCount: Int
    public let arrived: [DockApp]  // in the final dock, not in the first one
    public let left: [DockApp]  // in the first dock, gone at the end
    public let stayed: [DockApp]  // there from day one to the end
    public let finalCount: Int

    public var headline: String {
        if changeCount == 0 { return "Day \(days).  Your Dock today." }
        return "\(days) day\(days == 1 ? "" : "s").  \(changeCount) change\(changeCount == 1 ? "" : "s")."
    }

    public func lines(wrap: Bool = false) -> [String] {
        func names(_ apps: [DockApp], _ n: Int = 4) -> String {
            let ns = apps.map(\.label)
            return ns.prefix(n).joined(separator: ", ") + (ns.count > n ? " +\(ns.count - n)" : "")
        }
        var lines: [String] = []
        if !arrived.isEmpty { lines += wrap ? ["Arrived:", names(arrived, 3)] : ["Arrived  \(names(arrived))"] }
        if !left.isEmpty { lines += wrap ? ["Moved on from:", names(left, 3)] : ["Moved on from  \(names(left))"] }
        if changeCount > 0 {
            lines.append("\(stayed.count) app\(stayed.count == 1 ? "" : "s") there since day one")
        } else {
            lines.append("\(finalCount) apps, recorded from here on")
        }
        return lines
    }
}

public func summarize(_ scenes: [Scene]) -> Summary {
    let first = scenes.first!.apps, last = scenes.last!.apps
    let fk = Set(first.map(\.key)), lk = Set(last.map(\.key))
    return Summary(
        days: scenes.last!.day,
        changeCount: scenes.dropFirst().reduce(0) { $0 + $1.changes.count },
        arrived: last.filter { !fk.contains($0.key) },
        left: first.filter { !lk.contains($0.key) },
        stayed: last.filter { fk.contains($0.key) },
        finalCount: last.count
    )
}
