import AppKit
import DockCore
import Foundation

/// Run a command and capture its output.
public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return CommandResult(status: -1, stdout: "", stderr: "\(error)") }
    // Read before waiting so a chatty command can't fill the pipe and deadlock.
    let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                         stderr: String(decoding: e, as: UTF8.self))
}

public enum TimeMachine {
    /// Backups of this Mac known to Time Machine (the backup disk must be connected).
    public static func listBackups(runner: (String, [String]) -> CommandResult = run) throws -> [Backup] {
        let r = runner("/usr/bin/tmutil", ["listbackups"])
        let out = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = r.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if r.status != 0 || paths.isEmpty {
            let lower = out.lowercased()
            if lower.contains("not permitted") || lower.contains("full disk access") {
                throw DockError.fullDiskAccessNeeded(path: "your Time Machine backups")
            }
            throw DockError.noTimeMachineBackups(detail: out.split(separator: "\n").last.map(String.init))
        }
        return backups(from: paths.map { URL(fileURLWithPath: $0) })
    }

    /// Is a Time Machine destination configured at all? (Cheap; doesn't need the disk connected.)
    public static func isConfigured(runner: (String, [String]) -> CommandResult = run) -> Bool {
        let r = runner("/usr/bin/tmutil", ["destinationinfo"])
        return r.status == 0 && !r.stdout.contains("No destinations configured")
    }
}

public enum Permissions {
    /// Full Disk Access can't be queried directly; reading a TCC-protected file is the standard probe.
    public static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for rel in ["Library/Application Support/com.apple.TCC/TCC.db", "Library/Safari/Bookmarks.plist",
                    "Library/Containers/com.apple.stocks"] {
            let path = home.appending(path: rel).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if rel.hasSuffix("stocks") {
                return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
            }
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return true
            }
            return false
        }
        return false
    }

    @MainActor public static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

/// Is the app running from somewhere it can't stay: a translocated copy, a mounted DMG, or Downloads?
public func runsFromTemporaryLocation(_ bundlePath: String, home: String) -> Bool {
    bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix("/Volumes/") || bundlePath.hasPrefix("\(home)/Downloads/")
}
