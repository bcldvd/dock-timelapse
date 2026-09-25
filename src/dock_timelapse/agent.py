"""Install / remove the hourly launchd capture agent."""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

LABEL = "io.github.bcldvd.dock-timelapse"
LEGACY_LABELS = ["com.bcldvd.dock-timelapse"]
PACKAGE_SPEC = os.environ.get("DOCK_TIMELAPSE_SPEC", "git+https://github.com/bcldvd/dock-timelapse")
EPHEMERAL_MARKERS = ("/.cache/uv/", "/uv/archive-", "/Caches/uv/")


def plist_path(label: str = LABEL) -> Path:
    return Path.home() / "Library/LaunchAgents" / f"{label}.plist"


def launchd_plist(program: list[str], log: Path, interval: int = 3600) -> dict:
    return {
        "Label": LABEL,
        "ProgramArguments": program,
        "StartInterval": interval,
        "RunAtLoad": True,
        "ProcessType": "Background",
        "StandardOutPath": str(log),
        "StandardErrorPath": str(log),
        "EnvironmentVariables": {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"},
    }


def capture_command(executable: str | None = None, uvx: str | None = None, data: Path | None = None,
                    default_data: Path | None = None) -> list[str]:
    """Command launchd should run. An executable inside a throwaway `uvx` env would vanish, so use uvx itself."""
    executable = executable or shutil.which("dock-timelapse") or sys.argv[0]
    extra = ["--data", str(data)] if data and data != default_data else []
    if any(m in executable for m in EPHEMERAL_MARKERS) and uvx:
        return [uvx, "--from", PACKAGE_SPEC, "dock-timelapse", *extra, "capture"]
    return [executable, *extra, "capture"]


def _launchctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["/bin/launchctl", *args], capture_output=True, text=True)


def install(data: Path, default_data: Path) -> tuple[Path, list[str]]:
    uninstall(quiet=True)
    data.mkdir(parents=True, exist_ok=True)
    cmd = capture_command(executable=os.path.abspath(sys.argv[0]), uvx=shutil.which("uvx"), data=data,
                          default_data=default_data)
    path = plist_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(launchd_plist(cmd, data / "capture.log")))
    r = _launchctl("bootstrap", f"gui/{os.getuid()}", str(path))
    if r.returncode:
        raise RuntimeError(f"launchctl bootstrap failed: {r.stderr.strip()}")
    return path, cmd


def uninstall(quiet: bool = False) -> list[str]:
    removed = []
    for label in [LABEL, *LEGACY_LABELS]:
        _launchctl("bootout", f"gui/{os.getuid()}/{label}")
        p = plist_path(label)
        if p.exists():
            p.unlink()
            removed.append(label)
    return removed


def installed() -> bool:
    return plist_path().exists()
