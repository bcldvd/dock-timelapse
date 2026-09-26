import Foundation

public enum Paths {
    /// Where history lives. Same place as the Python engine used, so existing recordings carry over.
    public static var defaultData: URL {
        if let custom = ProcessInfo.processInfo.environment["DOCK_TIMELAPSE_DATA"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/dock-timelapse")
    }

    public static var defaultOutput: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Dock Timelapse")
    }
}
