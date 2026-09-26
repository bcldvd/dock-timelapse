# Dock Timelapse for Mac — native app design

Date: 2026-09-26 · Status: approved direction, self-reviewed build

## Intent

Non-technical people download a DMG, drag **Dock Timelapse** to Applications, and get their Dock timelapse
without Terminal, uv or Python. The app must feel premium and current (SwiftUI, Liquid Glass, macOS 26+),
and be bulletproof: failures are found in development, not by customers.

Decisions taken with the user:
- Menu-bar app plus a first-launch welcome window.
- Developer ID signing + notarization (user is getting the paid membership), distributed outside the App
  Store (the sandbox would block reading the Dock prefs and Time Machine backups).
- **Swift becomes the only engine.** The app bundle ships the CLI (and later the MCP server). The Python
  package is used in development only, as the reference oracle, and later gets a final release pointing
  to the app.

## Sub-projects

1. **Engine + CLI parity** (Swift package `mac/`).
2. **The app** (SwiftUI menu-bar app, onboarding, permissions, background recording, playback).
3. **MCP server, DMG/CI pipeline, migration** of PyPI/plugin users.

## Architecture (Swift package `mac/`)

| Target | Role | Depends on |
|---|---|---|
| `DockCore` | `DockApp`, `Change` + `diffDocks` (a faithful port of Python's `difflib.SequenceMatcher`), `Day`, `Snapshot`, `Store` (the `snapshots.json` contract), `Timeline`, `Layout`, `Summary`, invented preview histories, Time Machine import logic over a file-system protocol. Pure and deterministic. | — |
| `DockMac` | Real macOS: Dock prefs (`CFPreferences`), icons (`NSWorkspace`), wallpaper, `tmutil`, Full Disk Access probe, the background agent (`SMAppService`, LaunchAgent fallback for the bare CLI). | `DockCore` |
| `DockRender` | Frame drawing (Core Graphics / Core Text / Core Image) and encoding (`AVAssetWriter`, hardware H.264, 60 fps, 1920×1080 and 1080×1920). No ffmpeg. | `DockCore` |
| `dock-timelapse` | CLI (swift-argument-parser): `install`, `uninstall`, `capture`, `import`, `status`, `preview`, `render`, `still`. | all |
| `DockTimelapseApp` | SwiftUI app. | all |

Rules:
- Everything touching the OS sits behind a protocol (`MacSystem`, `FileSystem`, `CommandRunner`) with
  fakes in tests.
- Every failure is a typed `DockError` with a user-facing message and a recovery (`openFullDiskAccess`,
  `connectBackupDisk`, …). The CLI prints it; the app turns it into a button.
- Data compatibility: the Swift `Store` reads and writes the exact `snapshots.json` / `checks.json` /
  `config.json` layout of the Python version, in the same data dir
  (`~/Library/Application Support/dock-timelapse`). Existing recordings carry over.
- Screenshots (optional in Python, unused by rendering) are dropped: the field is still read and preserved.

## Proving parity (TDD)

- Port the Python tests to Swift Testing first; they are the spec.
- `scripts/gen_swift_fixtures.py` runs the Python engine to emit oracle fixtures:
  - `diff.json`: hundreds of random Dock pairs → exact expected changes (validates the difflib port).
  - `timeline.json`: frame states (tiles, labels, day, progress, title, outro) sampled across a fixture
    history → Swift must match within 1e-9.
  - `layout.json`: geometry and label placement.
  - Python-written `snapshots.json` files → Swift loads them and round-trips without loss.
- Golden frames: the same fixture rendered by Python and Swift must match within a perceptual tolerance
  (fonts rasterize differently, so text regions are compared loosely); Swift reference frames are then
  committed for pixel-regression tests.

## The app (sub-project 2)

- `MenuBarExtra` (window style) with Liquid Glass: status line (recording, days, changes), the latest Dock
  as icons, primary **Make my video**, secondary **Preview**, **Import from Time Machine**, **Pause/Resume
  recording**, Settings, Quit.
- First launch: a welcome window — what it does, **Start recording** (registers the agent), optional
  Time Machine import with a Full Disk Access step that deep-links System Settings and re-checks
  automatically, then an instant preview.
- Videos render in the background with progress, then play in an in-app player with Reveal in Finder /
  Share.
- Background recording: `SMAppService.agent` running the bundled CLI hourly (`capture`). The legacy Python
  LaunchAgent is detected and replaced.
- View models are plain `@Observable` types tested without UI; the app is smoke-tested by launching it and
  capturing screenshots.

## Distribution (sub-project 3)

`scripts/build-app.sh` builds a universal release, assembles `Dock Timelapse.app` (app + CLI + agent
plist + icon), signs with the hardened runtime; `make-dmg.sh` builds and notarizes the DMG. A macOS CI job
does this on `v*` tags and attaches the DMG to the GitHub Release.
