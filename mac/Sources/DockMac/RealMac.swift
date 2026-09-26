import AppKit
import DockCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The real Mac: the Dock's own preferences, app icons and the desktop picture.
public struct RealMac: MacSystem {
    public init() {}

    public func currentDock() throws -> [DockApp] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let tiles = CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] else {
            throw DockError.dockUnreadable
        }
        return parseDockPrefs(["persistent-apps": tiles])
    }

    public func iconPNG(for app: DockApp) -> Data? {
        guard !app.path.isEmpty, FileManager.default.fileExists(atPath: app.path) else { return nil }
        // Resolve symlinks (e.g. /Applications/Safari.app) or macOS adds an alias arrow badge.
        let path = URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path
        let image = NSWorkspace.shared.icon(forFile: path)
        return pngData(image, size: 512)
    }

    public func wallpaper() -> Wallpaper? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return loadWallpaper(url)
    }
}

/// Draw an NSImage (all representations considered) into an exact `size`² RGBA PNG.
func pngData(_ image: NSImage, size: Int) -> Data? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let cg = ctx.makeImage() else { return nil }
    return encode(cg, type: .png)
}

func encode(_ image: CGImage, type: UTType, quality: Double = 0.9) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}

/// JPEG/PNG wallpapers are kept as-is; anything else (HEIC, dynamic desktops, TIFF) becomes a JPEG
/// of at most 3840 px so the renderer and old Python versions can read it.
func loadWallpaper(_ url: URL) -> Wallpaper? {
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension.lowercased()
    if ["jpg", "jpeg", "png"].contains(ext), let data = try? Data(contentsOf: url) {
        return Wallpaper(stem: stem, suffix: "." + (ext == "jpeg" ? "jpg" : ext), data: data)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 3840,
                                    kCGImageSourceCreateThumbnailWithTransform: true]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
          let jpeg = encode(image, type: .jpeg) else { return nil }
    return Wallpaper(stem: stem, suffix: ".jpg", data: jpeg)
}
