import DockCore
import Foundation
import ServiceManagement

/// The hourly background job that records the Dock, even when the app isn't open.
public enum RecorderState: Equatable, Sendable {
    case on
    case off
    /// macOS wants the user to allow it in System Settings → General → Login Items.
    case needsApproval
}

public protocol Recorder: Sendable {
    var state: RecorderState { get }
    func start() throws
    func stop() throws
}

public let legacyAgentLabels = ["io.github.bcldvd.dock-timelapse", "com.bcldvd.dock-timelapse"]

/// Inside Dock Timelapse.app: a login-item agent registered with `SMAppService`. It runs the bundled CLI
/// (`Contents/MacOS/dock-timelapse capture`) hourly; its plist ships in `Contents/Library/LaunchAgents`.
public struct AppRecorder: Recorder {
    public static let plistName = "io.github.bcldvd.DockTimelapse.recorder.plist"
    var service: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    public init() {}

    public var state: RecorderState {
        switch service.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    public func start() throws {
        LaunchAgentRecorder.removeLegacyAgents()
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval { return }
            throw DockError.backgroundRecording(error.localizedDescription)
        }
    }

    public func stop() throws {
        do { try service.unregister() } catch {
            if service.status == .notRegistered || service.status == .notFound { return }
            throw DockError.backgroundRecording(error.localizedDescription)
        }
    }

    @MainActor public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// For the bare CLI (not inside the app): a classic LaunchAgent in ~/Library/LaunchAgents.
public struct LaunchAgentRecorder: Recorder {
    public static let label = "io.github.bcldvd.dock-timelapse"
    let executable: String
    let data: URL

    public init(executable: String, data: URL) {
        self.executable = executable
        self.data = data
    }

    static func plistURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var domain: String { "gui/\(getuid())" }

    public var state: RecorderState {
        FileManager.default.fileExists(atPath: Self.plistURL(Self.label).path) ? .on : .off
    }

    public static func plist(executable: String, data: URL) -> [String: Any] {
        var args = [executable]
        if data.standardizedFileURL != Paths.defaultData.standardizedFileURL { args += ["--data", data.path] }
        return [
            "Label": label,
            "ProgramArguments": args + ["capture"],
            "StartInterval": 3600,
            "RunAtLoad": true,
            "ProcessType": "Background",
            // `capture` appends its own line to capture.log; stderr only catches crashes.
            "StandardErrorPath": data.appending(path: "capture-errors.log").path,
        ]
    }

    public func start() throws {
        try? stop()
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let url = Self.plistURL(Self.label)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try PropertyListSerialization.data(fromPropertyList: Self.plist(executable: executable, data: data),
                                                       format: .xml, options: 0)
        try bytes.write(to: url)
        let r = run("/bin/launchctl", ["bootstrap", Self.domain, url.path])
        if r.status != 0 { throw DockError.backgroundRecording(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public func stop() throws { Self.removeLegacyAgents() }

    /// Remove agents written by this CLI or by the Python version.
    @discardableResult
    public static func removeLegacyAgents() -> [String] {
        var removed: [String] = []
        for label in legacyAgentLabels {
            _ = run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
            let url = plistURL(label)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed.append(label)
            }
        }
        return removed
    }
}

/// The recorder that fits how we're running: the login item inside the app, a LaunchAgent otherwise.
public func currentRecorder(data: URL = Paths.defaultData) -> Recorder {
    if bundledCLI() != nil { return AppRecorder() }
    return LaunchAgentRecorder(executable: CommandLine.executablePath, data: data)
}

/// Contents/MacOS/dock-timelapse when running from Dock Timelapse.app.
public func bundledCLI() -> URL? {
    let bundle = Bundle.main
    guard bundle.bundleURL.pathExtension == "app" else { return nil }
    let cli = bundle.bundleURL.appending(path: "Contents/MacOS/dock-timelapse")
    return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
}

extension CommandLine {
    static var executablePath: String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") { return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path }
        if arg0.contains("/") {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: arg0)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(arg0)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            }
        }
        return arg0
    }
}
