import asyncio
import datetime as dt

from dock_timelapse.capture import run_capture
from dock_timelapse.mcp_server import DockTools, build_server
from dock_timelapse.store import Store
from tests.test_poc import FakeMac


def test_current_dock_and_history(tmp_path):
    mac = FakeMac()
    run_capture(Store(tmp_path), mac, dt.datetime(2026, 1, 1, 10), screenshots=False)
    t = DockTools(tmp_path, mac=mac)
    assert t.current_dock()[0] == {"position": 1, "name": "Arc", "bundle_id": "company.thebrowser.Browser",
                                   "path": "/Applications/Arc.app"}
    h = t.history()
    assert h[0]["date"] == "2026-01-01" and h[0]["day"] == 1 and h[0]["changes"] == ["(first snapshot)"]


def test_render_without_history_explains_what_to_do(tmp_path):
    import pytest

    from mcp.server.mcpserver.exceptions import ToolError

    with pytest.raises(ToolError, match="render_preview"):
        DockTools(tmp_path, mac=FakeMac()).render()


def test_server_lists_expected_tools(tmp_path):
    server = build_server(tmp_path)
    names = {t.name for t in asyncio.run(server.list_tools())}
    assert names == {"dock_status", "current_dock", "dock_history", "install_recording", "uninstall_recording",
                     "capture_now", "render_timelapse", "render_preview", "render_frame"}


def test_tool_errors_reach_the_agent_with_their_message(tmp_path):
    import pytest
    from mcp.server.mcpserver.exceptions import ToolError

    server = build_server(tmp_path)
    with pytest.raises(ToolError, match="call render_preview"):
        asyncio.run(server.call_tool("render_timelapse", {}))


def test_format_is_an_enum_in_the_schema(tmp_path):
    tools = {t.name: t for t in asyncio.run(build_server(tmp_path).list_tools())}
    props = tools["render_timelapse"].input_schema["properties"]
    assert set(props["format"]["enum"]) == {"landscape", "portrait", "both"}
    assert tools["dock_status"].annotations.read_only_hint is True


def test_server_reports_its_version(tmp_path):
    from importlib.metadata import version

    assert build_server(tmp_path).version == version("dock-timelapse")
