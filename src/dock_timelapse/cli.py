"""dock-timelapse: install | uninstall | capture | status | preview | render | still | mcp"""

from __future__ import annotations

import argparse
import datetime as dt
import os
import sys
import tempfile
from pathlib import Path

from dock_timelapse.layout import FORMATS

DEFAULT_DATA = Path(os.environ.get("DOCK_TIMELAPSE_DATA", Path.home() / "Library/Application Support/dock-timelapse"))
DEFAULT_OUT = Path.home() / "Movies/Dock Timelapse"


def _positive_int(v: str) -> int:
    n = int(v)
    if n <= 0:
        raise argparse.ArgumentTypeError("fps must be a positive number, e.g. 30 or 60")
    return n


def _time(v: str) -> float:
    t = float(v)
    if t < 0:
        raise argparse.ArgumentTypeError("times start at 0 (seconds from the start of the video)")
    return t


def _render_args(p: argparse.ArgumentParser, still: bool = False) -> None:
    p.add_argument("--format", choices=[*FORMATS, "both"], default="both")
    p.add_argument("--background", choices=["wallpaper", "desktop", "white"], default="wallpaper")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"output folder (default: {DEFAULT_OUT})")
    if still:
        p.add_argument("--t", type=_time, nargs="+", default=[3.0], help="times in seconds")
    else:
        p.add_argument("--fps", type=_positive_int, default=60)


def main(argv: list[str] | None = None) -> None:
    fmt_cls = argparse.ArgumentDefaultsHelpFormatter
    ap = argparse.ArgumentParser(prog="dock-timelapse", formatter_class=fmt_cls,
                                 description="Record your macOS Dock over time and render timelapse videos of it.")
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA, help="data dir")
    common = argparse.ArgumentParser(add_help=False)  # lets --data also follow the subcommand
    common.add_argument("--data", type=Path, default=argparse.SUPPRESS, help="data dir")
    sub = ap.add_subparsers(dest="cmd", required=True, metavar="command")
    _add = sub.add_parser

    def add_parser(name, **kw):
        return _add(name, parents=[common], formatter_class=fmt_cls, **kw)

    sub.add_parser = add_parser
    p = sub.add_parser("install", help="start recording: hourly background agent (launchd)")
    p.add_argument("--screenshots", action=argparse.BooleanOptionalAction, default=None,
                   help="also keep a cropped Dock screenshot per change (needs Screen Recording permission)")
    sub.add_parser("uninstall", help="stop recording (keeps your data)")
    sub.add_parser("capture", help="one capture attempt (idempotent; what the agent runs)")
    sub.add_parser("status", help="show recorded snapshots")
    p = sub.add_parser("preview", help="invent a past from today's Dock and render it (see the video on day one)")
    _render_args(p)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--wallpaper", type=Path, help="use this image instead of the current wallpaper")
    p.add_argument("--demo", action="store_true", help="use a generic demo Dock instead of yours")
    _render_args(sub.add_parser("render", help="render the timelapse videos from your recorded history"))
    _render_args(sub.add_parser("still", help="render single PNG frames"), still=True)
    sub.add_parser("poc")  # dev: write an invented history into --data
    sub.add_parser("mcp", help="run the MCP server (stdio) for AI agents")
    args = ap.parse_args(argv)

    if args.cmd == "mcp":
        from dock_timelapse.mcp_server import serve

        serve(args.data)
        return

    if args.cmd == "install":
        from dock_timelapse import agent, config

        cfg = config.save(args.data, **({} if args.screenshots is None else {"screenshots": args.screenshots}))
        path, cmd = agent.install(args.data, DEFAULT_DATA)
        py = agent.python_for(cmd[0])
        print(f"Recording started ({agent.LABEL}). Runs hourly; one snapshot per day the Dock changes.")
        print(f"  agent: {path}\n  data:  {args.data}\n  cmd:   {' '.join(cmd)}")
        if cfg["screenshots"]:
            print("  screenshots: on — grant Screen Recording to the Python running the agent:\n"
                  f"    {py}\n"
                  "    System Settings → Privacy & Security → Screen & System Audio Recording")
        return

    if args.cmd == "uninstall":
        from dock_timelapse import agent

        removed = agent.uninstall()
        print(f"Stopped: {', '.join(removed) or 'nothing was installed'}. Data kept in {args.data}")
        return

    if args.cmd == "capture":
        from dock_timelapse import config
        from dock_timelapse.capture import run_capture
        from dock_timelapse.macos import RealMac
        from dock_timelapse.store import Store

        shots = config.load(args.data)["screenshots"]
        result = run_capture(Store(args.data), RealMac(), dt.datetime.now(), screenshots=shots)
        print(f"{dt.datetime.now():%Y-%m-%d %H:%M} {result}", flush=True)
        return

    if args.cmd == "status":
        from dock_timelapse import agent
        from dock_timelapse.store import Store

        rec = agent.installed(args.data, DEFAULT_DATA)
        print(f"recording: {'on' if rec else 'off (start it with: dock-timelapse install)'}")
        print(f"data:  {args.data}")
        for k, s in enumerate(Store(args.data).snapshots()):
            ch = "first snapshot" if k == 0 else ", ".join(c.describe() for c in s.changes)
            print(f"{s.date}  {len(s.apps):2d} apps  shot={'yes' if s.screenshot else '-'}  {ch}")
        return

    if args.cmd == "poc":
        from dock_timelapse.macos import RealMac
        from dock_timelapse.poc import build_poc

        if (args.data / "snapshots.json").exists():
            sys.exit(f"{args.data} already has data; pick an empty --data for the POC")
        build_poc(args.data, RealMac())
        print(f"Invented history written to {args.data}")
        return

    fmts = list(FORMATS.values()) if args.format == "both" else [FORMATS[args.format]]
    args.out.mkdir(parents=True, exist_ok=True)
    if args.cmd in ("render", "preview"):
        from dock_timelapse.video import render_video

        data, suffix = args.data, ""
        if args.cmd == "preview":
            from dock_timelapse.macos import RealMac
            from dock_timelapse.poc import DemoMac, build_poc

            data, suffix = Path(tempfile.mkdtemp(prefix="dock-timelapse-preview-")), "-preview"
            mac = DemoMac(RealMac()) if args.demo else RealMac()
            build_poc(data, mac, seed=args.seed, wallpaper=args.wallpaper)
        elif not (data / "snapshots.json").exists():
            sys.exit("No history yet. Start recording with `dock-timelapse install`, "
                     "or try `dock-timelapse preview` to see an invented past.")
        for fmt in fmts:
            render_video(data, fmt, args.out / f"dock-{fmt.name}-{args.background}{suffix}.mp4", args.fps, args.background)
    else:
        from dock_timelapse.video import render_still

        if not (args.data / "snapshots.json").exists():
            sys.exit("No history yet. Start recording with `dock-timelapse install`, "
                     "or try `dock-timelapse preview` to see an invented past.")
        for fmt in fmts:
            for t in args.t:
                print(render_still(args.data, fmt, t, args.out / f"still-{fmt.name}-{args.background}-{t:05.1f}.png",
                                   args.background))
