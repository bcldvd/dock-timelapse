import datetime as dt
from pathlib import Path

from dock_timelapse.capture import dock_crop_box, run_capture
from dock_timelapse.store import Store

NOW = dt.datetime(2026, 3, 1, 10, 0)


def tile(label):
    return {"tile-type": "file-tile", "tile-data": {"file-label": label, "bundle-identifier": label.lower(),
            "file-data": {"_CFURLString": f"file:///Applications/{label}.app/"}}}


class FakeMac:
    def __init__(self, labels=("Arc", "Slack"), visible=True, wallpaper_bytes=b"jpg"):
        self.prefs = {"persistent-apps": [tile(l) for l in labels], "orientation": "left"}
        self.visible = visible
        self.wallpaper_bytes = wallpaper_bytes
        self.screenshots = 0

    def dock_prefs(self):
        return self.prefs

    def visibility(self, prefs):
        return (True, "visible") if self.visible else (False, "fullscreen:Keynote")

    def icon_png(self, app):
        return f"png-{app.label}".encode()

    def wallpaper(self):
        return (Path("Fresh Grass.jpg"), self.wallpaper_bytes) if self.wallpaper_bytes else None

    def dock_screenshot(self, prefs, out: Path):
        self.screenshots += 1
        out.write_bytes(b"shot")
        return out


def test_first_run_saves_snapshot_icons_wallpaper_and_screenshot(tmp_path):
    mac = FakeMac()
    assert run_capture(Store(tmp_path), mac, NOW) == "saved"
    snap = Store(tmp_path).snapshots()[0]
    assert snap.screenshot == "shots/2026-03-01.png"
    assert (tmp_path / snap.icons["arc"]).read_bytes() == b"png-Arc"
    assert (tmp_path / snap.wallpaper).read_bytes() == b"jpg"


def test_second_run_same_day_is_noop(tmp_path):
    mac = FakeMac()
    run_capture(Store(tmp_path), mac, NOW)
    assert run_capture(Store(tmp_path), mac, NOW.replace(hour=11)) == "already-done"
    assert mac.screenshots == 1


def test_unchanged_next_day_takes_no_screenshot(tmp_path):
    mac = FakeMac()
    run_capture(Store(tmp_path), mac, NOW)
    assert run_capture(Store(tmp_path), mac, NOW + dt.timedelta(days=1)) == "unchanged"
    assert mac.screenshots == 1
    assert len(Store(tmp_path).snapshots()) == 1


def test_changed_but_hidden_keeps_data_and_retries_screenshot_later(tmp_path):
    mac = FakeMac()
    run_capture(Store(tmp_path), mac, NOW)
    mac.prefs["persistent-apps"].append(tile("Linear"))
    mac.visible = False
    day2 = NOW + dt.timedelta(days=1)
    assert run_capture(Store(tmp_path), mac, day2) == "pending:fullscreen:Keynote"
    assert Store(tmp_path).snapshots()[-1].screenshot is None
    mac.visible = True
    assert run_capture(Store(tmp_path), mac, day2.replace(hour=14)) == "saved"
    assert Store(tmp_path).snapshots()[-1].screenshot == "shots/2026-03-02.png"


def test_identical_icons_are_stored_once(tmp_path):
    mac = FakeMac()
    run_capture(Store(tmp_path), mac, NOW)
    mac.prefs["persistent-apps"].append(tile("Linear"))
    run_capture(Store(tmp_path), mac, NOW + dt.timedelta(days=1))
    assert len(list((tmp_path / "icons").iterdir())) == 3


def test_crop_box_left_dock():
    assert dock_crop_box("left", (3024, 1964), scale=2, tilesize=64) == (0, 0, 272, 1964)


def test_crop_box_bottom_and_right_dock():
    assert dock_crop_box("bottom", (3024, 1964), scale=2, tilesize=48) == (0, 1964 - 224, 3024, 1964)
    assert dock_crop_box("right", (3024, 1964), scale=2, tilesize=48) == (3024 - 224, 0, 3024, 1964)


def test_screenshots_disabled_marks_day_done_without_screenshot(tmp_path):
    mac = FakeMac()
    assert run_capture(Store(tmp_path), mac, NOW, screenshots=False) == "saved"
    assert mac.screenshots == 0
    assert run_capture(Store(tmp_path), mac, NOW.replace(hour=12), screenshots=False) == "already-done"


def test_screenshots_disabled_unchanged_next_day_reports_unchanged(tmp_path):
    mac = FakeMac()
    run_capture(Store(tmp_path), mac, NOW, screenshots=False)
    assert run_capture(Store(tmp_path), mac, NOW + dt.timedelta(days=1), screenshots=False) == "unchanged"
