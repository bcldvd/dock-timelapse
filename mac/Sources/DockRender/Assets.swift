import CoreGraphics
import CoreImage
import DockCore
import Foundation

public enum Background: String, CaseIterable, Sendable {
    /// Blurred real wallpaper, light text.
    case wallpaper
    /// Sharp wallpaper.
    case desktop
    /// Apple-keynote white, dark text.
    case white
}

struct Theme {
    let fg: RGBA, fg2: RGBA, plate: RGBA, stroke: RGBA
    let shadow: Double
    let green: RGBA, red: RGBA, pill: RGBA, track: RGBA

    static func of(_ b: Background) -> Theme {
        switch b {
        case .white:
            Theme(fg: RGBA(29, 29, 31), fg2: RGBA(29, 29, 31, 150), plate: RGBA(255, 255, 255, 190),
                  stroke: RGBA(0, 0, 0, 22), shadow: 38, green: RGBA(40, 170, 70), red: RGBA(230, 55, 45),
                  pill: RGBA(255, 255, 255, 230), track: RGBA(0, 0, 0, 30))
        case .wallpaper, .desktop:
            Theme(fg: RGBA(255, 255, 255), fg2: RGBA(255, 255, 255, 175), plate: RGBA(255, 255, 255, 46),
                  stroke: RGBA(255, 255, 255, 90), shadow: 70, green: RGBA(48, 209, 88), red: RGBA(255, 69, 58),
                  pill: RGBA(18, 20, 26, 120), track: RGBA(255, 255, 255, 60))
        }
    }
}

/// Loads and caches everything a frame draws from disk: backgrounds per wallpaper, icons per size.
final class Assets: @unchecked Sendable {
    let root: URL
    let size: (Int, Int)
    let mode: Background
    private let ci = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
    private var backgrounds: [String: (CGImage, CGImage)] = [:]
    private var icons: [String: CGImage] = [:]
    private var gray: [String: CGImage] = [:]
    private let lock = NSLock()

    init(root: URL, size: (Int, Int), mode: Background) {
        self.root = root
        self.size = size
        self.mode = mode
    }

    // MARK: backgrounds

    /// (base, frosted) for a wallpaper: base is what the scene sits on, frosted is seen through glass.
    func background(_ wallpaper: String?) -> (CGImage, CGImage) {
        let key = mode == .white ? "" : (wallpaper ?? "")
        lock.lock(); defer { lock.unlock() }
        if let bg = backgrounds[key] { return bg }
        let bg = makeBackground(key.isEmpty ? nil : root.appending(path: key))
        backgrounds[key] = bg
        return bg
    }

    private func solid(_ c: RGBA) -> CGImage {
        let ctx = bitmapContext(size.0, size.1)
        ctx.setFillColor(c.cg)
        ctx.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
        return ctx.makeImage()!
    }

    private func makeBackground(_ url: URL?) -> (CGImage, CGImage) {
        let (w, h) = (Double(size.0), Double(size.1))
        guard mode != .white, let url, let src = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            return mode == .white ? (solid(RGBA(245, 245, 247)), solid(RGBA(255, 255, 255)))
                                  : (solid(RGBA(38, 44, 58)), solid(RGBA(70, 76, 92)))
        }
        // Cover-fit, centered.
        let e = src.extent
        let k = max(w / e.width, h / e.height)
        var wp = src.transformed(by: CGAffineTransform(scaleX: k, y: k))
        wp = wp.transformed(by: CGAffineTransform(translationX: -(wp.extent.midX - w / 2), y: -(wp.extent.midY - h / 2)))
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        wp = wp.cropped(to: frame)

        func blur(_ img: CIImage, _ radius: Double, scale: Double) -> CIImage {
            // Blur at 1/scale resolution (as the Python renderer did), then scale back up.
            let small = img.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: small.extent)
            return blurred.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: frame)
        }
        var base = mode == .desktop ? wp.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: frame)
                                    : blur(wp, 7, scale: 4)
        // Darken for legible white type, a bit more at the top where the header sits (41% → 11%).
        let top = CIColor(red: 8 / 255, green: 10 / 255, blue: 14 / 255, alpha: 105 / 255)
        let bottom = CIColor(red: 8 / 255, green: 10 / 255, blue: 14 / 255, alpha: (105 - 255 * 0.3) / 255)
        let shade = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: h), "inputColor0": top,
            "inputPoint1": CIVector(x: 0, y: 0), "inputColor1": bottom,
        ])!.outputImage!.cropped(to: frame)
        base = shade.composited(over: base)
        var frosted = blur(wp, 14, scale: 4)
        frosted = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.18)).cropped(to: frame).composited(over: frosted)
        return (ci.createCGImage(base, from: frame)!, ci.createCGImage(frosted, from: frame)!)
    }

    // MARK: shadows

    private var shadows: [String: CGImage] = [:]

    /// A soft shadow for a w×h rounded rect: the shape blurred by `blur`, padded by 2×blur on each side.
    /// Rendered at reduced resolution (a big blur has no fine detail) and cached per size.
    func shadow(width w: Int, height h: Int, radius: Double, blur: Double) -> CGImage? {
        let key = "\(w)x\(h)r\(Int(radius))b\(Int(blur))"
        lock.lock(); defer { lock.unlock() }
        if let img = shadows[key] { return img }
        let scale = max(1, blur / 6)
        let pad = 2 * blur
        let W = Int(((Double(w) + 2 * pad) / scale).rounded(.up)), H = Int(((Double(h) + 2 * pad) / scale).rounded(.up))
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        let rect = CGRect(x: pad / scale, y: pad / scale, width: Double(w) / scale, height: Double(h) / scale)
        ctx.addPath(roundedRect(rect, radius: radius / scale))
        ctx.fillPath()
        guard let mask = ctx.makeImage() else { return nil }
        let blurred = CIImage(cgImage: mask).clampedToExtent().applyingGaussianBlur(sigma: blur / scale)
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        guard let img = ci.createCGImage(blurred, from: blurred.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        else { return nil }
        if shadows.count > 256 { shadows.removeAll() }
        shadows[key] = img
        return img
    }

    // MARK: icons

    /// The icon cropped to its visible tile (macOS icons carry ~10% transparent margin), or nil.
    func icon(_ rel: String?) -> CGImage? {
        guard let rel else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let img = icons[rel] { return img }
        guard let raw = loadImage(root.appending(path: rel)) else { return nil }
        let img = cropToVisible(raw)
        icons[rel] = img
        return img
    }

    func grayIcon(_ rel: String?) -> CGImage? {
        guard let rel, let color = icon(rel) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let img = gray[rel] { return img }
        let out = CIImage(cgImage: color).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let img = ci.createCGImage(out, from: out.extent) ?? color
        gray[rel] = img
        return img
    }
}

/// Crop to a square around the pixels with alpha > 8.
func cropToVisible(_ image: CGImage) -> CGImage {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                        bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return image }
    var (x0, y0, x1, y1) = (w, h, -1, -1)
    for y in 0..<h {
        let row = data + y * w
        for x in 0..<w where row[x] > 8 {
            if x < x0 { x0 = x }
            if x > x1 { x1 = x }
            if y < y0 { y0 = y }
            if y > y1 { y1 = y }
        }
    }
    guard x1 >= x0 else { return image }
    let side = Double(max(x1 + 1 - x0, y1 + 1 - y0))
    let cx = Double(x0 + x1 + 1) / 2, cy = Double(y0 + y1 + 1) / 2
    let rect = CGRect(x: Int(cx - side / 2), y: Int(cy - side / 2), width: Int(side), height: Int(side))
    // Pad instead of clipping when the square pokes outside the image.
    let out = bitmapContext(Int(side), Int(side))
    out.draw(image, in: CGRect(x: -rect.minX, y: -(Double(h) - rect.maxY), width: Double(w), height: Double(h)))
    return out.makeImage() ?? image
}
