import DockCore
import DockMac
import DockRender
import Foundation

/// The tools agents get: status, the Dock and its history, recording, Time Machine import, videos, frames.
public final class DockTools: @unchecked Sendable {
    public var data: URL
    public var out: URL
    let mac: MacSystem
    let recorder: () -> Recorder
    let listBackups: () throws -> [Backup]
    let render: (URL, VideoFormat, URL, Int, Background) async throws -> URL

    public init(data: URL = Paths.defaultData, out: URL = Paths.defaultOutput, mac: MacSystem = RealMac(),
                recorder: @escaping () -> Recorder = { currentRecorder() },
                listBackups: @escaping () throws -> [Backup] = { try TimeMachine.listBackups() },
                render: @escaping (URL, VideoFormat, URL, Int, Background) async throws -> URL = { d, f, o, fps, bg in
                    try await renderVideo(dataRoot: d, format: f, to: o, fps: fps, background: bg)
                }) {
        self.data = data
        self.out = out
        self.mac = mac
        self.recorder = recorder
        self.listBackups = listBackups
        self.render = render
    }

    static let instructions = """
    dock-timelapse records how the user's macOS Dock evolves (one snapshot per day it changes) and renders \
    Apple-style timelapse videos (landscape 1920x1080 and portrait 1080x1920).
    Typical flow: dock_status → install_recording (once) → import_time_machine (real past, if the user has backups) \
    → render_timelapse. Without backups, render_preview shows what the video will look like with an invented past.
    Rendering takes a few seconds per format. Output files are MP4 paths on the user's Mac: tell the user where they \
    are (open one with `open <path>`). render_frame returns a single PNG you can look at directly.
    """

    static var format: [String: Any] { ["type": "string", "enum": ["landscape", "portrait", "both"], "default": "both"] }
    static var background: [String: Any] { ["type": "string", "enum": ["wallpaper", "desktop", "white"], "default": "wallpaper",
                                            "description": "wallpaper = blurred desktop picture, desktop = sharp, white = clean white"] }
    static var fps: [String: Any] { ["type": "integer", "minimum": 1, "maximum": 120, "default": 30] }
    static var outDir: [String: Any] { ["type": "string", "description": "Output folder (default ~/Movies/Dock Timelapse)"] }

    static func tool(_ name: String, _ title: String, _ description: String, _ properties: [String: Any] = [:],
                     readOnly: Bool = false) -> [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false],
         "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
    }

    static var definitions: [[String: Any]] { [
        tool("dock_status", "Dock status", "Is recording on, how many snapshots exist, can we render yet.", readOnly: true),
        tool("current_dock", "Current Dock", "The apps pinned in the Dock right now, in order (everything after System Settings is ignored).", readOnly: true),
        tool("dock_history", "Dock history", "Every recorded snapshot: date, day number, apps, what changed (added/removed/replaced/moved) and whether it came from Time Machine.", readOnly: true),
        tool("install_recording", "Start recording", "Turn on hourly background recording of the Dock."),
        tool("uninstall_recording", "Stop recording", "Turn off background recording. Recorded history is kept."),
        tool("capture_now", "Capture now", "Record the Dock right now if it changed (normally done hourly)."),
        tool("import_time_machine", "Import from Time Machine",
             "Import the user's past Docks from Time Machine backups (one snapshot per day the Dock changed), so render_timelapse shows real history right away. The backup disk must be connected and the app running this server needs Full Disk Access.",
             ["backups_dir": ["type": "string", "description": "Optional backups folder to read directly"]]),
        tool("render_timelapse", "Render timelapse", "Render MP4 timelapses of the recorded history. Returns the file paths.",
             ["format": format, "background": background, "fps": fps, "out_dir": outDir]),
        tool("render_preview", "Render preview", "Render a demo timelapse from an invented past that ends with today's real Dock. Tell the user the history in it is invented. Returns the file paths.",
             ["format": format, "background": background, "fps": fps, "out_dir": outDir]),
        tool("render_frame", "Render frame", "Render one frame (PNG) at t seconds to see the look before a full render. preview=true uses an invented past.",
             ["t": ["type": "number", "minimum": 0, "default": 3], "format": ["type": "string", "enum": ["landscape", "portrait"], "default": "landscape"],
              "background": background, "preview": ["type": "boolean", "default": false]]),
    ] }

    // MARK: calls

    /// Run a tool; failures come back as `isError` results with a message the agent can relay.
    public func call(_ name: String, _ args: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "render_frame":
                let png = try frame(args)
                return ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]]
            default:
                let value = try await structured(name, args)
                // Always an object at the top: NSJSONSerialization raises an uncatchable exception otherwise.
                let object = value as? [String: Any] ?? ["result": value]
                guard JSONSerialization.isValidJSONObject(object),
                      let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys])
                else { throw ToolError("Internal error: the result couldn't be encoded.") }
                return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": object]
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return ["content": [["type": "text", "text": message]], "isError": true]
        }
    }

    func store() throws -> Store { try Store(root: data) }

    func structured(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "dock_status":
            let snaps = try store().snapshots()
            return ["recording": recorder().state == .on, "recording_state": "\(recorder().state)", "data_dir": data.path,
                    "snapshots": snaps.count, "imported_from_time_machine": snaps.filter(\.isImported).count,
                    "first": snaps.first?.date ?? NSNull(), "last_change": snaps.last?.date ?? NSNull(),
                    "can_render": !snaps.isEmpty] as [String: Any]
        case "current_dock":
            return try mac.currentDock().enumerated().map { k, a in
                ["position": k + 1, "name": a.label, "bundle_id": a.bundleID ?? NSNull(), "path": a.path] as [String: Any]
            }
        case "dock_history":
            let snaps = try store().snapshots()
            let first = snaps.first?.day
            return snaps.enumerated().map { k, s in
                ["date": s.date, "day": first.map { s.day.days(since: $0) + 1 } ?? 1, "app_count": s.apps.count,
                 "apps": s.apps.map(\.label), "source": s.source ?? "recorded",
                 "changes": k == 0 ? ["(first snapshot)"] : s.changes.map(\.describe)] as [String: Any]
            }
        case "install_recording":
            let r = recorder()
            try r.start()
            _ = try? runCapture(store: store(), mac: mac)
            return ["installed": r.state != .off, "state": "\(r.state)",
                    "note": r.state == .needsApproval
                        ? "Ask the user to allow Dock Timelapse in System Settings → General → Login Items."
                        : "Runs hourly; records a snapshot on each day the Dock changes."] as [String: Any]
        case "uninstall_recording":
            try recorder().stop()
            return ["stopped": true, "data_kept_in": data.path]
        case "capture_now":
            return try runCapture(store: store(), mac: mac).rawValue
        case "import_time_machine":
            let backups = try (args["backups_dir"] as? String).map {
                try DockCore.backups(in: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath))
            } ?? listBackups()
            let r = try importBackups(backups, into: store(), mac: mac)
            return ["backups": r.backups, "backups_with_dock": r.read, "snapshots_added": r.added,
                    "first": r.first ?? NSNull(), "last": r.last ?? NSNull(), "total_snapshots": try store().snapshots().count,
                    "note": "Past wallpapers can't be recovered, so imported days use today's wallpaper."] as [String: Any]
        case "render_timelapse":
            guard try !store().snapshots().isEmpty else {
                throw ToolError("No history recorded yet. Start it with install_recording, import the past with import_time_machine, or call render_preview to show a demo with an invented past.")
            }
            return try await renderAll(data, args, suffix: "")
        case "render_preview":
            let tmp = FileManager.default.temporaryDirectory.appending(path: "dock-timelapse-preview-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try buildPreview(at: tmp, mac: mac)
            return try await renderAll(tmp, args, suffix: "-preview")
        default:
            throw ToolError("Unknown tool: \(name)")
        }
    }

    func options(_ args: [String: Any]) throws -> ([VideoFormat], Background, Int, URL) {
        let fmt = args["format"] as? String ?? "both"
        guard fmt == "both" || VideoFormat.named(fmt) != nil else { throw ToolError("format must be landscape, portrait or both") }
        guard let bg = Background(rawValue: args["background"] as? String ?? "wallpaper") else {
            throw ToolError("background must be wallpaper, desktop or white")
        }
        let fps = (args["fps"] as? NSNumber)?.intValue ?? 30
        guard fps > 0 else { throw ToolError("fps must be a positive number, e.g. 30") }
        let outDir = (args["out_dir"] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? out
        return (fmt == "both" ? VideoFormat.all : [VideoFormat.named(fmt)!], bg, fps, outDir)
    }

    func renderAll(_ source: URL, _ args: [String: Any], suffix: String) async throws -> [String] {
        let (formats, bg, fps, outDir) = try options(args)
        var paths: [String] = []
        for f in formats {
            paths.append(try await render(source, f, outDir.appending(path: "dock-\(f.name)-\(bg.rawValue)\(suffix).mp4"), fps, bg).path)
        }
        return paths
    }

    func frame(_ args: [String: Any]) throws -> Data {
        let fmt = VideoFormat.named(args["format"] as? String ?? "landscape") ?? .landscape
        let bg = Background(rawValue: args["background"] as? String ?? "wallpaper") ?? .wallpaper
        let t = max(0, (args["t"] as? NSNumber)?.doubleValue ?? 3)
        var source = data
        var tmp: URL?
        defer { if let tmp { try? FileManager.default.removeItem(at: tmp) } }
        if args["preview"] as? Bool == true {
            let dir = FileManager.default.temporaryDirectory.appending(path: "dock-timelapse-frame-\(UUID().uuidString)")
            try buildPreview(at: dir, mac: mac)
            (source, tmp) = (dir, dir)
        } else if try store().snapshots().isEmpty {
            throw ToolError("No history recorded yet. Use preview=true for a demo frame.")
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "dock-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try renderStill(dataRoot: source, format: fmt, at: t, to: file, background: bg)
        return try Data(contentsOf: file)
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
