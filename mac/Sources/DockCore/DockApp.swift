import Foundation

/// Everything after the Settings app is ignored (running apps, recent items).
public let settingsBundleIDs: Set<String> = ["com.apple.systempreferences", "com.apple.SystemSettings"]

/// One app pinned in the Dock.
public struct DockApp: Hashable, Sendable, Codable {
    public var label: String
    public var bundleID: String?
    public var path: String

    public init(label: String, bundleID: String?, path: String) {
        self.label = label
        self.bundleID = bundleID
        self.path = path
    }

    /// Identity across snapshots: the bundle id, or the path for apps without one.
    public var key: String { bundleID ?? path }

    enum CodingKeys: String, CodingKey {
        case label, bundleID = "bundle_id", path
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        path = try c.decode(String.self, forKey: .path)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(bundleID, forKey: .bundleID)  // explicit null, like the Python writer
        try c.encode(path, forKey: .path)
    }
}

/// `file:///Applications/Google%20Chrome.app/` → `/Applications/Google Chrome.app`
func urlToPath(_ url: String?) -> String {
    guard var s = url, !s.isEmpty else { return "" }
    if let range = s.range(of: "://") {
        s = String(s[range.upperBound...])
        if let slash = s.firstIndex(of: "/") { s = String(s[slash...]) } else { s = "" }
    }
    for marker in ["?", "#"] {
        if let cut = s.range(of: marker) { s = String(s[..<cut.lowerBound]) }
    }
    let path = s.removingPercentEncoding ?? s
    var trimmed = path
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    return trimmed.isEmpty ? path : trimmed
}

/// The Dock's pinned apps, in order, from its preferences (`com.apple.dock`), up to System Settings.
public func parseDockPrefs(_ prefs: [String: Any]) -> [DockApp] {
    var apps: [DockApp] = []
    for tile in prefs["persistent-apps"] as? [[String: Any]] ?? [] {
        guard tile["tile-type"] as? String == "file-tile" else { continue }
        let data = tile["tile-data"] as? [String: Any] ?? [:]
        let fileData = data["file-data"] as? [String: Any] ?? [:]
        let app = DockApp(
            label: data["file-label"] as? String ?? "",
            bundleID: data["bundle-identifier"] as? String,
            path: urlToPath(fileData["_CFURLString"] as? String)
        )
        apps.append(app)
        if let id = app.bundleID, settingsBundleIDs.contains(id) { break }
    }
    return apps
}
