import DockCore
import DockMac
import DockRender
import Foundation
import Observation

/// What the video settings are, remembered between launches.
public struct VideoSettings: Codable, Equatable, Sendable {
    public var landscape = true
    public var portrait = true
    public var background: Background = .wallpaper
    public var fps = 60

    public init() {}

    public var formats: [VideoFormat] {
        let chosen = [landscape ? VideoFormat.landscape : nil, portrait ? .portrait : nil].compactMap { $0 }
        return chosen.isEmpty ? [.landscape] : chosen
    }
}

extension Background: Codable {}

/// A finished render.
public struct Video: Equatable, Sendable {
    public let files: [String: URL]  // format name → file
    public let isPreview: Bool
    public let background: Background

    public init(files: [String: URL], isPreview: Bool, background: Background) {
        (self.files, self.isPreview, self.background) = (files, isPreview, background)
    }

    public var primary: URL { files["landscape"] ?? files.values.first! }
}

public enum RenderState: Equatable, Sendable {
    case idle
    /// `fraction` of the whole job (all formats), and what's being made right now.
    case rendering(fraction: Double, step: String)
    case finished(Video)
    case failed(String)

    public var isRendering: Bool { if case .rendering = self { true } else { false } }
}

public enum ImportState: Equatable, Sendable {
    case idle
    case needsFullDiskAccess
    case running(fraction: Double)
    case finished(ImportResult)
    case failed(DockError)
}

/// The history in numbers, for the menu and the welcome screen.
public struct Stats: Equatable, Sendable {
    public let days: Int
    public let changes: Int
    public let since: Day?
    public let lastChange: String?
    public let lastChangeDay: Day?
    public let importedCount: Int
}

/// The app's single source of truth. Views read it and call its actions; it talks to the world only through
/// `AppServices`.
@MainActor @Observable
public final class AppModel {
    public let services: AppServices
    private let defaults: UserDefaults

    public private(set) var snapshots: [Snapshot] = []
    public private(set) var currentDock: [DockApp] = []
    public private(set) var recorder: RecorderState = .off
    /// Whether the job, when on, is actually capturing.
    public private(set) var recorderHealth: RecorderHealth = .healthy
    public private(set) var timeMachineConfigured = false
    public private(set) var legacyRecorderFound = false
    public private(set) var historyError: DockError?
    public private(set) var recorderError: DockError?
    public var render: RenderState = .idle
    public var importState: ImportState = .idle
    public var settings: VideoSettings { didSet { save(settings, "videoSettings") } }
    public var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }

    private var renderTask: Task<Void, Never>?
    private var permissionWatch: Task<Void, Never>?

    public init(services: AppServices, defaults: UserDefaults = .standard) {
        self.services = services
        self.defaults = defaults
        settings = (defaults.data(forKey: "videoSettings")).flatMap { try? JSONDecoder().decode(VideoSettings.self, from: $0) }
            ?? VideoSettings()
        onboarded = defaults.bool(forKey: "onboarded")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // MARK: state

    public var store: Store? { try? Store(root: services.dataDir) }

    /// Reload everything from disk and the system. Cheap; call it whenever a surface appears.
    public func refresh() {
        do {
            snapshots = try Store(root: services.dataDir).snapshots()
            historyError = nil
        } catch let error as DockError {
            historyError = error
        } catch {
            historyError = .storageUnavailable(services.dataDir.path)
        }
        currentDock = (try? services.mac.currentDock()) ?? snapshots.last?.apps ?? []
        recorder = services.recorder.state
        recorderHealth = recorder == .on ? DockCore.recorderHealth(dataDir: services.dataDir, now: services.now()) : .healthy
        timeMachineConfigured = services.timeMachineConfigured()
        legacyRecorderFound = services.legacyRecorderInstalled()
    }

    public var stats: Stats {
        let first = snapshots.first?.day
        let last = snapshots.dropFirst().last
        return Stats(
            days: first.map { services.now().day.days(since: $0) + 1 } ?? 0,
            changes: snapshots.dropFirst().reduce(0) { $0 + $1.changes.count },
            since: first,
            lastChange: last?.changes.first.map { c in
                last!.changes.count > 1 ? "\(c.describe) and \(last!.changes.count - 1) more" : c.describe
            },
            lastChangeDay: last?.day,
            importedCount: snapshots.filter(\.isImported).count
        )
    }

    /// Enough history for a real video (a single snapshot renders "Day 1", which isn't much of a story).
    public var hasStory: Bool { snapshots.count >= 2 }

    /// Icon file for an app, from the most recent snapshot that has one.
    public func iconURL(for app: DockApp) -> URL? {
        for s in snapshots.reversed() {
            if let rel = s.icons[app.key] { return services.dataDir.appending(path: rel) }
        }
        return nil
    }

    // MARK: recording

    public func startRecording() {
        withRecorder {
            try services.recorder.start()
            _ = try? runCapture(store: Store(root: services.dataDir), mac: services.mac, now: services.now())
        }
    }

    public func stopRecording() {
        withRecorder { try services.recorder.stop() }
    }

    /// Re-register the job when it has stopped capturing; registering runs it right away.
    public func restartRecording() {
        withRecorder {
            try services.recorder.stop()
            try services.recorder.start()
            _ = try? runCapture(store: Store(root: services.dataDir), mac: services.mac, now: services.now())
        }
        Task { [weak self] in  // the job logs its first run a moment later
            try? await Task.sleep(for: .seconds(5))
            self?.refresh()
        }
    }

    private func withRecorder(_ body: () throws -> Void) {
        do {
            try body()
            recorderError = nil
        } catch let error as DockError {
            recorderError = error
        } catch {
            recorderError = .backgroundRecording(error.localizedDescription)
        }
        refresh()
    }

    /// Record right now (the app does this when it opens, the background job hourly).
    public func captureNow() {
        _ = try? runCapture(store: Store(root: services.dataDir), mac: services.mac, now: services.now())
        refresh()
    }

    // MARK: Time Machine

    /// Import the past. Without Full Disk Access it waits for the user to grant it, then continues by itself.
    public func importFromTimeMachine() async {
        guard !isImporting else { return }
        guard services.hasFullDiskAccess() else {
            importState = .needsFullDiskAccess
            watchForFullDiskAccess()
            return
        }
        permissionWatch?.cancel()
        importState = .running(fraction: 0)
        let services = services
        let result: Result<ImportResult, DockError> = await Task.detached { [weak self] in
            do {
                let backups = try services.listBackups()
                let r = try importBackups(backups, into: Store(root: services.dataDir), mac: services.mac) { done, total in
                    Task { @MainActor in
                        if case .running = self?.importState { self?.importState = .running(fraction: Double(done) / Double(max(1, total))) }
                    }
                }
                return .success(r)
            } catch let error as DockError {
                return .failure(error)
            } catch {
                return .failure(.storageUnavailable(services.dataDir.path))
            }
        }.value
        switch result {
        case .success(let r): importState = .finished(r)
        case .failure(let e): importState = .failed(e)
        }
        refresh()
    }

    private var isImporting: Bool { if case .running = importState { true } else { false } }

    /// Poll for Full Disk Access (macOS has no notification for it) and resume the import once granted.
    private func watchForFullDiskAccess() {
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.importState == .needsFullDiskAccess else { return }
                if self.services.hasFullDiskAccess() {
                    await self.importFromTimeMachine()
                    return
                }
            }
        }
    }

    public func dismissImport() {
        permissionWatch?.cancel()
        importState = .idle
    }

    // MARK: video

    /// Make the video: the real history when there is a story to tell, otherwise a clearly labelled preview.
    public func makeVideo(preview forcePreview: Bool = false) {
        guard !render.isRendering else { return }
        let preview = forcePreview || !hasStory
        let settings = settings
        let services = services
        render = .rendering(fraction: 0, step: preview ? "Inventing a past…" : "Getting ready…")
        // Detached: drawing frames must never run on the main thread.
        renderTask = Task.detached { [weak self] in
            let outcome: RenderState
            do {
                outcome = .finished(try await Self.renderJob(services: services, settings: settings, preview: preview) { fraction, step in
                    Task { @MainActor in
                        if case .rendering = self?.render { self?.render = .rendering(fraction: fraction, step: step) }
                    }
                })
            } catch is CancellationError {
                outcome = .idle
            } catch {
                outcome = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            await MainActor.run {
                guard let self, self.render.isRendering else { return }  // cancelled meanwhile
                self.render = outcome
                self.renderTask = nil
            }
        }
    }

    nonisolated static func renderJob(services: AppServices, settings: VideoSettings, preview: Bool,
                                      report: @escaping @Sendable (Double, String) -> Void) async throws -> Video {
        var data = services.dataDir
        var tmp: URL?
        defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
        if preview {
            let dir = FileManager.default.temporaryDirectory.appending(path: "dock-timelapse-preview-\(UUID().uuidString)")
            tmp = dir
            try buildPreview(at: dir, mac: services.mac, today: services.now().day)
            data = dir
        }
        var files: [String: URL] = [:]
        let formats = settings.formats
        for (k, format) in formats.enumerated() {
            try Task.checkCancellation()
            let out = services.outputDir.appending(path: "Dock \(format.name.capitalized)\(preview ? " Preview" : "").mp4")
            let step = formats.count > 1 ? "Making the \(format.name) video…" : "Making your video…"
            report(Double(k) / Double(formats.count), step)
            files[format.name] = try await services.render(data, format, out, settings.fps, settings.background) { done, total in
                report((Double(k) + Double(done) / Double(max(1, total))) / Double(formats.count), step)
                return !Task.isCancelled
            }
        }
        try Task.checkCancellation()
        return Video(files: files, isPreview: preview, background: settings.background)
    }

    public func cancelRender() {
        renderTask?.cancel()
        renderTask = nil
        render = .idle
    }

    public func dismissVideo() {
        if !render.isRendering { render = .idle }
    }
}
