import datetime as dt

from dock_timelapse.dockdata import DockApp
from dock_timelapse.store import Store


def apps(*ids):
    return [DockApp(label=i, bundle_id=i, path=f"/Applications/{i}.app") for i in ids]


D1 = dt.datetime(2026, 1, 10, 9, 0)
D2 = dt.datetime(2026, 1, 11, 9, 0)


def test_first_observation_creates_snapshot(tmp_path):
    s = Store(tmp_path)
    snap = s.observe(apps("a", "b"), D1)
    assert snap is not None and snap.date == "2026-01-10"
    assert [c.kind for c in snap.changes] == ["added", "added"]
    assert Store(tmp_path).snapshots()[0].apps == apps("a", "b")  # persisted


def test_unchanged_dock_does_not_create_snapshot_but_marks_day_checked(tmp_path):
    s = Store(tmp_path)
    s.observe(apps("a"), D1)
    assert s.observe(apps("a"), D2) is None
    assert len(s.snapshots()) == 1
    assert s.checked_on(D2.date())


def test_change_creates_new_snapshot_with_diff(tmp_path):
    s = Store(tmp_path)
    s.observe(apps("a", "vscode"), D1)
    snap = s.observe(apps("a", "cursor"), D2)
    assert [c.describe() for c in snap.changes] == ["vscode → cursor"]
    assert len(s.snapshots()) == 2


def test_same_day_change_updates_todays_snapshot_instead_of_stacking(tmp_path):
    s = Store(tmp_path)
    s.observe(apps("a"), D1)
    s.observe(apps("a", "b"), D2)
    s.observe(apps("a", "b", "c"), D2.replace(hour=15))
    snaps = s.snapshots()
    assert len(snaps) == 2
    assert [c.describe() for c in snaps[-1].changes] == ["+ b", "+ c"]


def test_same_day_revert_drops_todays_snapshot(tmp_path):
    s = Store(tmp_path)
    s.observe(apps("a"), D1)
    s.observe(apps("a", "b"), D2)
    s.observe(apps("a"), D2.replace(hour=15))
    assert len(s.snapshots()) == 1


def test_pending_screenshot_and_attach(tmp_path):
    s = Store(tmp_path)
    s.observe(apps("a"), D1)
    assert s.pending_screenshot() is not None
    shot = tmp_path / "x.png"
    shot.write_bytes(b"png")
    s.attach_screenshot(shot)
    assert s.pending_screenshot() is None
    snap = s.snapshots()[-1]
    assert (tmp_path / snap.screenshot).read_bytes() == b"png"


def test_icons_and_wallpaper_are_recorded(tmp_path):
    s = Store(tmp_path)
    snap = s.observe(apps("a"), D1, icons={"a": "icons/a-123.png"}, wallpaper="wallpapers/w.jpg")
    assert snap.icons == {"a": "icons/a-123.png"}
    assert Store(tmp_path).snapshots()[0].wallpaper == "wallpapers/w.jpg"


def test_done_for_day_requires_check_and_no_pending_screenshot(tmp_path):
    s = Store(tmp_path)
    s.observe(apps("a"), D1)
    assert not s.done_for(D1.date())
    shot = tmp_path / "x.png"; shot.write_bytes(b"png")
    s.attach_screenshot(shot)
    assert s.done_for(D1.date())
    assert not s.done_for(D2.date())
