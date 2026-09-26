import Testing
@testable import DockCore

func snaps(_ states: (String, String)...) -> [Snapshot] {
    var out: [Snapshot] = [], prev: [DockApp] = []
    for (date, ids) in states {
        let a = chars(ids)
        out.append(Snapshot(date: date, capturedAt: date + "T10:00:00", apps: a, changes: diffDocks(prev, a)))
        prev = a
    }
    return out
}

var T: Timing {
    var t = Timing()
    (t.intro, t.transition, t.holdBase, t.holdPerChange, t.outro) = (1, 1, 1, 0.5, 2)
    return t
}
let HISTORY = snaps(("2026-01-01", "abc"), ("2026-01-11", "abxc"), ("2026-02-10", "axc"))
func tl() -> Timeline { try! Timeline(buildScenes(HISTORY), timing: T) }

func pos(_ s: FrameState) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: s.tiles.filter { $0.slot > 0 }.map { ($0.app.bundleID!, ($0.pos * 1000).rounded() / 1000) })
}

@Test func scenesHaveDayNumbers() { #expect(buildScenes(HISTORY).map(\.day) == [1, 11, 41]) }

@Test func duration() { #expect(approx(tl().duration, 1 + 1 + 2.5 + 2.5 + 2)) }

@Test func emptyHistoryThrowsNoHistory() {
    #expect(throws: DockError.noHistory) { try Timeline([]) }
}

@Test func afterIntroFirstDockIsBuilt() {
    let s = tl().at(1.5)
    #expect(pos(s) == ["a": 0, "b": 1, "c": 2])
    #expect(approx(s.length, 3) && s.sceneIndex == 0)
}

@Test func midTransitionAddedAppOpensAGap() {
    let t = tl()
    let s = t.at(t.sceneStarts[1] + 0.6)
    let x = s.tiles.first { $0.app.bundleID == "x" }!
    #expect(0 < x.slot && x.slot < 1 && 3 < s.length && s.length < 4)
}

@Test func afterTransitionPositionsMatchNewDock() {
    let t = tl()
    #expect(pos(t.at(t.sceneStarts[1] + 1.2)) == ["a": 0, "b": 1, "x": 2, "c": 3])
    #expect(pos(t.at(t.duration - 0.01)) == ["a": 0, "x": 1, "c": 2])
}

@Test func dayCounterCountsUpDuringTransition() {
    let t = tl()
    #expect(approx(t.at(1.5).day, 1))
    let mid = t.at(t.sceneStarts[1] + 0.5).day
    #expect(1 < mid && mid < 11)
    #expect(approx(t.at(t.sceneStarts[1] + 1.1).day, 11))
}

@Test func labelsShowDuringTheirSceneOnly() {
    let t = tl()
    #expect(t.at(t.sceneStarts[1] + 1.5).labels.map { "\($0.change.describe) \($0.alpha)" } == ["+ X 1.0"])
    #expect(t.at(t.sceneStarts[2] + 1.5).labels.filter { $0.alpha > 0.99 }.map(\.change.describe) == ["− B"])
    #expect(t.at(1.5).labels.isEmpty)
}

@Test func progressFollowsCalendar() {
    let t = tl()
    #expect(approx(t.at(1.5).progress, 0))
    #expect(approx(t.at(t.sceneStarts[1] + 1.1).progress, 10.0 / 40))
    #expect(approx(t.at(t.duration).progress, 1))
    #expect(t.at(t.duration - 2.5).outro == 0 && approx(t.at(t.duration).outro, 1))
}

@Test func movedAppShrinksAndGrows() throws {
    let t = try Timeline(buildScenes(snaps(("2026-01-01", "abc"), ("2026-01-02", "bca"))), timing: T)
    #expect(t.at(t.sceneStarts[1] + 0.5).tiles.filter { $0.app.bundleID == "a" }.count == 2)
}

@Test func removedLabelPointsAtTheGap() {
    let t = tl()
    let lab = t.at(t.sceneStarts[2] + 1.5).labels.first { $0.change.kind == .removed }!
    #expect(approx(lab.anchor, 1))
}

@Test func growingTilesNeverExceedTheirSlot() {
    let t = tl()
    for k in 1..<20 {
        for time in [t.sceneStarts[1] + Double(k) * 0.05, Double(k) * 0.05] {
            for tile in t.at(time).tiles where 0 < tile.slot && tile.slot < 0.95 {
                #expect(tile.scale <= tile.slot * 1.1 + 1e-9)
            }
        }
    }
}

@Test func summaryForOutro() {
    let s = summarize(buildScenes(snaps(("2026-01-01", "abc"), ("2026-01-11", "abxc"), ("2026-02-10", "axcy"))))
    #expect(s.days == 41 && s.changeCount == 3 && s.finalCount == 4)
    #expect(s.arrived.map(\.bundleID) == ["x", "y"] && s.left.map(\.bundleID) == ["b"])
    #expect(s.stayed.map(\.bundleID) == ["a", "c"])
}

@Test func singleSnapshotReadsNaturally() throws {
    let one = buildScenes(snaps(("2026-09-25", "abc")))
    let t = try Timeline(one, timing: T)
    #expect(approx(t.at(t.duration).progress, 1))
    #expect(summarize(one).headline == "Day 1.  Your Dock today.")
    #expect(summarize(buildScenes(snaps(("2026-01-01", "ab"), ("2026-01-02", "abc")))).headline == "2 days.  1 change.")
}

/// Every frame state of four histories, computed by the Python engine: the port must match to 1e-9.
@Test(arguments: ["invented", "single", "mixed", "long"])
func matchesPythonOracle(_ name: String) throws {
    let all = try fixture("timeline") as! [String: [String: Any]]
    let f = all[name]!
    let t = try Timeline(buildScenes(try decodeSnapshots(f["snapshots"]!)))
    #expect(approx(t.duration, f["duration"] as! Double))
    #expect(approx(t.outroStart, f["outro_start"] as! Double))
    #expect(t.sceneStarts.count == (f["scene_starts"] as! [Double]).count)
    let frames = f["frames"] as! [[String: Any]]
    #expect(frames.count > 20)
    for e in frames {
        let s = t.at(e["t"] as! Double)
        let where_ = "\(name) t=\(e["t"]!)"
        #expect(s.sceneIndex == e["scene_index"] as! Int, "\(where_)")
        #expect(s.phase.rawValue == e["phase"] as! String, "\(where_)")
        for (a, key) in [(s.p, "p"), (s.length, "length"), (s.day, "day"), (s.progress, "progress"),
                         (s.outro, "outro"), (s.title, "title"), (s.wallpaperMix, "wallpaper_mix")] {
            #expect(approx(a, e[key] as! Double), "\(where_) \(key): \(a) vs \(e[key]!)")
        }
        #expect(s.date.iso == e["date"] as! String, "\(where_)")
        #expect(s.wallpaper == e["wallpaper"] as? String && s.wallpaperFrom == e["wallpaper_from"] as? String, "\(where_)")
        let tiles = e["tiles"] as! [[String: Any]]
        #expect(s.tiles.count == tiles.count, "\(where_)")
        for (tile, x) in zip(s.tiles, tiles) {
            #expect(tile.app.key == x["key"] as! String && tile.icon == x["icon"] as? String, "\(where_)")
            for (a, key) in [(tile.pos, "pos"), (tile.slot, "slot"), (tile.scale, "scale"), (tile.alpha, "alpha"),
                             (tile.highlight, "highlight")] {
                #expect(approx(a, x[key] as! Double), "\(where_) tile \(tile.app.key) \(key)")
            }
        }
        let labels = e["labels"] as! [[String: Any]]
        #expect(s.labels.count == labels.count, "\(where_)")
        for (l, x) in zip(s.labels, labels) {
            #expect(l.change == decodeChange(x["change"] as! [String: Any]), "\(where_)")
            #expect(approx(l.alpha, x["alpha"] as! Double) && approx(l.anchor, x["anchor"] as! Double), "\(where_)")
            #expect(l.icon == x["icon"] as? String && l.oldIcon == x["old_icon"] as? String, "\(where_)")
        }
    }
    let sm = summarize(t.scenes), es = f["summary"] as! [String: Any]
    #expect(sm.days == es["days"] as! Int && sm.changeCount == es["n_changes"] as! Int)
    #expect(sm.arrived.map(\.key) == es["arrived"] as! [String] && sm.left.map(\.key) == es["left"] as! [String])
    #expect(sm.stayed.map(\.key) == es["stayed"] as! [String] && sm.finalCount == es["final_count"] as! Int)
}
