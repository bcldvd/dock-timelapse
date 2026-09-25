---
name: dock-timelapse
description: Record how the user's macOS Dock evolves over time and render Apple-style timelapse videos (landscape and portrait) of apps being added, removed and replaced. Use when the user asks to track, record, visualize or make a video/timelapse of their Mac Dock, see which apps they adopted or dropped, or check how their Dock changed since some date.
license: MIT
compatibility: macOS with uv (https://docs.astral.sh/uv/). ffmpeg comes bundled.
metadata:
  repository: https://github.com/bcldvd/dock-timelapse
---

# Dock timelapse

`dock-timelapse` records the Dock's pinned apps (read from the Dock's own preferences, up to and
including System Settings) on each day they change, and re-renders the history as videos: a glass Dock
over the blurred wallpaper, springs for arrivals/departures, labels next to changed icons, a day counter.

If `dock_*` / `render_*` MCP tools from the `dock-timelapse` server are available, prefer them.
Otherwise run the CLI. Use `dock-timelapse` if it is on PATH, else prefix every command with:

```bash
uvx dock-timelapse
```

When you hand the user a command to run later, give it in the same full form you used.

## Workflow

1. **Check state**: `dock-timelapse status` → is recording installed, how many snapshots.
2. **Start recording** (once): `dock-timelapse install`
   - Installs a launchd agent that runs hourly and records a snapshot on each day the Dock changes.
   - `--screenshots` also keeps a cropped Dock screenshot per change; tell the user to grant Screen
     Recording to the Python path the command prints (System Settings → Privacy & Security →
     Screen & System Audio Recording). Optional: the videos are drawn from the Dock data.
3. **Show what it will look like now**: `dock-timelapse preview --format both` invents a plausible past
   ending with today's real Dock and renders it. Tell the user the preview history is invented, and how
   many real snapshots exist so far. Options: `--format`, `--background`, `--out`, `--fps`, `--seed`, `--demo`.
   When `status` lists fewer than 2 snapshots, go straight to this step.
4. **Render the real thing** (needs ≥ 2 snapshots to be interesting):
   `dock-timelapse render [--format landscape|portrait|both] [--background wallpaper|desktop|white] [--fps 60]`
   Videos land in `~/Movies/Dock Timelapse/` (override with `--out`). Rendering takes about 15–40 s per
   format at 60 fps; `--fps 30` halves it.
5. **Answer questions from the data**: `dock-timelapse status` lists every snapshot with its changes
   (e.g. "Xcode → Cursor", "+ Linear", "− Mail"); the first one reads "first snapshot" and holds the
   starting Dock. Raw data: `~/Library/Application Support/dock-timelapse/snapshots.json`. The live Dock:
   `defaults read com.apple.dock persistent-apps`.

Stop recording with `dock-timelapse uninstall` (history is kept).

## Notes

- Portrait (1080×1920) draws a vertical Dock with labels beside it; landscape (1920×1080) a horizontal one.
- `still --t 2 5.5` renders PNG frames, handy to show the user a frame before a full render. Keep any
  extracted frames in the user's output folder.
- The agent log is `~/Library/Application Support/dock-timelapse/capture.log`
  (`pending:<reason>` = waiting for the Dock to be visible for a screenshot; it retries hourly).
- Open a finished video for the user with `open "<path>.mp4"`.
