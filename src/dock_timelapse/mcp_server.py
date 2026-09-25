"""MCP server (stdio) so any MCP-capable agent can record and render Dock timelapses."""

from __future__ import annotations

import datetime as dt
import tempfile
from pathlib import Path
from typing import Literal

from mcp.server.mcpserver import Image
from mcp.server.mcpserver.exceptions import ToolError

from dock_timelapse.layout import FORMATS

Fmt = Literal["landscape", "portrait", "both"]
Background = Literal["wallpaper", "desktop", "white"]

DEFAULT_OUT = Path.home() / "Movies/Dock Timelapse"

INSTRUCTIONS = """\
dock-timelapse records how the user's macOS Dock evolves (one snapshot per day it changes) and renders
Apple-style timelapse videos (landscape 1920x1080 and portrait 1080x1920).
Typical flow: dock_status → install_recording (once) → weeks later render_timelapse.
If there is no history yet, render_preview shows what the video will look like using an invented past.
Rendering takes roughly 10-30 s per format at 30 fps. Output files are MP4 paths on the user's Mac: tell the user
where they are (open one with `open <path>`). render_frame returns a single PNG you can look at directly.
"""


class DockTools:
    """Tool logic, independent of the MCP transport (and of macOS via the `mac` object)."""

    def __init__(self, data: Path, mac=None, out: Path = DEFAULT_OUT):
        self.data = Path(data)
        self.out = Path(out)
        self._mac = mac

    @property
    def mac(self):
        if self._mac is None:
            from dock_timelapse.macos import RealMac

            self._mac = RealMac()
        return self._mac

    def _store(self):
        from dock_timelapse.store import Store

        return Store(self.data)

    def current_dock(self) -> list[dict]:
        from dock_timelapse.dockdata import parse_dock_prefs

        return [{"position": k + 1, "name": a.label, "bundle_id": a.bundle_id, "path": a.path}
                for k, a in enumerate(parse_dock_prefs(self.mac.dock_prefs()))]

    def history(self) -> list[dict]:
        snaps = self._store().snapshots()
        first = snaps[0].day if snaps else None
        return [{"date": s.date, "day": (s.day - first).days + 1, "app_count": len(s.apps),
                 "apps": [a.label for a in s.apps],
                 "changes": [c.describe() for c in s.changes] if k else ["(first snapshot)"]}
                for k, s in enumerate(snaps)]

    def status(self) -> dict:
        from dock_timelapse import agent, config

        snaps = self._store().snapshots()
        return {
            "recording": agent.installed(),
            "data_dir": str(self.data),
            "screenshots": config.load(self.data)["screenshots"],
            "snapshots": len(snaps),
            "first": snaps[0].date if snaps else None,
            "last_change": snaps[-1].date if snaps else None,
            "can_render": bool(snaps),
        }

    def install(self, screenshots: bool = False) -> dict:
        from dock_timelapse import agent, config

        config.save(self.data, screenshots=screenshots)
        path, cmd = agent.install(self.data, self.data)
        return {"installed": True, "agent_plist": str(path), "command": cmd, "screenshots": screenshots,
                "note": "Runs hourly; records a snapshot on each day the Dock changes."
                + (" Screenshots need Screen Recording permission (System Settings → Privacy & Security)."
                   if screenshots else "")}

    def uninstall(self) -> dict:
        from dock_timelapse import agent

        return {"removed": agent.uninstall(), "data_kept_in": str(self.data)}

    def capture_now(self) -> str:
        from dock_timelapse import config
        from dock_timelapse.capture import run_capture

        return run_capture(self._store(), self.mac, dt.datetime.now(), screenshots=config.load(self.data)["screenshots"])

    def _render(self, data: Path, fmt: str, background: str, fps: int, suffix: str) -> list[str]:
        from dock_timelapse.video import render_video

        if fps <= 0:
            raise ToolError("fps must be a positive number, e.g. 30")
        fmts = list(FORMATS.values()) if fmt == "both" else [FORMATS[fmt]]
        return [str(render_video(data, f, self.out / f"dock-{f.name}-{background}{suffix}.mp4", fps, background,
                                 progress=False)) for f in fmts]

    def render(self, format: str = "both", background: str = "wallpaper", fps: int = 30) -> list[str]:
        if not self._store().snapshots():
            raise ToolError("No history recorded yet. Start it with install_recording, "
                            "or call render_preview to show a demo with an invented past.")
        return self._render(self.data, format, background, fps, "")

    def preview(self, format: str = "both", background: str = "wallpaper", fps: int = 30, seed: int = 7) -> list[str]:
        from dock_timelapse.poc import build_poc

        tmp = Path(tempfile.mkdtemp(prefix="dock-timelapse-preview-"))
        build_poc(tmp, self.mac, seed=seed)
        return self._render(tmp, format, background, fps, "-preview")

    def frame(self, t: float, format: str = "landscape", background: str = "wallpaper", preview: bool = False) -> Path:
        from dock_timelapse.poc import build_poc
        from dock_timelapse.video import render_still

        data = self.data
        if preview:
            data = Path(tempfile.mkdtemp(prefix="dock-timelapse-preview-"))
            build_poc(data, self.mac)
        elif not self._store().snapshots():
            raise ToolError("No history recorded yet. Use preview=true for a demo frame.")
        fmt = FORMATS["landscape" if format == "both" else format]
        self.out.mkdir(parents=True, exist_ok=True)
        return render_still(data, fmt, max(0.0, t), self.out / f"frame-{fmt.name}-{background}.png", background)


def build_server(data: Path):
    from importlib.metadata import version

    from mcp.server.mcpserver import MCPServer
    from mcp.types import ToolAnnotations

    tools = DockTools(data)
    server = MCPServer("dock-timelapse", title="Dock Timelapse", instructions=INSTRUCTIONS,
                       website_url="https://bcldvd.github.io/dock-timelapse/", version=version("dock-timelapse"))
    read = ToolAnnotations(read_only_hint=True, open_world_hint=False)
    write = ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True, open_world_hint=False)

    def out(out_dir: str | None) -> None:
        tools.out = Path(out_dir).expanduser() if out_dir else DEFAULT_OUT

    @server.tool(title="Dock status", annotations=read)
    def dock_status() -> dict:
        """Is recording installed, how many snapshots exist, can we render yet."""
        return tools.status()

    @server.tool(title="Current Dock", annotations=read)
    def current_dock() -> list[dict]:
        """The apps pinned in the Dock right now, in order (everything after System Settings is ignored)."""
        return tools.current_dock()

    @server.tool(title="Dock history", annotations=read)
    def dock_history() -> list[dict]:
        """Every recorded snapshot: date, day number, apps, and what changed (added/removed/replaced/moved)."""
        return tools.history()

    @server.tool(title="Start recording", annotations=write)
    def install_recording(screenshots: bool = False) -> dict:
        """Install the hourly background agent (launchd). screenshots=True also keeps Dock screenshots
        (requires the user to grant Screen Recording permission)."""
        return tools.install(screenshots)

    @server.tool(title="Stop recording", annotations=write)
    def uninstall_recording() -> dict:
        """Remove the background agent. Recorded history is kept."""
        return tools.uninstall()

    @server.tool(title="Capture now", annotations=write)
    def capture_now() -> str:
        """Record the Dock right now (normally done hourly by the agent)."""
        return tools.capture_now()

    @server.tool(title="Render timelapse", annotations=write)
    def render_timelapse(format: Fmt = "both", background: Background = "wallpaper", fps: int = 30,
                         out_dir: str | None = None) -> list[str]:
        """Render MP4 timelapses of the recorded history (needs 2+ snapshots to show change).
        background: wallpaper = blurred desktop picture, desktop = sharp, white = clean white.
        out_dir defaults to ~/Movies/Dock Timelapse. Returns the file paths."""
        out(out_dir)
        return tools.render(format, background, fps)

    @server.tool(title="Render preview", annotations=write)
    def render_preview(format: Fmt = "both", background: Background = "wallpaper", fps: int = 30,
                       out_dir: str | None = None) -> list[str]:
        """Render a demo timelapse from an invented past that ends with today's real Dock.
        Tell the user the history in it is invented. Returns the file paths."""
        out(out_dir)
        return tools.preview(format, background, fps)

    @server.tool(title="Render frame", annotations=write)
    def render_frame(t: float = 3.0, format: Literal["landscape", "portrait"] = "landscape",
                     background: Background = "wallpaper", preview: bool = False) -> Image:
        """Render one frame (PNG) at t seconds so you can see the look before a full render.
        preview=true uses an invented past ending with today's Dock."""
        return Image(path=tools.frame(t, format, background, preview))

    return server


def serve(data: Path) -> None:
    build_server(data).run("stdio")
