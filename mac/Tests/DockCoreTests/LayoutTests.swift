import Testing
@testable import DockCore

@Test func iconsFitOnScreenForMaxApps() {
    for fmt in VideoFormat.all {
        let g = dockGeometry(fmt, maxApps: 25)
        #expect(g.slot * 25 + 2 * g.pad <= Double((g.horizontal ? fmt.width : fmt.height) - 2 * fmt.margin))
    }
}

@Test func landscapeIsHorizontalPortraitIsVertical() {
    #expect(dockGeometry(.landscape, maxApps: 18).horizontal)
    #expect(!dockGeometry(.portrait, maxApps: 18).horizontal)
}

@Test func placeLabelsNeverOverlapOnARow() {
    let items: [(Double, Double)] = [(100, 200), (150, 200), (160, 200), (900, 200)]
    let placed = placeLabels(items, gap: 12)
    var rows: [Int: [(Double, Double)]] = [:]
    for (item, p) in zip(items, placed) { rows[p.row, default: []].append((p.start, p.start + item.1)) }
    for spans in rows.values {
        let s = spans.sorted { $0.0 < $1.0 }
        for (a, b) in zip(s, s.dropFirst()) { #expect(a.1 + 12 <= b.0) }
    }
    #expect(placed[3].row == 0)
    #expect(placeLabels([(500, 100)], gap: 10) == [Placement(start: 450, row: 0)])
}

@Test func geometryMatchesPythonOracle() throws {
    let f = try fixture("layout") as! [String: Any]
    for g in f["geometry"] as! [[String: Any]] {
        let geo = dockGeometry(VideoFormat.named(g["format"] as! String)!, maxApps: g["max_apps"] as! Int)
        let region = g["region"] as! [Double], extent = g["extent_7_5"] as! [Double], center = g["center_3_2"] as! [Double]
        #expect(geo.horizontal == g["horizontal"] as! Bool)
        #expect(geo.icon == g["icon"] as! Int)
        for (a, b) in [(geo.slot, g["slot"]), (geo.pad, g["pad"]), (geo.cross, g["cross"]), (geo.thickness, g["thickness"]),
                       (geo.region.0, region[0]), (geo.region.1, region[1]), (geo.extent(7.5).0, extent[0]),
                       (geo.extent(7.5).1, extent[1]), (geo.iconCenter(3.2, 9).x, center[0]),
                       (geo.iconCenter(3.2, 9).y, center[1])] as [(Double, Any?)] {
            #expect(approx(a, b as! Double))
        }
    }
    for c in f["labels"] as! [[String: Any]] {
        let items = (c["items"] as! [[Double]]).map { ($0[0], $0[1]) }
        let expected = (c["placed"] as! [[String: Any]]).map { Placement(start: $0["start"] as! Double, row: $0["row"] as! Int) }
        #expect(placeLabels(items, gap: 16) == expected)
    }
}
