import Foundation
@testable import DockCore

func apps(_ ids: String...) -> [DockApp] { apps(ids) }
func apps(_ ids: [String]) -> [DockApp] {
    ids.map { DockApp(label: $0.uppercased(), bundleID: $0, path: "/Applications/\($0.uppercased()).app") }
}

func chars(_ s: String) -> [DockApp] { apps(s.map(String.init)) }

let fixturesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Fixtures")

func fixture(_ name: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: fixturesDir.appending(path: "\(name).json")))
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "dock-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // /var → /private/var, as directory listings report it (resolvingSymlinksInPath does the opposite).
    return URL(fileURLWithPath: String(cString: realpath(url.path, nil)!))
}

func decodeChange(_ d: [String: Any]) -> Change {
    func app(_ a: Any?) -> DockApp? {
        guard let a = a as? [String: Any] else { return nil }
        return DockApp(label: a["label"] as! String, bundleID: a["bundle_id"] as? String, path: a["path"] as! String)
    }
    return Change(Change.Kind(rawValue: d["kind"] as! String)!, app(d["app"])!, old: app(d["old"]))
}

func decodeSnapshots(_ list: Any) throws -> [Snapshot] {
    try JSONDecoder().decode([Snapshot].self, from: JSONSerialization.data(withJSONObject: list))
}

func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }
