from dock_timelapse.dockdata import DockApp, parse_dock_prefs


def tile(label, bundle, path=None, kind="file-tile"):
    return {
        "tile-type": kind,
        "tile-data": {
            "file-label": label,
            "bundle-identifier": bundle,
            "file-data": {"_CFURLString": path or f"file:///Applications/{label}.app/"},
        },
    }


def test_parses_apps_in_order():
    prefs = {"persistent-apps": [tile("Arc", "company.thebrowser.Browser"), tile("Slack", "com.tinyspeck.slackmacgap")]}
    apps = parse_dock_prefs(prefs)
    assert [a.bundle_id for a in apps] == ["company.thebrowser.Browser", "com.tinyspeck.slackmacgap"]
    assert apps[0] == DockApp(label="Arc", bundle_id="company.thebrowser.Browser", path="/Applications/Arc.app")


def test_stops_after_settings_app_inclusive():
    prefs = {"persistent-apps": [
        tile("Arc", "a"),
        tile("Réglages Système", "com.apple.systempreferences", "file:///System/Applications/System%20Settings.app/"),
        tile("Junk", "junk"),
    ]}
    apps = parse_dock_prefs(prefs)
    assert [a.bundle_id for a in apps] == ["a", "com.apple.systempreferences"]
    assert apps[1].path == "/System/Applications/System Settings.app"


def test_skips_spacers_and_ignores_recents_and_others():
    prefs = {
        "persistent-apps": [tile("Arc", "a"), {"tile-type": "spacer-tile", "tile-data": {}}, tile("B", "b")],
        "recent-apps": [tile("R", "r")],
        "persistent-others": [tile("Downloads", None, kind="directory-tile")],
    }
    assert [a.bundle_id for a in parse_dock_prefs(prefs)] == ["a", "b"]


def test_missing_bundle_id_falls_back_to_path():
    prefs = {"persistent-apps": [tile("Thing", None, "file:///Applications/Thing.app/")]}
    assert parse_dock_prefs(prefs)[0].key == "/Applications/Thing.app"


def test_empty_prefs():
    assert parse_dock_prefs({}) == []
