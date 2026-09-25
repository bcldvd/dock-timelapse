import datetime as dt

from dock_timelapse.dockdata import DockApp
from dock_timelapse.poc import invent_history


def apps(*labels):
    return [DockApp(l, f"id.{l}", f"/Applications/{l}.app") for l in labels]


CURRENT = apps("Finder", "Arc", "Slack", "Linear", "Cursor", "Figma", "Spotify", "Notion", "Zoom", "Settings")


def test_invented_history_ends_with_the_real_dock():
    hist = invent_history(CURRENT, n=7, seed=1)
    assert len(hist) == 7
    assert hist[-1][1] == CURRENT
    assert hist[-1][0] == 0
    days = [d for d, _ in hist]
    assert days == sorted(days, reverse=True) and days[0] > 200


def test_each_step_changes_something_and_is_deterministic():
    a = invent_history(CURRENT, n=7, seed=1)
    assert all(x[1] != y[1] for x, y in zip(a, a[1:]))
    assert a == invent_history(CURRENT, n=7, seed=1)


def test_history_uses_classic_apps_for_the_past_and_keeps_edges():
    hist = invent_history(CURRENT, n=7, seed=3, classics=apps("Safari", "Mail", "Terminal", "Music"))
    first = hist[0][1]
    assert first[0].label == "Finder" and first[-1].label == "Settings"
    assert any(a.label in {"Safari", "Mail", "Terminal", "Music"} for a in first)


def test_tiny_dock_still_works():
    hist = invent_history(apps("Finder", "Settings"), n=4, seed=0, classics=apps("Safari", "Mail"))
    assert len(hist) == 4 and hist[-1][1] == apps("Finder", "Settings")


def test_demo_mac_serves_a_generic_dock_ending_in_settings():
    from dock_timelapse.dockdata import parse_dock_prefs
    from dock_timelapse.poc import DEMO_DOCK, DemoMac

    class Base:
        def icon_png(self, app):
            return b"png"

        def wallpaper(self):
            return None

    apps = parse_dock_prefs(DemoMac(Base()).dock_prefs())
    assert apps == DEMO_DOCK
    assert apps[-1].bundle_id == "com.apple.systempreferences"
    assert DemoMac(Base()).icon_png(apps[0]) == b"png"
