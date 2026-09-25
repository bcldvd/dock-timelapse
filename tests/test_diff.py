from dock_timelapse.dockdata import DockApp
from dock_timelapse.diff import Change, diff_docks


def apps(*ids):
    return [DockApp(label=i.upper(), bundle_id=i, path=f"/Applications/{i}.app") for i in ids]


def kinds(changes):
    return [(c.kind, c.app.bundle_id, c.old.bundle_id if c.old else None) for c in changes]


def test_no_change():
    assert diff_docks(apps("a", "b"), apps("a", "b")) == []


def test_added_at_end():
    assert kinds(diff_docks(apps("a"), apps("a", "b"))) == [("added", "b", None)]


def test_removed():
    assert kinds(diff_docks(apps("a", "b", "c"), apps("a", "c"))) == [("removed", "b", None)]


def test_replaced_in_place():
    assert kinds(diff_docks(apps("a", "vscode", "c"), apps("a", "cursor", "c"))) == [("replaced", "cursor", "vscode")]


def test_replace_block_uneven_gives_replaced_plus_added():
    assert kinds(diff_docks(apps("a", "x", "c"), apps("a", "y", "z", "c"))) == [
        ("replaced", "y", "x"),
        ("added", "z", None),
    ]


def test_moved_app_is_reported_as_moved_not_add_remove():
    assert kinds(diff_docks(apps("a", "b", "c"), apps("b", "c", "a"))) == [("moved", "a", None)]


def test_first_snapshot_diff_from_empty_is_all_added():
    assert [c.kind for c in diff_docks([], apps("a", "b"))] == ["added", "added"]


def test_change_describe():
    assert Change("replaced", apps("cursor")[0], apps("vscode")[0]).describe() == "VSCODE → CURSOR"
    assert Change("added", apps("x")[0]).describe() == "+ X"
    assert Change("removed", apps("x")[0]).describe() == "− X"
