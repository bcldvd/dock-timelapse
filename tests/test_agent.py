from pathlib import Path

from dock_timelapse.agent import LABEL, capture_command, launchd_plist


def test_plist_runs_capture_hourly_and_at_load():
    p = launchd_plist(["/x/dock-timelapse", "capture"], Path("/d/capture.log"))
    assert p["Label"] == LABEL == "io.github.bcldvd.dock-timelapse"
    assert p["ProgramArguments"] == ["/x/dock-timelapse", "capture"]
    assert p["StartInterval"] == 3600 and p["RunAtLoad"] is True
    assert p["StandardOutPath"] == p["StandardErrorPath"] == "/d/capture.log"


def test_capture_command_uses_the_installed_executable_when_persistent():
    cmd = capture_command(executable="/Users/me/.local/bin/dock-timelapse", uvx="/opt/homebrew/bin/uvx")
    assert cmd == ["/Users/me/.local/bin/dock-timelapse", "capture"]


def test_capture_command_falls_back_to_uvx_when_running_from_an_ephemeral_uvx_env():
    cmd = capture_command(executable="/Users/me/.cache/uv/archive-v0/abc/bin/dock-timelapse", uvx="/opt/homebrew/bin/uvx")
    assert cmd[0] == "/opt/homebrew/bin/uvx"
    assert cmd[-2:] == ["dock-timelapse", "capture"]
    assert "--from" in cmd


def test_data_dir_is_passed_through_when_not_default():
    cmd = capture_command(executable="/bin/dt", uvx=None, data=Path("/custom"))
    assert cmd == ["/bin/dt", "--data", "/custom", "capture"]
