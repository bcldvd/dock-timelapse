"""MCP server (stdio) so any MCP-capable agent can record and render Dock timelapses."""

from __future__ import annotations

import datetime as dt
import tempfile
from pathlib import Path

from dock_timelapse.layout import FORMATS

DEFAULT_OUT = Path.home() / "Movies/Dock Timelapse"

INSTRUCTIONS = """\
dock-timelapse records how the user's macOS Dock evolves (one snapshot per day it changes) and renders
Apple-style timelapse videos (landscape 1920x1080 and portrait 1080x1920).
Typical flow: dock_status → install_recording (once) → weeks later render_timelapse.
If there is no history yet, render_preview shows what the video will look like using an invented past.
Rendering takes ~20-60 s per format. Output files are MP4 paths on the user's Mac; tell the user where they are.
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

        if fmt not in (*FORMATS, "both"):
            raise ValueError(f"format must be one of {[*FORMATS, 'both']}")
        if background not in ("wallpaper", "desktop", "white"):
            raise ValueError("background must be wallpaper, desktop or white")
        fmts = list(FORMATS.values()) if fmt == "both" else [FORMATS[fmt]]
        return [str(render_video(data, f, self.out / f"dock-{f.name}-{background}{suffix}.mp4", fps, background,
                                 progress=False)) for f in fmts]

    def render(self, format: str = "both", background: str = "wallpaper", fps: int = 30) -> list[str]:
        if not self._store().snapshots():
            raise ValueError("No history recorded yet. Use install_recording, or render_preview for a demo.")
        return self._render(self.data, format, background, fps, "")

    def preview(self, format: str = "both", background: str = "wallpaper", fps: int = 30, seed: int = 7) -> list[str]:
        from dock_timelapse.poc import build_poc

        tmp = Path(tempfile.mkdtemp(prefix="dock-timelapse-preview-"))
        build_poc(tmp, self.mac, seed=seed)
        return self._render(tmp, format, background, fps, "-preview")


def build_server(data: Path):
    from mcp.server.mcpserver import MCPServer

    tools = DockTools(data)
    server = MCPServer("dock-timelapse", title="Dock Timelapse", instructions=INSTRUCTIONS,
                       website_url="https://github.com/bcldvd/dock-timelapse")

    @server.tool(title="Dock status")
    def dock_status() -> dict:
        """Is recording installed, how many snapshots exist, can we render yet."""
        return tools.status()

    @server.tool(title="Current Dock")
    def current_dock() -> list[dict]:
        """The apps pinned in the Dock right now, in order (everything after System Settings is ignored)."""
        return tools.current_dock()

    @server.tool(title="Dock history")
    def dock_history() -> list[dict]:
        """Every recorded snapshot: date, day number, apps, and what changed (added/removed/replaced/moved)."""
        return tools.history()

    @server.tool(title="Start recording")
    def install_recording(screenshots: bool = False) -> dict:
        """Install the hourly background agent (launchd). screenshots=True also keeps Dock screenshots
        (requires the user to grant Screen Recording permission)."""
        return tools.install(screenshots)

    @server.tool(title="Stop recording")
    def uninstall_recording() -> dict:
        """Remove the background agent. Recorded history is kept."""
        return tools.uninstall()

    @server.tool(title="Capture now")
    def capture_now() -> str:
        """Record the Dock right now (normally done hourly by the agent)."""
        return tools.capture_now()

    @server.tool(title="Render timelapse")
    def render_timelapse(format: str = "both", background: str = "wallpaper", fps: int = 30) -> list[str]:
        """Render MP4 timelapses of the recorded history. format: landscape | portrait | both.
        background: wallpaper (blurred desktop picture) | desktop (sharp) | white. Returns file paths."""
        return tools.render(format, background, fps)

    @server.tool(title="Render preview")
    def render_preview(format: str = "both", background: str = "wallpaper", fps: int = 30) -> list[str]:
        """Render a demo timelapse from an invented past that ends with today's real Dock. Returns file paths."""
        return tools.preview(format, background, fps)

    return server


def serve(data: Path) -> None:
    build_server(data).run("stdio")
