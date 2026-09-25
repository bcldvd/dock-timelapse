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
