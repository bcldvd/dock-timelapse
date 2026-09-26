import pytest

from dock_timelapse.cli import main


def test_still_with_no_history_explains_what_to_do(tmp_path, capsys):
    with pytest.raises(SystemExit) as e:
        main(["--data", str(tmp_path), "still", "--out", str(tmp_path / "o")])
    assert "dock-timelapse preview" in str(e.value)


def test_fps_must_be_positive(tmp_path, capsys):
    with pytest.raises(SystemExit):
        main(["--data", str(tmp_path), "render", "--fps", "0"])
    assert "fps" in capsys.readouterr().err


def test_data_flag_works_after_the_subcommand_too(tmp_path, capsys):
    main(["status", "--data", str(tmp_path)])
    assert str(tmp_path) in capsys.readouterr().out


def test_status_marks_the_first_snapshot(tmp_path, capsys):
    import datetime as dt

    from dock_timelapse.capture import run_capture
    from dock_timelapse.store import Store
    from tests.test_poc import FakeMac

    run_capture(Store(tmp_path), FakeMac(), dt.datetime(2026, 1, 1, 9), screenshots=False)
    main(["--data", str(tmp_path), "status"])
    line = capsys.readouterr().out.strip().splitlines()[-1]
    assert line.endswith("first snapshot") and line.count("apps") == 1


def test_import_from_a_backups_folder_then_status_labels_it(tmp_path, capsys, monkeypatch):
    from pathlib import Path

    import dock_timelapse.timemachine as tm
    from tests.test_timemachine import make_backup

    make_backup(tmp_path / "tm", "2025-06-01-090000.backup", ["Arc"], volume="Data")
    make_backup(tmp_path / "tm", "2025-08-01-090000.backup", ["Arc", "Slack"], volume="Data")
    real = tm.import_backups
    monkeypatch.setattr(tm, "import_backups",
                        lambda store, mac, backups: real(store, _NoMac(), backups, home=Path("/Users/me")))
    main(["--data", str(tmp_path / "d"), "import", "--backups", str(tmp_path / "tm")])
    assert "Imported 2 snapshots (2025-06-01 → 2025-08-01)" in capsys.readouterr().out
    main(["--data", str(tmp_path / "d"), "status"])
    assert capsys.readouterr().out.strip().splitlines()[-1].endswith("+ Slack  (Time Machine)")


def test_import_with_no_backups_explains(tmp_path):
    (tmp_path / "empty").mkdir()
    with pytest.raises(SystemExit, match="No Time Machine backups in"):
        main(["--data", str(tmp_path / "d"), "import", "--backups", str(tmp_path / "empty")])


class _NoMac:
    def icon_png(self, app):
        return None

    def wallpaper(self):
        return None
