"""Encode frames with ffmpeg (H.264, yuv420p: plays everywhere, incl. iPhone/QuickTime)."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from dock_timelapse.layout import Format
from dock_timelapse.render import Renderer
from dock_timelapse.store import Store
from dock_timelapse.timeline import Timeline, Timing, build_scenes


def ffmpeg_exe() -> str:
    """System ffmpeg when present, otherwise the static build that ships with imageio-ffmpeg."""
    found = shutil.which("ffmpeg")
    if found:
        return found
    import imageio_ffmpeg

    return imageio_ffmpeg.get_ffmpeg_exe()


def load_timeline(data_root: Path, timing: Timing = Timing()) -> Timeline:
    return Timeline(build_scenes(Store(data_root).snapshots()), timing)


def render_video(data_root: Path, fmt: Format, out: Path, fps: int = 60, background: str = "wallpaper",
                 timing: Timing = Timing(), progress: bool = True) -> Path:
    tl = load_timeline(data_root, timing)
    r = Renderer(data_root, fmt, tl, background)
    n = int(round(tl.duration * fps)) + 1
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [ffmpeg_exe(), "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
           "-s", f"{fmt.width}x{fmt.height}", "-r", str(fps), "-i", "-",
           "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
           "-movflags", "+faststart", "-tag:v", "avc1", str(out)]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    try:
        for k in range(n):
            proc.stdin.write(r.frame(tl.at(k / fps)).tobytes())
            if progress and k % fps == 0:
                print(f"\r{fmt.name}: {k}/{n} frames", end="", file=sys.stderr, flush=True)
    finally:
        proc.stdin.close()
        proc.wait()
    if progress:
        print(f"\r{fmt.name}: {n}/{n} frames -> {out}", file=sys.stderr)
    if proc.returncode:
        raise RuntimeError(f"ffmpeg failed ({proc.returncode})")
    return out


def render_still(data_root: Path, fmt: Format, t: float, out: Path, background: str = "wallpaper",
                 timing: Timing = Timing()) -> Path:
    tl = load_timeline(data_root, timing)
    Renderer(data_root, fmt, tl, background).frame(tl.at(t)).save(out)
    return out
