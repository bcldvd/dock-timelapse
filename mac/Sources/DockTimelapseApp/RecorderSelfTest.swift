import AppKit
import Foundation
import ServiceManagement

/// `--selftest-recorder <report>`: register the login-item agent, let it run once, unregister, write what
/// happened. Leaves any existing recorder alone. Used to verify a build on a real Mac.
enum RecorderSelfTest {
    static func run(report: URL) {
        let service = SMAppService.agent(plistName: "io.github.bcldvd.DockTimelapse.recorder.plist")
        var lines = ["before: \(service.status.rawValue)"]
        do {
            try service.register()
            lines.append("registered: \(service.status.rawValue)")
        } catch {
            lines.append("register error: \(error)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            lines.append("after 6s: \(service.status.rawValue)")
            do { try service.unregister(); lines.append("unregistered: \(service.status.rawValue)") }
            catch { lines.append("unregister error: \(error)") }
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
