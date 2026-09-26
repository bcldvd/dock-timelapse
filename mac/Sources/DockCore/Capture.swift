import Foundation

/// A desktop picture, normalized to a format the renderer reads (JPEG/PNG).
public struct Wallpaper: Sendable {
    public let stem: String
    public let suffix: String
    public let data: Data

    public init(stem: String, suffix: String, data: Data) {
        self.stem = stem
        self.suffix = suffix
        self.data = data
    }
}

/// The macOS side effects the engine needs. `DockMac.RealMac` implements it; tests use fakes.
public protocol MacSystem: Sendable {
    /// The apps pinned in the Dock right now, in order, up to System Settings.
    func currentDock() throws -> [DockApp]
    /// The app's icon as a 512 px PNG, or nil if the app can't be found at `app.path`.
    func iconPNG(for app: DockApp) -> Data?
    /// The current desktop picture of the main screen.
    func wallpaper() -> Wallpaper?
}

public enum CaptureResult: String, Sendable {
    case saved, unchanged
}

/// One capture attempt: record the Dock if it changed. Safe to run as often as we like (the agent runs
/// hourly); same-day changes fold into today's snapshot.
@discardableResult
public func runCapture(store: Store, mac: MacSystem, now: LocalTime = .now()) throws -> CaptureResult {
    let apps = try mac.currentDock()
    if let last = try store.snapshots().last, last.apps == apps {
        try store.observe(apps, at: now)  // marks the day as checked
        return .unchanged
    }
    let icons = try saveIcons(apps, store: store, mac: mac)
    let wallpaper = try saveWallpaper(store: store, mac: mac)
    return try store.observe(apps, at: now, icons: icons, wallpaper: wallpaper) == nil ? .unchanged : .saved
}

func saveIcons(_ apps: [DockApp], store: Store, mac: MacSystem) throws -> [String: String] {
    var icons: [String: String] = [:]
    for app in apps {
        if let png = mac.iconPNG(for: app) {
            icons[app.key] = try store.contentAddressed(folder: "icons", stem: app.key, suffix: ".png", data: png)
        }
    }
    return icons
}

func saveWallpaper(store: Store, mac: MacSystem) throws -> String? {
    guard let wp = mac.wallpaper() else { return nil }
    return try store.contentAddressed(folder: "wallpapers", stem: wp.stem, suffix: wp.suffix, data: wp.data)
}
