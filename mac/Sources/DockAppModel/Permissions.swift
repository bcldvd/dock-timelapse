import DockCore
import DockMac
import Foundation

/// What Dock Timelapse asks macOS for.
public enum Permission: String, CaseIterable, Sendable {
    /// The hourly background job (Login Items). Required: without it there is no story to tell.
    case backgroundRecording
    /// Reading Time Machine backups. Optional: only to bring back the past.
    case fullDiskAccess
}

public enum PermissionStatus: Equatable, Sendable {
    case granted
    /// Not asked yet, or turned off.
    case notYet
    /// Asked; macOS wants the user to flip a switch in System Settings.
    case waitingForApproval
}

public struct PermissionRow: Equatable, Sendable {
    public let permission: Permission
    public let status: PermissionStatus
    public let required: Bool

    public init(permission: Permission, status: PermissionStatus, required: Bool) {
        (self.permission, self.status, self.required) = (permission, status, required)
    }
}

extension AppModel {
    public var permissions: [PermissionRow] {
        let recording: PermissionStatus = switch recorder {
        case .on: .granted
        case .needsApproval: .waitingForApproval
        case .off: .notYet
        }
        return [
            PermissionRow(permission: .backgroundRecording, status: recording, required: true),
            PermissionRow(permission: .fullDiskAccess, status: fullDiskAccess ? .granted : .notYet, required: false),
        ]
    }

    public var requiredPermissionsGranted: Bool { permissions.allSatisfy { !$0.required || $0.status == .granted } }

    /// Do whatever gets this permission granted: start the job, or open the right pane of System Settings.
    public func requestPermission(_ permission: Permission) {
        switch (permission, permissions.first { $0.permission == permission }?.status) {
        case (_, .granted?): return
        case (.backgroundRecording, .notYet?): startRecording()
        default: services.openSettings(permission)
        }
    }

    /// Keep the permissions current while a permission screen is visible (macOS sends no notification when
    /// a switch is flipped in System Settings). Returns once everything is granted, or when cancelled.
    public func watchPermissions(every interval: Duration = .seconds(1)) async {
        while !Task.isCancelled && !permissions.allSatisfy({ $0.status == .granted }) {
            try? await Task.sleep(for: interval)
            refresh()
        }
    }
}
