import Testing
@testable import DockCore

func tile(_ label: String, _ bundle: String?, _ path: String? = nil, kind: String = "file-tile") -> [String: Any] {
    var data: [String: Any] = ["file-label": label,
                               "file-data": ["_CFURLString": path ?? "file:///Applications/\(label).app/"]]
    if let bundle { data["bundle-identifier"] = bundle }
    return ["tile-type": kind, "tile-data": data]
}

@Test func parsesAppsInOrder() {
    let apps = parseDockPrefs(["persistent-apps": [tile("Arc", "company.thebrowser.Browser"),
                                                   tile("Slack", "com.tinyspeck.slackmacgap")]])
    #expect(apps.map(\.bundleID) == ["company.thebrowser.Browser", "com.tinyspeck.slackmacgap"])
    #expect(apps[0] == DockApp(label: "Arc", bundleID: "company.thebrowser.Browser", path: "/Applications/Arc.app"))
}

@Test func stopsAfterSettingsAppInclusive() {
    let apps = parseDockPrefs(["persistent-apps": [
        tile("Arc", "a"),
        tile("Réglages Système", "com.apple.systempreferences", "file:///System/Applications/System%20Settings.app/"),
        tile("Junk", "junk"),
    ]])
    #expect(apps.map(\.bundleID) == ["a", "com.apple.systempreferences"])
    #expect(apps[1].path == "/System/Applications/System Settings.app")
}

@Test func skipsSpacersAndIgnoresRecentsAndOthers() {
    let prefs: [String: Any] = [
        "persistent-apps": [tile("Arc", "a"), ["tile-type": "spacer-tile", "tile-data": [String: Any]()], tile("B", "b")],
        "recent-apps": [tile("R", "r")],
        "persistent-others": [tile("Downloads", nil, kind: "directory-tile")],
    ]
    #expect(parseDockPrefs(prefs).map(\.bundleID) == ["a", "b"])
}

@Test func missingBundleIDFallsBackToPath() {
    #expect(parseDockPrefs(["persistent-apps": [tile("Thing", nil, "file:///Applications/Thing.app/")]])[0].key
        == "/Applications/Thing.app")
}

@Test func emptyPrefs() {
    #expect(parseDockPrefs([:]).isEmpty)
}

@Test func urlToPathHandlesHostsAndOddInput() {
    #expect(urlToPath("file://localhost/Applications/A%20B.app/") == "/Applications/A B.app")
    #expect(urlToPath(nil) == "")
    #expect(urlToPath("file:///") == "/")
}
