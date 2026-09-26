import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// 0–255 RGBA, as the Python themes were written.
public struct RGBA: Hashable, Sendable {
    public let r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 255) {
        (self.r, self.g, self.b, self.a) = (r, g, b, a)
    }

    public func alpha(_ a: Double) -> RGBA { RGBA(r, g, b, a) }
    public func scaled(_ k: Double) -> RGBA { RGBA(r, g, b, a * k) }
    var cg: CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a / 255) }
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// A top-left-origin drawing surface over a CGContext (y grows downwards, like Pillow).
struct Canvas {
    let ctx: CGContext
    let width: Int
    let height: Int

    init(_ ctx: CGContext, width: Int, height: Int) {
        self.ctx = ctx
        self.width = width
        self.height = height
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// Black at `alpha` (0–255) through `mask`, top-left at (x, y), composited straight into the pixels with
    /// integer math, so it comes out the same however many renders run at once. Pixels inside `hole` (a rounded
    /// rect about to be covered by opaque glass) are left alone, which also keeps it right under a fading
    /// transparency layer: outside the glass, only the shadow would have shown through it.
    func darken(_ mask: ShadowMask, x: Int, y: Int, alpha: Int, hole: CGRect, radius: Double) {
        guard alpha > 0, let base = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let rowBytes = ctx.bytesPerRow
        let (x0, x1) = (max(0, x), min(width, x + mask.width))
        let (y0, y1) = (max(0, y), min(height, y + mask.height))
        guard x0 < x1, y0 < y1 else { return }
        let inner = hole.insetBy(dx: 1, dy: 1)  // the glass's antialiased edge still gets its shadow
        let rr = max(0, min(radius - 1, inner.width / 2, inner.height / 2))
        let (hx, hy) = (inner.width / 2 - rr, inner.height / 2 - rr)
        let alpha = UInt32(alpha)
        mask.bytes.withUnsafeBufferPointer { m in
            for py in y0..<y1 {
                // The pixels of this row the glass covers: [skipFrom, skipTo).
                var (skipFrom, skipTo) = (x1, x1)
                let dy = max(0, abs(Double(py) + 0.5 - inner.midY) - hy)
                if !inner.isEmpty && dy <= rr {
                    let half = hx + (rr * rr - dy * dy).squareRoot()
                    skipFrom = max(x0, Int((inner.midX - half - 0.5).rounded(.up)))
                    skipTo = min(x1, Int((inner.midX + half - 0.5).rounded(.down)) + 1)
                }
                let row = base + py * rowBytes
                let mrow = (py - y) * mask.width - x
                var px = x0
                while px < x1 {
                    if px == skipFrom && skipFrom < skipTo { px = skipTo; continue }
                    let a = alpha * UInt32(m[mrow + px])  // 0…65025
                    if a > 0 {
                        let keep = 65025 - a
                        let p = row + px * 4
                        p[0] = UInt8((UInt32(p[0]) * keep + 32512) / 65025)
                        p[1] = UInt8((UInt32(p[1]) * keep + 32512) / 65025)
                        p[2] = UInt8((UInt32(p[2]) * keep + 32512) / 65025)
                        p[3] = UInt8((UInt32(p[3]) * keep + 32512) / 65025)
                    }
                    px += 1
                }
            }
        }
    }

    func image(_ img: CGImage, in rect: CGRect, alpha: Double = 1) {
        ctx.saveGState()
        if alpha < 0.999 { ctx.setAlpha(alpha) }
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    func fill(_ path: CGPath, _ color: RGBA) {
        ctx.addPath(path)
        ctx.setFillColor(color.cg)
        ctx.fillPath()
    }

    func stroke(_ path: CGPath, _ color: RGBA, width: Double, round: Bool = false) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color.cg)
        ctx.setLineWidth(width)
        if round { ctx.setLineJoin(.round); ctx.setLineCap(.round) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    func withClip(_ path: CGPath, _ body: () -> Void) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        body()
        ctx.restoreGState()
    }

    func layer(alpha: Double, _ body: () -> Void) {
        if alpha >= 0.999 { body(); return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

func roundedRect(_ r: CGRect, radius: Double) -> CGPath {
    let rr = max(0, min(radius, r.width / 2, r.height / 2))
    return CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
}

// MARK: text

/// Pillow-style text anchors: horizontal l/m/r, vertical a (ascender), t (top), m (middle), s (baseline).
struct Anchor {
    let h: Character
    let v: Character
    init(_ s: String) { (h, v) = (s.first!, s.last!) }
}

final class Typesetter: @unchecked Sendable {
    private var fonts: [Int: CTFont] = [:]
    private var lines: [String: (CTLine, Double, Double, Double)] = [:]
    private let lock = NSLock()

    /// San Francisco at an exact variable weight (100–1000), like the Python renderer's SFNS axes.
    func font(_ size: Int, _ weight: Int) -> CTFont {
        let key = size * 10_000 + weight
        if let f = fonts[key] { return f }
        let base = CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)!
        let wght: UInt32 = 0x7767_6874  // 'wght'
        let desc = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(base), [
            kCTFontVariationAttribute: [wght: weight],
        ] as CFDictionary)
        let f = CTFontCreateWithFontDescriptor(desc, CGFloat(size), nil)
        fonts[key] = f
        return f
    }

    /// (line, width, ascent, descent)
    func line(_ text: String, _ size: Int, _ weight: Int, tracking: Double = 0) -> (CTLine, Double, Double, Double) {
        lock.lock(); defer { lock.unlock() }
        let key = "\(size)|\(weight)|\(tracking)|\(text)"
        if let l = lines[key] { return l }
        let f = font(size, weight)
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        if tracking != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking * Double(size) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        var width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        if tracking != 0 && !text.isEmpty { width -= tracking * Double(size) }  // no trailing space
        let entry = (line, width, Double(ascent), Double(descent))
        if lines.count > 2000 { lines.removeAll() }
        lines[key] = entry
        return entry
    }

    func width(_ text: String, _ size: Int, _ weight: Int) -> Double { line(text, size, weight).1 }

    @discardableResult
    func draw(_ canvas: Canvas, _ text: String, at p: CGPoint, size: Int, weight: Int, color: RGBA,
              anchor: Anchor = Anchor("la"), tracking: Double = 0, alpha: Double = 1) -> Double {
        let (line, width, ascent, descent) = self.line(text, size, weight, tracking: tracking)
        var x = p.x
        if anchor.h == "m" { x -= width / 2 } else if anchor.h == "r" { x -= width }
        let baseline: Double = switch anchor.v {
        case "a": p.y + ascent
        case "t": p.y + CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).maxY  // top of the glyphs
        case "m": p.y + (ascent - descent) / 2
        case "d", "b": p.y - descent
        default: p.y
        }
        canvas.ctx.saveGState()
        canvas.ctx.setFillColor(color.scaled(alpha).cg)
        canvas.ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, canvas.ctx)
        canvas.ctx.restoreGState()
        return width
    }
}

func loadImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
}

func bitmapContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}
