import AppKit
import DockCore
import Foundation
import Testing
@testable import DockMac

func fakeRunner(_ status: Int32, _ out: String, _ err: String = "") -> (String, [String]) -> CommandResult {
    { _, _ in CommandResult(status: status, stdout: out, stderr: err) }
}

@Test func listBackupsParsesTmutilOutput() throws {
    let out = """
    /Volumes/.timemachine/ABC/2026-02-01-100000.backup/2026-02-01-100000.backup
    /Volumes/.timemachine/ABC/2026-01-01-093000.backup/2026-01-01-093000.backup
    """
    let b = try TimeMachine.listBackups(runner: fakeRunner(0, out))
    #expect(b.map(\.when.iso) == ["2026-01-01T09:30:00", "2026-02-01T10:00:00"])
}

@Test func listBackupsExplainsMissingDiskAndPermission() {
    #expect(throws: DockError.noTimeMachineBackups(detail: "No machine directory found for host.")) {
        try TimeMachine.listBackups(runner: fakeRunner(1, "", "No machine directory found for host."))
    }
    #expect(throws: DockError.fullDiskAccessNeeded(path: "your Time Machine backups")) {
        try TimeMachine.listBackups(runner: fakeRunner(1, "", "tmutil: listbackups requires Full Disk Access privileges."))
    }
}

@Test func timeMachineConfiguredDetection() {
    #expect(!TimeMachine.isConfigured(runner: fakeRunner(0, "tmutil: No destinations configured.")))
    #expect(TimeMachine.isConfigured(runner: fakeRunner(0, "Name : Backup\nKind : Local")))
}

@Test func launchAgentPlistRunsCaptureAndLogsToDataDir() {
    let data = URL(fileURLWithPath: "/tmp/custom-data")
    let p = LaunchAgentRecorder.plist(executable: "/usr/local/bin/dock-timelapse", data: data)
    #expect(p["ProgramArguments"] as? [String] == ["/usr/local/bin/dock-timelapse", "--data", "/tmp/custom-data", "capture"])
    #expect(p["StartInterval"] as? Int == 3600 && p["RunAtLoad"] as? Bool == true)
    #expect(p["StandardErrorPath"] as? String == "/tmp/custom-data/capture-errors.log")
}

@Test func wallpaperLoaderConvertsNonJPEGToJPEG() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "wp-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let tiff = dir.appending(path: "Green Hills.tiff")
    try encode(ctx.makeImage()!, type: .tiff)!.write(to: tiff)
    let wp = try #require(loadWallpaper(tiff))
    #expect(wp.stem == "Green Hills" && wp.suffix == ".jpg" && wp.data.starts(with: [0xFF, 0xD8]))
    let png = dir.appending(path: "a.png")
    try encode(ctx.makeImage()!, type: .png)!.write(to: png)
    #expect(loadWallpaper(png)?.suffix == ".png")
    #expect(loadWallpaper(dir.appending(path: "missing.heic")) == nil)
}

// MARK: against this Mac

@Test func readsTheRealDock() throws {
    let dock = try RealMac().currentDock()
    #expect(!dock.isEmpty)
    #expect(dock.allSatisfy { !$0.label.isEmpty })
}

@Test func iconIsA512PNGAndMissingAppsHaveNone() throws {
    let png = try #require(RealMac().iconPNG(for: DockApp(label: "Finder", bundleID: "com.apple.finder",
                                                          path: "/System/Library/CoreServices/Finder.app")))
    let image = try #require(NSBitmapImageRep(data: png))
    #expect(image.pixelsWide == 512 && image.pixelsHigh == 512)
    #expect(RealMac().iconPNG(for: DockApp(label: "Gone", bundleID: "x", path: "/Applications/Nope-\(UUID()).app")) == nil)
}

@Test func detectsTemporaryAppLocations() {
    let home = "/Users/me"
    for path in ["/private/var/folders/x/AppTranslocation/ABC/d/Dock Timelapse.app", "/Volumes/Dock Timelapse/Dock Timelapse.app",
                 "/Users/me/Downloads/Dock Timelapse.app"] {
        #expect(runsFromTemporaryLocation(path, home: home), "\(path)")
    }
    for path in ["/Applications/Dock Timelapse.app", "/Users/me/Applications/Dock Timelapse.app",
                 "/Users/me/Work/mac/build/Dock Timelapse.app"] {
        #expect(!runsFromTemporaryLocation(path, home: home), "\(path)")
    }
}
