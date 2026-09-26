"""Import past Docks from Time Machine: each backup holds a copy of the Dock's preferences."""

from __future__ import annotations

import datetime as dt
import plistlib
import re
import subprocess
from dataclasses import dataclass, replace
from pathlib import Path

from dock_timelapse.capture import _content_addressed
from dock_timelapse.dockdata import DockApp, parse_dock_prefs
from dock_timelapse.store import Snapshot, Store

SOURCE = "time-machine"
BACKUP_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2})-(\d{2})(\d{2})(\d{2})")
FULL_DISK_ACCESS = ("Grant Full Disk Access to the app running this command (your terminal, or the AI app): "
                    "System Settings → Privacy & Security → Full Disk Access.")


class TimeMachineError(Exception):
    pass


@dataclass(frozen=True)
class Backup:
    when: dt.datetime
    root: Path


def backup_time(name: str) -> dt.datetime | None:
    m = BACKUP_NAME.match(name)
    if not m:
        return None
    day, hh, mm, ss = m.groups()
    return dt.datetime.combine(dt.date.fromisoformat(day), dt.time(int(hh), int(mm), int(ss)))


def list_backups() -> list[Backup]:
    """Backups of this Mac known to Time Machine (the backup disk must be connected)."""
    r = subprocess.run(["/usr/bin/tmutil", "listbackups"], capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    if r.returncode != 0 or not r.stdout.strip():
        if "not permitted" in out.lower() or "full disk access" in out.lower():
            raise TimeMachineError(f"Time Machine refused to list backups. {FULL_DISK_ACCESS}")
        raise TimeMachineError("No Time Machine backups found"
                               + (f" (tmutil: {out.splitlines()[-1]})" if out else "")
                               + ". Connect the backup disk, or pass the backups folder explicitly.")
    return _backups([Path(line) for line in r.stdout.splitlines() if line.strip()])


def backups_in(folder: Path) -> list[Backup]:
    """Backups in a folder: a machine folder of a backup disk, or a single backup."""
    folder = Path(folder)
    if backup_time(folder.name):
        return _backups([folder])
    try:
        found = _backups(sorted(folder.iterdir()))
    except FileNotFoundError:
        raise TimeMachineError(f"{folder} doesn't exist.") from None
    except PermissionError:
        raise TimeMachineError(f"Can't read {folder}. {FULL_DISK_ACCESS}") from None
    if not found:
        raise TimeMachineError(f"No Time Machine backups in {folder} (expected folders named like 2026-01-31-093000).")
    return found


def _backups(paths: list[Path]) -> list[Backup]:
    found = {}
    for p in paths:
        when = backup_time(p.name)
        if when:
            found[when] = Backup(when, p)
    return [found[k] for k in sorted(found)]


def find_dock_plist(backup: Backup, home: Path) -> Path | None:
    """The Dock prefs inside a backup. Volumes sit one or two levels down depending on the backup format."""
    rel = Path(*home.parts[1:]) / "Library/Preferences/com.apple.dock.plist"
    for prefix in ("", "*", "*/*"):
        try:
            hits = sorted(backup.root.glob(f"{prefix}/{rel}" if prefix else str(rel)))
        except PermissionError:
            raise TimeMachineError(f"Can't read {backup.root}. {FULL_DISK_ACCESS}") from None
        if hits:
            return hits[0]
    return None


@dataclass
class ImportResult:
    backups: int
    read: int
    added: int
    first: str | None
    last: str | None


def import_backups(store: Store, mac, backups: list[Backup], home: Path | None = None) -> ImportResult:
    """Read the Dock from each backup and fold one snapshot per day of change into the store."""
    home = home or Path.home()
    states: list[tuple[dt.datetime, list[DockApp], Path]] = []
    for b in backups:
        plist = find_dock_plist(b, home)
        if plist is None:
            continue
        try:
            apps = parse_dock_prefs(plistlib.loads(plist.read_bytes()))
        except PermissionError:
            raise TimeMachineError(f"Can't read {plist}. {FULL_DISK_ACCESS}") from None
        except (plistlib.InvalidFileException, ValueError):
            continue
        if apps:
            # <volume>/Users/<me>/Library/Preferences/com.apple.dock.plist → <volume>
            states.append((b.when, apps, plist.parents[len(home.parts) + 1]))

    if backups and not states:
        raise TimeMachineError(f"None of the {len(backups)} backups had readable Dock preferences. "
                               f"If they should, this is usually missing permission. {FULL_DISK_ACCESS}")

    # One state per day (the last backup of the day wins), and only the days where it changed.
    by_day = {when.date(): (when, apps, volume) for when, apps, volume in sorted(states, key=lambda s: s[0])}
    kept = []
    for when, apps, volume in by_day.values():
        if not kept or kept[-1][1] != apps:
            kept.append((when, apps, volume))

    icons: dict[str, str] = {}
    for _, apps, volume in reversed(kept):  # newest first: the most recent icon of an app wins
        for app in apps:
            if app.key not in icons and (rel := _icon(store, mac, app, volume)):
                icons[app.key] = rel
    wp = mac.wallpaper() if kept else None  # past wallpapers aren't recoverable; today's stands in
    wallpaper = _content_addressed(store, "wallpapers", wp[0].stem, wp[0].suffix, wp[1]) if wp else None

    snaps = [Snapshot(date=when.date().isoformat(), captured_at=when.isoformat(timespec="seconds"), apps=apps,
                      icons={a.key: icons[a.key] for a in apps if a.key in icons}, wallpaper=wallpaper, source=SOURCE)
             for when, apps, _ in kept]
    added = store.merge(snaps) if snaps else 0
    return ImportResult(backups=len(backups), read=len(states), added=added,
                        first=snaps[0].date if snaps else None, last=snaps[-1].date if snaps else None)


def _icon(store: Store, mac, app: DockApp, volume: Path) -> str | None:
    """The app's icon from this Mac, or from its copy in the backup if it has since been deleted."""
    png = mac.icon_png(app)
    if not png and app.path:
        png = mac.icon_png(replace(app, path=str(volume / app.path.lstrip("/"))))
    return _content_addressed(store, "icons", app.key, ".png", png) if png else None
