"""Daily capture: record dock data immediately, attach a screenshot once the dock is visible."""

from __future__ import annotations

import datetime as dt
import hashlib
import re
import tempfile
from pathlib import Path
from typing import Protocol

from dock_timelapse.dockdata import DockApp, parse_dock_prefs
from dock_timelapse.store import Store


class Mac(Protocol):
    def dock_prefs(self) -> dict: ...
    def visibility(self, prefs: dict) -> tuple[bool, str]: ...
    def icon_png(self, app: DockApp) -> bytes | None: ...
    def wallpaper(self) -> tuple[Path, bytes] | None: ...
    def dock_screenshot(self, prefs: dict, out: Path) -> Path | None: ...


def dock_crop_box(orientation: str, screen_px: tuple[int, int], scale: float, tilesize: int) -> tuple[int, int, int, int]:
    """Pixel box of the screen edge band holding the dock (generous: icon + magnification margin)."""
    w, h = screen_px
    band = int((tilesize * 1.5 + 40) * scale)
    if orientation == "left":
        return (0, 0, band, h)
    if orientation == "right":
        return (w - band, 0, w, h)
    return (0, h - band, w, h)


def _content_addressed(store: Store, folder: str, stem: str, suffix: str, data: bytes) -> str:
    digest = hashlib.sha256(data).hexdigest()[:10]
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", stem)
    rel = f"{folder}/{safe}-{digest}{suffix}"
    path = store.root / rel
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return rel


def run_capture(store: Store, mac: Mac, now: dt.datetime, screenshots: bool = True) -> str:
    """One capture attempt. Safe to call as often as we like (launchd runs it hourly)."""
    if store.checked_on(now.date()) and (not screenshots or store.pending_screenshot() is None):
        return "already-done"

    prefs = mac.dock_prefs()
    apps = parse_dock_prefs(prefs)
    last = store.snapshots()[-1] if store.snapshots() else None
    if last is None or last.apps != apps:
        icons = {}
        for app in apps:
            png = mac.icon_png(app)
            if png:
                icons[app.key] = _content_addressed(store, "icons", app.key, ".png", png)
        wp = mac.wallpaper()
        wallpaper = _content_addressed(store, "wallpapers", wp[0].stem, wp[0].suffix, wp[1]) if wp else None
        if store.observe(apps, now, icons=icons, wallpaper=wallpaper) is None and store.pending_screenshot() is None:
            return "unchanged"
    else:
        store.observe(apps, now)
        if not screenshots or store.pending_screenshot() is None:
            return "unchanged"
    if not screenshots:
        return "saved"

    visible, reason = mac.visibility(prefs)
    if not visible:
        return f"pending:{reason}"
    with tempfile.TemporaryDirectory() as tmp:
        shot = mac.dock_screenshot(prefs, Path(tmp) / "dock.png")
        if shot is None:
            return "pending:screenshot-failed"
        store.attach_screenshot(shot)
    return "saved"
