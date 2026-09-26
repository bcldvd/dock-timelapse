import DockCore
import DockMac
import DockRender
import Foundation

/// Progress of a render: (frames done, total). Return false to cancel.
public typealias RenderProgress = @Sendable (Int, Int) -> Bool

/// Everything the app does to the outside world, injectable so the model is testable without a Mac.
public struct AppServices: Sendable {
    public var dataDir: URL
    public var outputDir: URL
    public var mac: MacSystem
    public var recorder: Recorder
    public var listBackups: @Sendable () throws -> [Backup]
    public var timeMachineConfigured: @Sendable () -> Bool
    public var hasFullDiskAccess: @Sendable () -> Bool
    public var legacyRecorderInstalled: @Sendable () -> Bool
    public var render: @Sendable (_ data: URL, _ format: VideoFormat, _ out: URL, _ fps: Int, _ background: Background,
                                  _ progress: @escaping RenderProgress) async throws -> URL
    public var now: @Sendable () -> LocalTime

    public init(dataDir: URL, outputDir: URL, mac: MacSystem, recorder: Recorder,
                listBackups: @escaping @Sendable () throws -> [Backup],
                timeMachineConfigured: @escaping @Sendable () -> Bool,
                hasFullDiskAccess: @escaping @Sendable () -> Bool,
                legacyRecorderInstalled: @escaping @Sendable () -> Bool,
                render: @escaping @Sendable (URL, VideoFormat, URL, Int, Background, @escaping RenderProgress) async throws -> URL,
                now: @escaping @Sendable () -> LocalTime = { .now() }) {
        self.dataDir = dataDir
        self.outputDir = outputDir
        self.mac = mac
        self.recorder = recorder
        self.listBackups = listBackups
        self.timeMachineConfigured = timeMachineConfigured
        self.hasFullDiskAccess = hasFullDiskAccess
        self.legacyRecorderInstalled = legacyRecorderInstalled
        self.render = render
        self.now = now
    }

    /// The real thing.
    public static func live() -> AppServices {
        AppServices(
            dataDir: Paths.defaultData,
            outputDir: Paths.defaultOutput,
            mac: RealMac(),
            recorder: currentRecorder(),
            listBackups: { try TimeMachine.listBackups() },
            timeMachineConfigured: { TimeMachine.isConfigured() },
            hasFullDiskAccess: { Permissions.hasFullDiskAccess() },
            legacyRecorderInstalled: {
                legacyAgentLabels.contains { label in
                    FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
                        .appending(path: "Library/LaunchAgents/\(label).plist").path)
                }
            },
            render: { data, format, out, fps, background, progress in
                try await renderVideo(dataRoot: data, format: format, to: out, fps: fps, background: background,
                                      progress: progress)
            }
        )
    }
}
