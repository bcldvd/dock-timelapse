import Foundation

/// `capture.log` in the data dir: one line per background capture, "<local time> <saved|unchanged>" or
/// "<local time> error: <message>".
public enum CaptureLog {
    public static let name = "capture.log"

    public static func append(_ line: String, to dataDir: URL) {
        let url = dataDir.appending(path: name)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    /// The newest entry, reading only the end of the file (it grows by a line an hour, forever).
    public static func last(in dataDir: URL) -> (time: LocalTime, outcome: String)? {
        guard let handle = try? FileHandle(forReadingFrom: dataDir.appending(path: name)) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? handle.readToEnd(), let tail = String(data: data, encoding: .utf8),
              let line = tail.split(whereSeparator: \.isNewline).last else { return nil }
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let time = LocalTime(iso: String(parts[0])) else { return nil }
        return (time, String(parts[1]))
    }
}

/// Whether the background job is actually recording, beyond being registered.
public enum RecorderHealth: Equatable, Sendable {
    case healthy
    /// Nothing recorded for over a day; `last` is the most recent sign of life, if any.
    case stale(last: LocalTime?)
    /// The latest capture failed with this message.
    case failing(String)
}

/// The job runs hourly, so a day and change without a capture means it isn't running.
public func recorderHealth(dataDir: URL, now: LocalTime, maxAge: Int = 26 * 3600) -> RecorderHealth {
    if let (time, outcome) = CaptureLog.last(in: dataDir) {
        if outcome.hasPrefix("error:") {
            return .failing(outcome.dropFirst("error:".count).trimmingCharacters(in: .whitespaces))
        }
        return now.seconds - time.seconds > maxAge ? .stale(last: time) : .healthy
    }
    // No log yet: the job may not have had its first run. Fall back on the days the Dock was checked.
    guard let day = (try? Store(root: dataDir))?.lastChecked() else { return .healthy }
    return now.day.days(since: day) > 1 ? .stale(last: LocalTime(day)) : .healthy
}
