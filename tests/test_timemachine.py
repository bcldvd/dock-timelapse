import datetime as dt
import plistlib
from pathlib import Path

import pytest

from dock_timelapse.store import Store
from dock_timelapse.timemachine import (Backup, TimeMachineError, backup_time, backups_in, find_dock_plist,
                                        import_backups)

HOME = Path("/Users/me")


def tile(label):
    return {"tile-type": "file-tile", "tile-data": {"file-label": label, "bundle-identifier": label.lower(),
            "file-data": {"_CFURLString": f"file:///Applications/{label}.app/"}}}


class FakeMac:
    """Only apps that still exist on this Mac have an icon; the rest must come from the backup."""

    def __init__(self, installed=("Arc", "Slack", "Cursor", "Linear")):
        self.installed = set(installed)
        self.asked: list[str] = []

    def icon_png(self, app):
        self.asked.append(app.path)
        if app.path.startswith("/Applications/"):
            ok = Path(app.path).stem in self.installed
        else:  # a path inside a backup
            ok = Path(app.path).exists()
        return f"png-{app.label}".encode() if ok else None

    def wallpaper(self):
        return Path("Grass.jpg"), b"jpg"


def make_backup(folder: Path, name: str, labels, volume="Macintosh HD - Data", nested=True) -> Path:
    root = folder / name / name if nested else folder / name  # APFS backups nest; HFS ones don't
    prefs = root / volume / "Users/me/Library/Preferences/com.apple.dock.plist"
    prefs.parent.mkdir(parents=True)
    prefs.write_bytes(plistlib.dumps({"persistent-apps": [tile(l) for l in labels]}))
    return folder / name


def test_backup_time_parses_time_machine_names():
    assert backup_time("2026-01-10-093015.backup") == dt.datetime(2026, 1, 10, 9, 30, 15)
    assert backup_time("2026-01-10-093015") == dt.datetime(2026, 1, 10, 9, 30, 15)
    assert backup_time("Latest") is None


def test_backups_in_lists_dated_backups_oldest_first(tmp_path):
    make_backup(tmp_path, "2026-02-01-100000.backup", ["Arc"])
    make_backup(tmp_path, "2026-01-01-100000.backup", ["Arc"])
    (tmp_path / "Latest").mkdir()
    assert [b.when.month for b in backups_in(tmp_path)] == [1, 2]


def test_find_dock_plist_in_both_backup_layouts(tmp_path):
    apfs = make_backup(tmp_path, "2026-01-01-100000.backup", ["Arc"])
    hfs = make_backup(tmp_path, "2025-01-01-100000", ["Arc"], volume="Macintosh HD", nested=False)
    for root in (apfs, hfs):
        assert find_dock_plist(Backup(dt.datetime.now(), root), HOME).name == "com.apple.dock.plist"
    assert find_dock_plist(Backup(dt.datetime.now(), tmp_path / "nope"), HOME) is None


def test_import_keeps_one_snapshot_per_day_of_change(tmp_path):
    tm, data = tmp_path / "tm", tmp_path / "data"
    make_backup(tm, "2025-06-01-090000.backup", ["Arc", "Xcode"])
    make_backup(tm, "2025-06-01-180000.backup", ["Arc", "Xcode", "Slack"])  # same day: last one wins
    make_backup(tm, "2025-07-01-090000.backup", ["Arc", "Xcode", "Slack"])  # unchanged: skipped
    make_backup(tm, "2025-08-01-090000.backup", ["Arc", "Cursor", "Slack"])
    store = Store(data)
    r = import_backups(store, FakeMac(), backups_in(tm), home=HOME)
    snaps = store.snapshots()
    assert (r.backups, r.read, r.added, r.first, r.last) == (4, 4, 2, "2025-06-01", "2025-08-01")
    assert [s.date for s in snaps] == ["2025-06-01", "2025-08-01"]
    assert [c.describe() for c in snaps[1].changes] == ["Xcode → Cursor"]
    assert all(s.source == "time-machine" and s.wallpaper for s in snaps)


def test_import_takes_deleted_apps_icon_from_the_backup(tmp_path):
    tm, data = tmp_path / "tm", tmp_path / "data"
    root = make_backup(tm, "2025-06-01-090000.backup", ["Arc", "Xcode"])
    app = root / root.name / "Macintosh HD - Data/Applications/Xcode.app"
    app.mkdir(parents=True)
    mac = FakeMac()
    store = Store(data)
    import_backups(store, mac, backups_in(tm), home=HOME)
    snap = store.snapshots()[0]
    assert str(app) in mac.asked
    assert (data / snap.icons["xcode"]).read_bytes() == b"png-Xcode"


def test_import_then_live_recording_continues_the_story(tmp_path):
    tm, data = tmp_path / "tm", tmp_path / "data"
    make_backup(tm, "2025-06-01-090000.backup", ["Arc", "Xcode"])
    store = Store(data)
    store.observe(parse(["Arc", "Cursor", "Linear"]), dt.datetime(2026, 1, 1, 9))
    import_backups(store, FakeMac(), backups_in(tm), home=HOME)
    snaps = store.snapshots()
    assert [s.source for s in snaps] == ["time-machine", None]
    assert [c.describe() for c in snaps[1].changes] == ["Xcode → Cursor", "+ Linear"]


def test_unreadable_backups_folder_explains_full_disk_access(tmp_path):
    locked = tmp_path / "locked"
    locked.mkdir(mode=0)
    try:
        with pytest.raises(TimeMachineError, match="Full Disk Access"):
            backups_in(locked)
    finally:
        locked.chmod(0o755)


def test_backups_without_a_readable_dock_point_to_full_disk_access(tmp_path):
    (tmp_path / "2026-01-01-100000.backup").mkdir()
    with pytest.raises(TimeMachineError, match="Full Disk Access"):
        import_backups(Store(tmp_path / "d"), FakeMac(), backups_in(tmp_path), home=HOME)


def parse(labels):
    from dock_timelapse.dockdata import parse_dock_prefs

    return parse_dock_prefs({"persistent-apps": [tile(l) for l in labels]})
