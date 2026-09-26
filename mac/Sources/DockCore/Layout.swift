/// Screen geometry for the two video formats (pure, no drawing).
public struct VideoFormat: Hashable, Sendable {
    public let name: String
    public let width: Int
    public let height: Int
    public let margin: Int

    public static let landscape = VideoFormat(name: "landscape", width: 1920, height: 1080, margin: 120)
    public static let portrait = VideoFormat(name: "portrait", width: 1080, height: 1920, margin: 90)
    public static let all = [landscape, portrait]

    public static func named(_ name: String) -> VideoFormat? { all.first { $0.name == name } }
    public var isLandscape: Bool { width >= height }
}

public let slotPerIcon = 1.22
public let padSlots = 0.35  // dock padding at each end, in slots

public struct DockGeometry: Sendable {
    public let format: VideoFormat
    public let horizontal: Bool
    public let slot: Double
    public let icon: Int
    public let pad: Double
    /// Dock center on the axis perpendicular to the dock.
    public let cross: Double
    /// Extent along the dock axis the dock is centered in.
    public let region: (Double, Double)

    public var thickness: Double { Double(icon) + 2 * pad * 0.9 }

    public func extent(_ length: Double) -> (Double, Double) {
        let mid = (region.0 + region.1) / 2
        let span = length * slot + 2 * pad
        return (mid - span / 2, mid + span / 2)
    }

    public func along(_ pos: Double, _ length: Double) -> Double { extent(length).0 + pad + pos * slot }

    public func iconCenter(_ pos: Double, _ length: Double) -> (x: Double, y: Double) {
        let a = along(pos, length)
        return horizontal ? (a, cross) : (cross, a)
    }
}

public func dockGeometry(_ fmt: VideoFormat, maxApps: Int) -> DockGeometry {
    let n = Double(max(1, maxApps)) + 2 * padSlots
    let w = Double(fmt.width), h = Double(fmt.height), m = Double(fmt.margin)
    if fmt.width >= fmt.height {
        let region = (m, w - m)
        let slot = min(134.0, (region.1 - region.0) / n)
        let icon = Int(slot / slotPerIcon)
        return DockGeometry(format: fmt, horizontal: true, slot: slot, icon: icon, pad: padSlots * slot,
                            cross: h * 0.64, region: region)
    }
    let region = (h * 0.215, h * 0.905)
    let slot = min(120.0, (region.1 - region.0) / n)
    let icon = Int(slot / slotPerIcon)
    let pad = padSlots * slot
    return DockGeometry(format: fmt, horizontal: false, slot: slot, icon: icon, pad: pad,
                        cross: m + (Double(icon) + 2 * pad * 0.9) / 2, region: region)
}

public struct Placement: Equatable, Sendable {
    public let start: Double
    public let row: Int
}

/// Greedy 1-D packing: each label as close to its anchor as possible, extra rows on collision.
/// `items` are (center, width).
public func placeLabels(_ items: [(Double, Double)], gap: Double) -> [Placement] {
    let order = items.indices.sorted { (items[$0].0, $0) < (items[$1].0, $1) }
    var rowEnds: [Double] = []
    var out: [Int: Placement] = [:]
    for k in order {
        let (center, width) = items[k]
        let start = center - width / 2
        if let r = rowEnds.firstIndex(where: { $0 + gap <= start }) {
            rowEnds[r] = start + width
            out[k] = Placement(start: start, row: r)
        } else {
            rowEnds.append(start + width)
            out[k] = Placement(start: start, row: rowEnds.count - 1)
        }
    }
    return items.indices.map { out[$0]! }
}
