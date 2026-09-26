import Foundation
@testable import DockCore

/// The Mac as tests see it. Apps listed in `installed` have an icon; others only if their path exists
/// (a copy inside a backup folder).
final class FakeMac: MacSystem, @unchecked Sendable {
    var dock: [DockApp]
    var installed: Set<String>
    var wallpaperData: Data? = Data("jpg".utf8)
    var askedIcons: [String] = []
    var failDock = false

    init(_ dock: [DockApp] = apps("arc", "slack"), installed: Set<String>? = nil) {
        self.dock = dock
        self.installed = installed ?? Set(dock.map(\.path))
    }

    func currentDock() throws -> [DockApp] {
        if failDock { throw DockError.dockUnreadable }
        return dock
    }

    func iconPNG(for app: DockApp) -> Data? {
        askedIcons.append(app.path)
        let ok = app.path.hasPrefix("/Applications/") || app.path.hasPrefix("/System/")
            ? installed.contains(app.path) : FileManager.default.fileExists(atPath: app.path)
        return ok ? Data("png-\(app.label)".utf8) : nil
    }

    func wallpaper() -> Wallpaper? {
        wallpaperData.map { Wallpaper(stem: "Fresh Grass", suffix: ".jpg", data: $0) }
    }
}
