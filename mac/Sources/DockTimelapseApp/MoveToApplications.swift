import AppKit
import DockMac
import Foundation

/// Opened straight from the DMG or from Downloads, macOS runs the app from a temporary copy
/// ("translocation"): background recording registered from there breaks once the DMG is ejected.
/// Offer to move it to Applications, the way polished Mac apps do.
enum MoveToApplications {
    static func needsMove() -> Bool {
        runsFromTemporaryLocation(Bundle.main.bundlePath, home: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @MainActor static func offerIfNeeded() {
        guard needsMove() else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Dock Timelapse to Applications?"
        alert.informativeText = "It needs to live in your Applications folder to keep recording in the background."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.icon = NSApp.applicationIconImage
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let target = try move()
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            let fail = NSAlert()
            fail.messageText = "Dock Timelapse couldn't be moved"
            fail.informativeText = "Drag it into your Applications folder from the Finder. (\(error.localizedDescription))"
            fail.runModal()
        }
    }

    /// Copy into /Applications (or ~/Applications without admin rights); an older copy is quit and goes to the Trash.
    @MainActor static func move() throws -> URL {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let candidates = [URL(fileURLWithPath: "/Applications"),
                          fm.homeDirectoryForCurrentUser.appending(path: "Applications")]
        var lastError: Error?
        for dir in candidates {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = dir.appending(path: source.lastPathComponent)
                if fm.fileExists(atPath: target.path) {
                    if let id = Bundle.main.bundleIdentifier { quitInstances(at: target, bundleID: id) }
                    try fm.trashItem(at: target, resultingItemURL: nil)
                }
                try fm.copyItem(at: source, to: target)
                // Out of Downloads, the original copy is just clutter.
                if source.path.hasPrefix(fm.homeDirectoryForCurrentUser.path + "/Downloads/") {
                    try? fm.trashItem(at: source, resultingItemURL: nil)
                }
                return target
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }
}
