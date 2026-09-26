import CryptoKit
import Foundation

/// Every failure a user can hit, with words they understand and a way out.
public enum DockError: Error, Equatable, Sendable, LocalizedError {
    case fullDiskAccessNeeded(path: String)
    case noTimeMachineBackups(detail: String?)
    case backupsFolderMissing(String)
    case noBackupsInFolder(String)
    case noReadableDockInBackups(count: Int)
    case noHistory
    case dockUnreadable
    case corruptHistory(String)
    case storageUnavailable(String)
    case renderFailed(String)
    case backgroundRecording(String)

    /// What the user can do about it. The CLI prints a hint; the app shows a button.
    public enum Recovery: Sendable, Equatable {
        case openFullDiskAccessSettings
        case connectBackupDisk
        case startRecording
        case openLoginItemsSettings
    }

    public var recovery: Recovery? {
        switch self {
        case .fullDiskAccessNeeded, .noReadableDockInBackups: .openFullDiskAccessSettings
        case .noTimeMachineBackups: .connectBackupDisk
        case .noHistory: .startRecording
        case .backgroundRecording: .openLoginItemsSettings
        default: nil
        }
    }

    public static let fullDiskAccessHint = "Give Dock Timelapse Full Disk Access in System Settings → "
        + "Privacy & Security → Full Disk Access (from Terminal, give it to your terminal app)."

    public var errorDescription: String? {
        switch self {
        case .fullDiskAccessNeeded(let path):
            "Dock Timelapse isn't allowed to read \(path). \(Self.fullDiskAccessHint)"
        case .noTimeMachineBackups(let detail):
            "No Time Machine backups found" + (detail.map { " (\($0))" } ?? "")
                + ". Connect your backup disk and try again."
        case .backupsFolderMissing(let path):
            "\(path) doesn't exist."
        case .noBackupsInFolder(let path):
            "No Time Machine backups in \(path) (expected folders named like 2026-01-31-093000)."
        case .noReadableDockInBackups(let count):
            "None of the \(count) backups had readable Dock settings. This usually means missing permission. "
                + Self.fullDiskAccessHint
        case .noHistory:
            "No history yet. Start recording, import your past from Time Machine, or watch a preview."
        case .dockUnreadable:
            "Couldn't read the Dock's settings."
        case .corruptHistory(let path):
            "The history file \(path) is damaged. It has been left untouched."
        case .storageUnavailable(let path):
            "Couldn't write to \(path). Check that the disk has free space."
        case .renderFailed(let why):
            "The video couldn't be made: \(why)"
        case .backgroundRecording(let why):
            "Background recording couldn't be turned on: \(why)"
        }
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
