import datetime as dt

import pytest

from dock_timelapse.dockdata import DockApp
from dock_timelapse.diff import diff_docks
from dock_timelapse.store import Snapshot
from dock_timelapse.timeline import Timeline, Timing, build_scenes


def apps(*ids):
    return [DockApp(label=i.upper(), bundle_id=i, path=f"/Applications/{i}.app") for i in ids]


def snaps(*states):
    out, prev = [], []
    for date, ids in states:
        a = apps(*ids)
        out.append(Snapshot(date=date, captured_at=date + "T10:00:00", apps=a, changes=diff_docks(prev, a)))
        prev = a
    return out


T = Timing(intro=1.0, transition=1.0, hold_base=1.0, hold_per_change=0.5, outro=2.0)
HISTORY = snaps(("2026-01-01", "abc"), ("2026-01-11", "abxc"), ("2026-02-10", "axc"))


def tl():
    return Timeline(build_scenes(HISTORY), T)


def pos(state):
    return {t.app.bundle_id: round(t.pos, 3) for t in state.tiles if t.slot > 0}


def test_scenes_have_day_numbers():
    assert [s.day for s in build_scenes(HISTORY)] == [1, 11, 41]


def test_duration():
    # intro build (scene 0 hold uses 0 labels) + 2 transitions + holds + outro
    assert tl().duration == pytest.approx(1.0 + 1.0 + (1.0 + 1.0 + 0.5) + (1.0 + 1.0 + 0.5) + 2.0)


def test_after_intro_first_dock_is_fully_built():
    s = tl().at(1.5)
    assert pos(s) == {"a": 0, "b": 1, "c": 2}
    assert s.length == pytest.approx(3)
    assert s.scene_index == 0


def test_mid_transition_added_app_opens_a_gap():
    t = tl()
    start = t.scene_starts[1]
    s = t.at(start + 0.6)
    x = next(tile for tile in s.tiles if tile.app.bundle_id == "x")
    assert 0 < x.slot < 1
    assert 3 < s.length < 4
    assert pos(s)["c"] == pytest.approx(3 - 1 + x.slot + 0, abs=1e-3) or pos(s)["c"] > 2


def test_after_transition_positions_match_new_dock():
    t = tl()
    assert pos(t.at(t.scene_starts[1] + 1.2)) == {"a": 0, "b": 1, "x": 2, "c": 3}
    assert pos(t.at(t.duration - 0.01)) == {"a": 0, "x": 1, "c": 2}


def test_removed_app_is_gone_after_transition():
    t = tl()
    s = t.at(t.scene_starts[2] + 1.2)
    assert all(tile.app.bundle_id != "b" for tile in s.tiles if tile.slot > 0)


def test_day_counter_counts_up_during_transition():
    t = tl()
    assert t.at(1.5).day == pytest.approx(1)
    mid = t.at(t.scene_starts[1] + 0.5).day
    assert 1 < mid < 11
    assert t.at(t.scene_starts[1] + 1.1).day == pytest.approx(11)


def test_labels_show_during_their_scene_only():
    t = tl()
    s1 = t.at(t.scene_starts[1] + 1.5)
    assert [(l.change.describe(), round(l.alpha, 2)) for l in s1.labels] == [("+ X", 1.0)]
    s2 = t.at(t.scene_starts[2] + 1.5)
    assert [l.change.describe() for l in s2.labels if l.alpha > 0.99] == ["− B"]


def test_first_scene_has_no_per_app_labels():
    assert tl().at(1.5).labels == []


def test_progress_follows_calendar_not_scene_count():
    t = tl()
    assert t.at(1.5).progress == pytest.approx(0)
    assert t.at(t.scene_starts[1] + 1.1).progress == pytest.approx(10 / 40)
    assert t.at(t.duration).progress == pytest.approx(1)


def test_outro_fades_in_at_the_end():
    t = tl()
    assert t.at(t.duration - 2.5).outro == 0
    assert t.at(t.duration).outro == pytest.approx(1)


def test_moved_app_shrinks_at_old_place_and_grows_at_new():
    t = Timeline(build_scenes(snaps(("2026-01-01", "abc"), ("2026-01-02", "bca"))), T)
    s = t.at(t.scene_starts[1] + 0.5)
    a_tiles = [tile for tile in s.tiles if tile.app.bundle_id == "a"]
    assert len(a_tiles) == 2


def test_summary_for_outro():
    from dock_timelapse.timeline import summarize

    s = summarize(build_scenes(snaps(("2026-01-01", "abc"), ("2026-01-11", "abxc"), ("2026-02-10", "axcy"))))
    assert s.days == 41
    assert s.n_changes == 3  # +x, -b, +y
    assert [a.bundle_id for a in s.arrived] == ["x", "y"]
    assert [a.bundle_id for a in s.left] == ["b"]
    assert [a.bundle_id for a in s.stayed] == ["a", "c"]
    assert s.final_count == 4


def test_removed_label_points_at_the_gap_it_left_during_hold():
    t = tl()  # scene 2 removes "b" which sat between a and x
    s = t.at(t.scene_starts[2] + 1.5)
    lab = next(l for l in s.labels if l.change.kind == "removed")
    assert lab.anchor == pytest.approx(1.0)  # boundary between a (0..1) and x (1..2)


def test_added_tiles_never_draw_bigger_than_their_slot_while_growing():
    t = tl()
    for k in range(1, 20):
        s = t.at(t.scene_starts[1] + k * 0.05)
        for tile in s.tiles:
            if 0 < tile.slot < 0.95:
                assert tile.scale <= tile.slot * 1.1 + 1e-9
    for k in range(1, 20):
        for tile in t.at(k * 0.05).tiles:
            if 0 < tile.slot < 0.95:
                assert tile.scale <= tile.slot * 1.1 + 1e-9
