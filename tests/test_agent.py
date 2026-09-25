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


def test_installed_only_when_the_agent_records_into_that_data_dir(tmp_path, monkeypatch):
    import plistlib

    from dock_timelapse import agent

    plist = tmp_path / "agent.plist"
    monkeypatch.setattr(agent, "plist_path", lambda label=agent.LABEL: plist)
    assert not agent.installed(tmp_path / "data", default_data=tmp_path / "data")
    plist.write_bytes(plistlib.dumps(launchd_plist(["/bin/dt", "capture"], tmp_path / "log")))
    assert agent.installed(tmp_path / "data", default_data=tmp_path / "data")
    assert not agent.installed(tmp_path / "other", default_data=tmp_path / "data")
    plist.write_bytes(plistlib.dumps(launchd_plist(["/bin/dt", "--data", str(tmp_path / "other"), "capture"], tmp_path / "log")))
    assert agent.installed(tmp_path / "other", default_data=tmp_path / "data")


def test_ephemeral_uvx_install_becomes_a_persistent_uv_tool(tmp_path):
    from dock_timelapse.agent import persistent_executable

    calls = []

    def run(cmd):
        calls.append(cmd)
        return str(tmp_path / "bin")

    exe = persistent_executable("/Users/me/.cache/uv/archive-v0/x/bin/dock-timelapse", uv="/opt/homebrew/bin/uv", run=run)
    assert exe == str(tmp_path / "bin" / "dock-timelapse")
    assert calls[0][:3] == ["/opt/homebrew/bin/uv", "tool", "install"]
    assert persistent_executable("/Users/me/.local/bin/dock-timelapse", uv="/x/uv", run=run) == "/Users/me/.local/bin/dock-timelapse"
