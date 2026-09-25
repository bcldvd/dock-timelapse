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
PACKAGE_SPEC = os.environ.get("DOCK_TIMELAPSE_SPEC", "dock-timelapse")
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


def persistent_executable(executable: str, uv: str | None, run=None) -> str:
    """A throwaway `uvx` environment can vanish (and breaks permissions), so install a stable `uv tool` copy."""
    if not any(m in executable for m in EPHEMERAL_MARKERS) or not uv:
        return executable

    def _run(cmd: list[str]) -> str:
        return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip()

    run = run or _run
    run([uv, "tool", "install", "--quiet", PACKAGE_SPEC])
    return str(Path(run([uv, "tool", "dir", "--bin"])) / "dock-timelapse")


def python_for(executable: str) -> Path:
    """The Python interpreter behind an entry-point script (what macOS permissions attach to)."""
    exe = Path(executable).resolve()
    for cand in (exe.parent / "python3", exe.parent / "python"):
        if cand.exists():
            return cand.resolve()
    return Path(sys.executable).resolve()


def _launchctl(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["/bin/launchctl", *args], capture_output=True, text=True)


def install(data: Path, default_data: Path) -> tuple[Path, list[str]]:
    uninstall(quiet=True)
    data.mkdir(parents=True, exist_ok=True)
    exe = persistent_executable(os.path.abspath(sys.argv[0]), uv=shutil.which("uv"))
    cmd = capture_command(executable=exe, uvx=shutil.which("uvx"), data=data, default_data=default_data)
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


def installed(data: Path | None = None, default_data: Path | None = None) -> bool:
    """Is the agent installed (and, when `data` is given, recording into that data dir)?"""
    path = plist_path()
    if not path.exists():
        return False
    if data is None:
        return True
    args = plistlib.loads(path.read_bytes()).get("ProgramArguments", [])
    target = Path(args[args.index("--data") + 1]) if "--data" in args else default_data
    return target is not None and Path(target).resolve() == Path(data).resolve()
