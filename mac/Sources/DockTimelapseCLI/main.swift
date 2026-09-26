import ArgumentParser
import DockCore
import DockMCP
import DockMac
import DockRender
import Foundation

struct Options: ParsableArguments {
    @Option(help: "Data folder.")
    var data: String = Paths.defaultData.path

    var dataURL: URL { URL(fileURLWithPath: (data as NSString).expandingTildeInPath) }
}

extension Background: ExpressibleByArgument {}

enum FormatChoice: String, ExpressibleByArgument, CaseIterable {
    case landscape, portrait, both
    var formats: [VideoFormat] { self == .both ? VideoFormat.all : [VideoFormat.named(rawValue)!] }
}

struct RenderOptions: ParsableArguments {
    @Option(help: "landscape, portrait or both.") var format: FormatChoice = .both
    @Option(help: "wallpaper (blurred), desktop (sharp) or white.") var background: Background = .wallpaper
    @Option(help: "Output folder.") var out: String = Paths.defaultOutput.path
    @Option(help: "Frames per second.") var fps: Int = 60

    var outURL: URL { URL(fileURLWithPath: (out as NSString).expandingTildeInPath) }

    func validate() throws {
        if fps <= 0 { throw ValidationError("fps must be a positive number, e.g. 30 or 60") }
    }
}

/// Print the error the way a person can act on it, and exit non-zero.
func fail(_ error: Error) -> Never {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    FileHandle.standardError.write(Data("dock-timelapse: \(message)\n".utf8))
    exit(1)
}

func requireHistory(_ data: URL) throws {
    if try Store(root: data).snapshots().isEmpty {
        throw ValidationError("No history yet. Start recording with `dock-timelapse install`, import your past from "
            + "Time Machine with `dock-timelapse import`, or try `dock-timelapse preview` to see an invented past.")
    }
}

func render(data: URL, options: RenderOptions, suffix: String = "") async throws {
    for fmt in options.format.formats {
        let out = options.outURL.appending(path: "dock-\(fmt.name)-\(options.background.rawValue)\(suffix).mp4")
        let started = Date()
        try await renderVideo(dataRoot: data, format: fmt, to: out, fps: options.fps, background: options.background) { done, total in
            if done % options.fps == 0 || done == total {
                FileHandle.standardError.write(Data("\r\(fmt.name): \(done)/\(total) frames".utf8))
            }
            return true
        }
        FileHandle.standardError.write(Data(String(format: " → %@ (%.1fs)\n", out.path, Date().timeIntervalSince(started)).utf8))
    }
}

@main
struct DockTimelapse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dock-timelapse",
        abstract: "Record your macOS Dock over time and render timelapse videos of it.",
        version: "0.3.0",
        subcommands: [Install.self, Uninstall.self, Capture.self, Import.self, Status.self, Preview.self,
                      Render.self, Still.self, MCP.self]
    )
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start recording: an hourly background job.")
    @OptionGroup var options: Options

    func run() throws {
        let recorder = currentRecorder(data: options.dataURL)
        do { try recorder.start() } catch { fail(error) }
        _ = try? runCapture(store: Store(root: options.dataURL), mac: RealMac())
        switch recorder.state {
        case .needsApproval:
            print("Almost there: allow Dock Timelapse in System Settings → General → Login Items.")
        default:
            print("Recording started. Runs hourly; one snapshot per day the Dock changes.\n  data: \(options.data)")
        }
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop recording (keeps your data).")
    @OptionGroup var options: Options

    func run() throws {
        do { try currentRecorder(data: options.dataURL).stop() } catch { fail(error) }
        print("Recording stopped. Your history is kept in \(options.data)")
    }
}

struct Capture: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record the Dock now if it changed (what the background job runs).")
    @OptionGroup var options: Options

    /// Exits 1 on failure (launchd just logs it and runs again next hour); the app reads capture.log.
    func run() throws {
        let line: String
        var failed = false
        do {
            let result = try runCapture(store: Store(root: options.dataURL), mac: RealMac())
            line = "\(LocalTime.now().iso) \(result.rawValue)"
        } catch {
            line = "\(LocalTime.now().iso) error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            failed = true
        }
        print(line)
        CaptureLog.append(line, to: options.dataURL)
        if failed { throw ExitCode.failure }
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import your past Docks from Time Machine backups.")
    @OptionGroup var options: Options
    @Option(help: "A backups folder to read instead of asking Time Machine (e.g. /Volumes/<disk>/Backups.backupdb/<Mac>).")
    var backups: String?

    func run() throws {
        do {
            let list = try backups.map { try DockCore.backups(in: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
                ?? TimeMachine.listBackups()
            print("Reading the Dock from \(list.count) Time Machine backups…")
            let r = try importBackups(list, into: Store(root: options.dataURL), mac: RealMac())
            print("Imported \(r.added) snapshots (\(r.first ?? "?") → \(r.last ?? "?")) from \(r.read) backups. "
                + "See them with `dock-timelapse status`, then `dock-timelapse render`.")
        } catch { fail(error) }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recording state and every snapshot.")
    @OptionGroup var options: Options

    func run() throws {
        let state = currentRecorder(data: options.dataURL).state
        print("recording: " + (state == .on ? "on" : state == .needsApproval
            ? "waiting for approval in System Settings → Login Items" : "off (start it with: dock-timelapse install)"))
        if state == .on {
            switch recorderHealth(dataDir: options.dataURL, now: .now()) {
            case .healthy: break
            case .stale(let last):
                print("warning: nothing recorded since \(last?.iso ?? "it was installed"); try `dock-timelapse install` again")
            case .failing(let why): print("warning: the last capture failed: \(why)")
            }
        }
        print("data:  \(options.data)")
        let snaps: [Snapshot]
        do { snaps = try Store(root: options.dataURL).snapshots() } catch { fail(error) }
        for (k, s) in snaps.enumerated() {
            let changes = k == 0 ? "first snapshot" : s.changes.map(\.describe).joined(separator: ", ")
            let count = String(format: "%2d", s.apps.count)
            print("\(s.date)  \(count) apps  \(changes)\(s.isImported ? "  (Time Machine)" : "")")
        }
    }
}

/// Serves a fixed Dock or wallpaper over the real Mac (for `preview --demo` and `--wallpaper`).
struct PreviewMac: MacSystem {
    let base = RealMac()
    var dock: [DockApp]?
    var wallpaperFile: URL?

    func currentDock() throws -> [DockApp] { try dock ?? base.currentDock() }
    func iconPNG(for app: DockApp) -> Data? { base.iconPNG(for: app) }
    func wallpaper() -> Wallpaper? {
        guard let file = wallpaperFile, let data = try? Data(contentsOf: file) else { return base.wallpaper() }
        return Wallpaper(stem: file.deletingPathExtension().lastPathComponent, suffix: "." + file.pathExtension.lowercased(), data: data)
    }
}

let demoDock: [DockApp] = [
    ("Safari", "com.apple.Safari", "/Applications/Safari.app"),
    ("Messages", "com.apple.MobileSMS", "/System/Applications/Messages.app"),
    ("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
    ("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
    ("Notes", "com.apple.Notes", "/System/Applications/Notes.app"),
    ("Keynote", "com.apple.iWork.Keynote", "/Applications/Keynote.app"),
    ("Music", "com.apple.Music", "/System/Applications/Music.app"),
    ("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
    ("App Store", "com.apple.AppStore", "/System/Applications/App Store.app"),
    ("System Settings", "com.apple.systempreferences", "/System/Applications/System Settings.app"),
].map { DockApp(label: $0.0, bundleID: $0.1, path: $0.2) }

struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Invent a past from today's Dock and render it (see the video on day one).")
    @OptionGroup var render: RenderOptions
    @Option(help: "Seed for the invented past.") var seed: UInt64 = 7
    @Option(help: "Use this image instead of the current wallpaper.") var wallpaper: String?
    @Flag(help: "Use a generic demo Dock instead of yours.") var demo = false

    func run() async throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "dock-timelapse-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mac = PreviewMac(dock: demo ? demoDock : nil,
                             wallpaperFile: wallpaper.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
        do {
            try buildPreview(at: tmp, mac: mac, seed: seed)
            try await DockTimelapseCLI.render(data: tmp, options: render, suffix: "-preview")
        } catch { fail(error) }
    }
}

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render the timelapse videos from your recorded history.")
    @OptionGroup var options: Options
    @OptionGroup var render: RenderOptions

    func run() async throws {
        try requireHistory(options.dataURL)
        do { try await DockTimelapseCLI.render(data: options.dataURL, options: render) } catch { fail(error) }
    }
}

struct Still: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render single PNG frames.")
    @OptionGroup var options: Options
    @Option(help: "landscape, portrait or both.") var format: FormatChoice = .both
    @Option(help: "wallpaper, desktop or white.") var background: Background = .wallpaper
    @Option(help: "Output folder.") var out: String = Paths.defaultOutput.path
    @Option(parsing: .upToNextOption, help: "Times in seconds.") var t: [Double] = [3.0]

    func validate() throws {
        if t.contains(where: { $0 < 0 }) { throw ValidationError("times start at 0 (seconds from the start of the video)") }
    }

    func run() throws {
        try requireHistory(options.dataURL)
        let outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        for fmt in format.formats {
            for time in t {
                let file = outURL.appending(path: String(format: "still-%@-%@-%05.1f.png", fmt.name, background.rawValue, time))
                do { print(try renderStill(dataRoot: options.dataURL, format: fmt, at: time, to: file, background: background).path) }
                catch { fail(error) }
            }
        }
    }
}

struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Run the MCP server (stdio) for AI agents.")
    @OptionGroup var options: Options

    func run() async throws {
        await MCPServer(tools: DockTools(data: options.dataURL)).run()
    }
}
