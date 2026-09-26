import CoreGraphics
import DockCore
import Foundation

/// Draws a `FrameState`: an Apple-style re-rendered Dock over the (blurred) real wallpaper.
/// A port of the Python Pillow renderer; geometry and timings come from `DockCore`.
public final class Renderer: @unchecked Sendable {
    public let format: VideoFormat
    public let timeline: Timeline
    let mode: Background
    let theme: Theme
    let geo: DockGeometry
    let assets: Assets
    let type = Typesetter()
    let summary: Summary
    private let first: Day
    private let last: Day

    public init(dataRoot: URL, format: VideoFormat, timeline: Timeline, background: Background = .wallpaper) {
        self.format = format
        self.timeline = timeline
        mode = background
        theme = Theme.of(background)
        geo = dockGeometry(format, maxApps: timeline.scenes.map(\.apps.count).max() ?? 1)
        assets = Assets(root: dataRoot, size: (format.width, format.height), mode: background)
        summary = summarize(timeline.scenes)
        first = timeline.scenes.first!.date
        last = timeline.scenes.last!.date
    }

    var landscape: Bool { format.width > format.height }

    /// A frame as an image (for stills and tests).
    public func image(at t: Double) -> CGImage {
        let ctx = bitmapContext(format.width, format.height)
        draw(timeline.at(t), into: ctx)
        return ctx.makeImage()!
    }

    /// Draw into a context of exactly `format.width × format.height` pixels (bottom-left origin).
    public func draw(_ s: FrameState, into ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let c = Canvas(ctx, width: format.width, height: format.height)
        let (base, frosted) = assets.background(s.wallpaper)
        var from: (CGImage, CGImage)?
        if s.wallpaperFrom != s.wallpaper && s.wallpaperMix < 1 { from = assets.background(s.wallpaperFrom) }
        if let from { c.image(from.0, in: c.bounds) }
        c.image(base, in: c.bounds, alpha: from == nil ? 1 : s.wallpaperMix)
        let frostedLayers: [(CGImage, Double)] = from.map { [($0.1, 1), (frosted, s.wallpaperMix)] } ?? [(frosted, 1)]
        drawDock(c, frostedLayers, s)
        drawLabels(c, frostedLayers, s)
        drawHeader(c, s)
        drawProgress(c, s)
        drawOutro(c, s)
    }

    // MARK: glass

    /// Frosted glass: soft shadow, the blurred wallpaper seen through, a tint, and a hairline ring.
    func glass(_ c: Canvas, _ frosted: [(CGImage, Double)], _ box: CGRect, radius: Double, fill: RGBA, stroke: RGBA,
               shadow: Bool = true) {
        let r = CGRect(x: box.minX.rounded(), y: box.minY.rounded(), width: (box.maxX.rounded() - box.minX.rounded()),
                       height: (box.maxY.rounded() - box.minY.rounded()))
        guard r.width >= 2, r.height >= 2 else { return }
        let path = roundedRect(r, radius: radius)
        if shadow && theme.shadow > 0 {
            let blur = max(6, Double(Int(r.height) / 5))
            if let mask = assets.shadow(width: Int(r.width), height: Int(r.height), radius: radius, blur: blur) {
                // Shadow = black through the blurred mask, offset down by blur/2 (as the Python renderer did).
                let dest = CGRect(x: r.minX - 2 * blur, y: r.minY - 2 * blur + (blur / 2).rounded(.down),
                                  width: r.width + 4 * blur, height: r.height + 4 * blur)
                c.ctx.saveGState()
                c.ctx.translateBy(x: dest.minX, y: dest.maxY)
                c.ctx.scaleBy(x: 1, y: -1)
                c.ctx.clip(to: CGRect(origin: .zero, size: dest.size), mask: mask)
                c.ctx.setFillColor(RGBA(0, 0, 0, theme.shadow).cg)
                c.ctx.fill(CGRect(origin: .zero, size: dest.size))
                c.ctx.restoreGState()
            }
        }
        c.withClip(path) {
            for (img, a) in frosted { c.image(img, in: c.bounds, alpha: a) }
        }
        c.fill(path, fill)
        c.stroke(roundedRect(r.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5), stroke, width: 1)
    }

    // MARK: dock

    func dockBox(_ length: Double) -> CGRect {
        let (a0, a1) = geo.extent(length)
        let t = geo.thickness
        return geo.horizontal ? CGRect(x: a0, y: geo.cross - t / 2, width: a1 - a0, height: t)
                              : CGRect(x: geo.cross - t / 2, y: a0, width: t, height: a1 - a0)
    }

    func drawIcon(_ c: Canvas, _ rel: String?, _ rect: CGRect, alpha: Double = 1, gray: Bool = false) {
        if let img = gray ? assets.grayIcon(rel) : assets.icon(rel) {
            c.image(img, in: rect, alpha: alpha)
        } else {
            c.fill(roundedRect(rect, radius: Double(Int(rect.width * 0.23))), RGBA(120, 124, 134, 255 * alpha))
        }
    }

    func drawDock(_ c: Canvas, _ frosted: [(CGImage, Double)], _ s: FrameState) {
        if s.length > 0.02 {
            glass(c, frosted, dockBox(s.length), radius: Double(Int(geo.thickness * 0.34)), fill: theme.plate,
                  stroke: theme.stroke)
        }
        for tile in s.tiles where tile.alpha > 0.01 && tile.scale > 0.02 {
            let size = Double(max(1, Int(Double(geo.icon) * tile.scale)))
            var (cx, cy) = geo.iconCenter(tile.center, s.length)
            let lift = Double(geo.icon) * 0.16 * tile.highlight
            if geo.horizontal { cy -= lift } else { cx += lift }
            let rect = CGRect(x: (cx - size / 2).rounded(), y: (cy - size / 2).rounded(), width: size, height: size)
            drawIcon(c, tile.icon, rect, alpha: tile.alpha)
            if tile.highlight > 0.02 {
                let dot = geo.horizontal
                    ? CGRect(x: Double(Int(cx - 4)), y: Double(Int(geo.cross + geo.thickness / 2 - 11)), width: 7, height: 7)
                    : CGRect(x: Double(Int(geo.cross - geo.thickness / 2 + 4)), y: Double(Int(cy - 4)), width: 7, height: 7)
                c.fill(CGPath(ellipseIn: dot, transform: nil), theme.fg.alpha(230 * tile.highlight))
            }
        }
    }

    // MARK: labels

    enum Part {
        case badge(String, RGBA)
        case icon(String?, gray: Bool)
        case text(String, RGBA, Int)
    }

    func parts(_ l: ChangeLabel) -> [Part] {
        let ch = l.change
        switch ch.kind {
        case .replaced:
            return [.icon(l.oldIcon, gray: true), .text("→", theme.fg2, 500), .icon(l.icon, gray: false),
                    .text(ch.app.label, theme.fg, 600), .text("replaces \(ch.old?.label ?? "")", theme.fg2, 400)]
        case .added:
            return [.badge("+", theme.green), .icon(l.icon, gray: false), .text(ch.app.label, theme.fg, 600)]
        case .removed:
            return [.badge("−", theme.red), .icon(l.icon, gray: true), .text(ch.app.label, theme.fg2, 500)]
        case .moved:
            return [.text("↕", theme.fg2, 600), .icon(l.icon, gray: false), .text(ch.app.label, theme.fg, 600)]
        }
    }

    func pillMetrics(_ parts: [Part], _ h: Double) -> (w: Double, fs: Int, isz: Int, gap: Int) {
        let fs = Int(h * 0.42), isz = Int(h * 0.62), gap = Int(h * 0.22)
        var w = h * 0.42 * 2 - Double(gap)
        for p in parts {
            switch p {
            case .icon: w += Double(isz)
            case .badge: w += Double(Int(h * 0.4))
            case .text(let s, _, let weight): w += type.width(s, fs, weight)
            }
            w += Double(gap)
        }
        return (Double(Int(w)), fs, isz, gap)
    }

    func drawPill(_ c: Canvas, _ frosted: [(CGImage, Double)], x: Double, y: Double, h: Double, _ parts: [Part],
                  alpha: Double) {
        let (w, fs, isz, gap) = pillMetrics(parts, h)
        let (x, y) = (Double(Int(x)), Double(Int(y)))
        c.layer(alpha: alpha) {
            glass(c, frosted, CGRect(x: x, y: y, width: w, height: h), radius: Double(Int(h) / 2), fill: theme.pill,
                  stroke: theme.stroke)
            var cx = x + h * 0.42
            for p in parts {
                switch p {
                case .badge(let sign, let color):
                    let b = Double(Int(h * 0.4))
                    badge(c, sign, color, CGRect(x: Double(Int(cx)), y: Double(Int(y + (h - b) / 2)), width: b, height: b))
                    cx += b + Double(gap)
                case .icon(let rel, let gray):
                    let s = Double(isz)
                    drawIcon(c, rel, CGRect(x: Double(Int(cx)), y: Double(Int(y + (h - s) / 2)), width: s, height: s),
                             alpha: gray ? 0.8 : 1, gray: gray)
                    cx += s + Double(gap)
                case .text(let s, let color, let weight):
                    type.draw(c, s, at: CGPoint(x: cx, y: y + h / 2), size: fs, weight: weight, color: color, anchor: Anchor("lm"))
                    cx += type.width(s, fs, weight) + Double(gap)
                }
            }
        }
    }

    func badge(_ c: Canvas, _ sign: String, _ color: RGBA, _ r: CGRect) {
        c.fill(CGPath(ellipseIn: r, transform: nil), color.alpha(255))
        let arm = r.width * 0.26, lw = max(2, Double(Int(r.width * 3 * 0.13)) / 3)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.midX - arm, y: r.midY))
        path.addLine(to: CGPoint(x: r.midX + arm, y: r.midY))
        if sign == "+" {
            path.move(to: CGPoint(x: r.midX, y: r.midY - arm))
            path.addLine(to: CGPoint(x: r.midX, y: r.midY + arm))
        }
        c.stroke(path, RGBA(255, 255, 255), width: lw)
    }

    func drawLabels(_ c: Canvas, _ frosted: [(CGImage, Double)], _ s: FrameState) {
        let labels = s.labels.filter { $0.alpha > 0.01 }
        guard !labels.isEmpty else { return }
        let h: Double = geo.horizontal ? 62 : 58
        let allParts = labels.map(parts)
        let widths = allParts.map { pillMetrics($0, h).w }
        let F = format
        if geo.horizontal {
            let anchors = labels.map { geo.iconCenter($0.anchor, s.length).x }
            let placed = placeLabels(Array(zip(anchors, widths)), gap: 16)
            let top = geo.cross - geo.thickness / 2
            for k in labels.indices {
                let l = labels[k], w = widths[k], pl = placed[k], ax = anchors[k]
                let x = min(max(pl.start, Double(F.margin) * 0.5), Double(F.width) - Double(F.margin) * 0.5 - w)
                let y = top - 70 - h - Double(pl.row) * (h + 18) + 16 * (1 - l.alpha)
                let line = CGMutablePath()
                line.move(to: CGPoint(x: ax, y: y + h))
                line.addLine(to: CGPoint(x: ax, y: top - 8))
                c.stroke(line, theme.fg.alpha(Double(Int(120 * l.alpha))), width: 2)
                drawPill(c, frosted, x: x, y: y, h: h, allParts[k], alpha: l.alpha)
            }
        } else {
            let anchors = labels.map { geo.iconCenter($0.anchor, s.length).y }
            let order = labels.indices.sorted { (anchors[$0], $0) < (anchors[$1], $1) }
            var ys: [Int: Double] = [:], prevEnd = -1e9
            for k in order {  // nudge down to avoid overlaps
                let y = max(anchors[k] - h / 2, prevEnd + 12)
                ys[k] = y
                prevEnd = y + h
            }
            let x0 = geo.cross + geo.thickness / 2
            for k in labels.indices {
                let l = labels[k], y = ys[k]!
                let x = x0 + 56 - 16 * (1 - l.alpha)
                let line = CGMutablePath()
                line.move(to: CGPoint(x: x0 + 10, y: anchors[k]))
                line.addLine(to: CGPoint(x: x0 + 30, y: anchors[k]))
                line.addLine(to: CGPoint(x: x0 + 44, y: y + h / 2))
                line.addLine(to: CGPoint(x: x, y: y + h / 2))
                c.stroke(line, theme.fg.alpha(Double(Int(120 * l.alpha))), width: 2, round: true)
                drawPill(c, frosted, x: x, y: y, h: h, allParts[k], alpha: l.alpha)
            }
        }
    }

    // MARK: header, progress, outro

    func text(_ c: Canvas, _ s: String, _ p: CGPoint, _ size: Int, _ weight: Int, _ color: RGBA? = nil,
              anchor: String = "la", tracking: Double = 0, alpha: Double = 1) {
        type.draw(c, s, at: p, size: size, weight: weight, color: color ?? theme.fg, anchor: Anchor(anchor),
                  tracking: tracking, alpha: alpha)
    }

    func drawHeader(_ c: Canvas, _ s: FrameState) {
        let F = format, land = landscape
        let (x, y) = (Double(F.margin), land ? 96.0 : 150.0)
        let a = (1 - s.title) * (1 - s.outro)
        if a > 0.01 {
            text(c, "MY DOCK", CGPoint(x: x, y: y), land ? 24 : 26, 600, theme.fg2, tracking: 0.14, alpha: a)
            text(c, s.date.long, CGPoint(x: x, y: y + 30), land ? 88 : 92, 650, alpha: a)
            let day = Int(s.day.rounded(.toNearestOrEven))
            let n = s.tiles.filter { $0.slot > 0.5 }.count
            text(c, "Day \(day)   ·   \(n) apps", CGPoint(x: x, y: y + (land ? 140 : 146)), land ? 40 : 42, 450,
                 theme.fg2, alpha: a)
        }
        if s.title > 0.01 {
            let cy = Double(F.height) * (land ? 0.3 : 0.14)
            text(c, "My Dock", CGPoint(x: Double(F.width) / 2, y: cy), land ? 120 : 128, 700, anchor: "ms", alpha: s.title)
            let (a, b) = (first.monthYear, last.monthYear)
            text(c, a == b ? a : "\(a) – \(b)", CGPoint(x: Double(F.width) / 2, y: cy + 64), 40, 450, theme.fg2,
                 anchor: "ms", alpha: s.title)
        }
    }

    func drawProgress(_ c: Canvas, _ s: FrameState) {
        let F = format, land = landscape
        let y = Double(F.height) - (land ? 86 : 104)
        let (x0, x1) = (Double(F.margin), Double(F.width - F.margin))
        c.fill(roundedRect(CGRect(x: x0, y: y - 2, width: x1 - x0, height: 4), radius: 2), theme.track)
        let px = x0 + (x1 - x0) * clamp01(s.progress)
        c.fill(roundedRect(CGRect(x: x0, y: y - 2, width: max(4, px - x0), height: 4), radius: 2), theme.fg.alpha(230))
        let span = Double(max(1, timeline.spanDays))
        for sc in timeline.scenes {
            let tx = x0 + (x1 - x0) * Double(sc.day - timeline.scenes[0].day) / span
            c.fill(CGPath(ellipseIn: CGRect(x: tx - 5, y: y - 5, width: 10, height: 10), transform: nil),
                   theme.fg.alpha(tx <= px + 0.5 ? 255 : 90))
        }
        c.fill(CGPath(ellipseIn: CGRect(x: px - 9, y: y - 9, width: 18, height: 18), transform: nil), theme.fg.alpha(255))
        let fs = land ? 24 : 26
        text(c, first.short, CGPoint(x: x0, y: y + 22), fs, 500, theme.fg2, anchor: "lt")
        text(c, last.short, CGPoint(x: x1, y: y + 22), fs, 500, theme.fg2, anchor: "rt")
    }

    func drawOutro(_ c: Canvas, _ s: FrameState) {
        guard s.outro > 0.01 else { return }
        let F = format, a = s.outro
        let rise = 24 * (1 - easeOut(a))
        if landscape {
            let (cx, y) = (Double(F.width) / 2, Double(F.height) * 0.25 + rise)
            text(c, summary.headline, CGPoint(x: cx, y: y), 84, 700, anchor: "ms", alpha: a)
            for (k, line) in summary.lines().enumerated() {
                text(c, line, CGPoint(x: cx, y: y + 66 + Double(k) * 46), 34, 450, theme.fg2, anchor: "ms", alpha: a)
            }
        } else {
            let x = Double(F.margin), y = 150 + rise
            text(c, "MY DOCK", CGPoint(x: x, y: y), 26, 600, theme.fg2, tracking: 0.14, alpha: a)
            let halves = summary.headline.components(separatedBy: "  ")
            text(c, halves[0], CGPoint(x: x, y: y + 30), 92, 700, alpha: a)
            text(c, halves.dropFirst().joined(separator: "  "), CGPoint(x: x, y: y + 130), 92, 700, alpha: a)
            let lx = geo.cross + geo.thickness / 2 + 60
            for (k, line) in summary.lines(wrap: true).enumerated() {
                let heading = line.hasSuffix(":")
                text(c, line, CGPoint(x: lx, y: Double(F.height) * 0.42 + Double(k) * 50 + rise), 36, heading ? 600 : 450,
                     heading ? theme.fg : theme.fg2, alpha: a)
            }
        }
    }
}
