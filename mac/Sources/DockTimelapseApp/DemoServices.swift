import DockAppModel
import DockCore
import DockMac
import Foundation

/// In-memory stand-ins for the system, for screenshots and UI testing (`--demo`).
///   --demo-recorder on|off|approval   --demo-fda yes|no   --demo-tm none|ok|missing
enum DemoServices {
    final class MemoryRecorder: Recorder, @unchecked Sendable {
        var state: RecorderState
        init(_ state: RecorderState) { self.state = state }
        func start() throws { state = .on }
        func stop() throws { state = .off }
    }

    static func value(_ args: [String], _ key: String, _ fallback: String) -> String {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return fallback }
        return args[i + 1]
    }

    static func make(_ args: [String]) -> AppServices {
        var s = AppServices.live()
        let recorder: RecorderState = switch value(args, "--demo-recorder", "off") {
        case "on": .on
        case "approval": .needsApproval
        default: .off
        }
        s.recorder = MemoryRecorder(recorder)
        let fda = value(args, "--demo-fda", "yes") == "yes"
        let fdaGranted = Box(fda)
        s.hasFullDiskAccess = {
            // Simulate the user granting access a few seconds after being asked.
            if !fdaGranted.value { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { fdaGranted.value = true } }
            return fdaGranted.value
        }
        let tm = value(args, "--demo-tm", "ok")
        s.timeMachineConfigured = { tm != "none" }
        s.listBackups = {
            if tm == "missing" { throw DockError.noTimeMachineBackups(detail: "No machine directory found for host.") }
            Thread.sleep(forTimeInterval: 1.5)
            return []
        }
        s.legacyRecorderInstalled = { args.contains("--demo-legacy") }
        return s
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }
}

extension AppModel {
    /// `--demo-state rendering|finished|failed|fda|importing|imported|import-failed`: show a state for review.
    func applyDemoState(_ args: [String]) {
        let state = DemoServices.value(args, "--demo-state", "")
        let videos = services.outputDir
        switch state {
        case "rendering": render = .rendering(fraction: 0.42, step: "Making the landscape video…")
        case "finished":
            render = .finished(Video(files: ["landscape": videos.appending(path: "Dock Landscape.mp4"),
                                             "portrait": videos.appending(path: "Dock Portrait.mp4")],
                                     isPreview: args.contains("--demo-preview"), background: .wallpaper))
        case "failed": render = .failed("The video couldn't be made: the disk is full.")
        case "fda": importState = .needsFullDiskAccess
        case "importing": importState = .running(fraction: 0.6)
        case "imported": importState = .finished(ImportResult(backups: 52, read: 52, added: 9, first: "2024-03-02", last: "2026-08-30"))
        case "import-failed": importState = .failed(.noTimeMachineBackups(detail: nil))
        case "make-video": makeVideo()
        default: break
        }
    }
}
