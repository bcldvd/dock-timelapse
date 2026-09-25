"""Invent a plausible past (ending with today's real dock) so anyone can preview the video on day one."""

from __future__ import annotations

import datetime as dt
import random
from pathlib import Path
from urllib.parse import quote

from PIL import Image

from dock_timelapse.capture import _content_addressed
from dock_timelapse.dockdata import DockApp, parse_dock_prefs
from dock_timelapse.store import Store

# Built-in apps every Mac has: plausible "before" states for an invented past.
CLASSICS = [
    DockApp("Safari", "com.apple.Safari", "/Applications/Safari.app"),
    DockApp("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
    DockApp("Music", "com.apple.Music", "/System/Applications/Music.app"),
    DockApp("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
    DockApp("Terminal", "com.apple.Terminal", "/System/Applications/Utilities/Terminal.app"),
    DockApp("Maps", "com.apple.Maps", "/System/Applications/Maps.app"),
    DockApp("FaceTime", "com.apple.FaceTime", "/System/Applications/FaceTime.app"),
    DockApp("Contacts", "com.apple.AddressBook", "/System/Applications/Contacts.app"),
    DockApp("Podcasts", "com.apple.podcasts", "/System/Applications/Podcasts.app"),
    DockApp("TextEdit", "com.apple.TextEdit", "/System/Applications/TextEdit.app"),
]


# A neutral, popular Dock for demos (README previews, `preview --demo`).
DEMO_DOCK = [
    DockApp("Safari", "com.apple.Safari", "/Applications/Safari.app"),
    DockApp("Messages", "com.apple.MobileSMS", "/System/Applications/Messages.app"),
    DockApp("Mail", "com.apple.mail", "/System/Applications/Mail.app"),
    DockApp("Calendar", "com.apple.iCal", "/System/Applications/Calendar.app"),
    DockApp("Slack", "com.tinyspeck.slackmacgap", "/Applications/Slack.app"),
    DockApp("Notion", "notion.id", "/Applications/Notion.app"),
    DockApp("Linear", "com.linear", "/Applications/Linear.app"),
    DockApp("Keynote", "com.apple.iWork.Keynote", "/Applications/Keynote.app"),
    DockApp("Cursor", "com.todesktop.230313mzl4w4u92", "/Applications/Cursor.app"),
    DockApp("ChatGPT", "com.openai.chat", "/Applications/ChatGPT.app"),
    DockApp("Claude", "com.anthropic.claudefordesktop", "/Applications/Claude.app"),
    DockApp("Music", "com.apple.Music", "/System/Applications/Music.app"),
    DockApp("Photos", "com.apple.Photos", "/System/Applications/Photos.app"),
    DockApp("App Store", "com.apple.AppStore", "/System/Applications/App Store.app"),
    DockApp("System Settings", "com.apple.systempreferences", "/System/Applications/System Settings.app"),
]


class DemoMac:
    """Serves DEMO_DOCK as the current Dock; icons and wallpaper come from the real Mac."""

    def __init__(self, base):
        self.base = base

    def dock_prefs(self) -> dict:
        return {"persistent-apps": [
            {"tile-type": "file-tile", "tile-data": {"file-label": a.label, "bundle-identifier": a.bundle_id,
                                                      "file-data": {"_CFURLString": "file://" + quote(a.path) + "/"}}}
            for a in DEMO_DOCK]}

    def icon_png(self, app: DockApp) -> bytes | None:
        return self.base.icon_png(app)

    def wallpaper(self):
        return self.base.wallpaper()


def invent_history(current: list[DockApp], n: int = 7, seed: int = 0,
                   classics: list[DockApp] | None = None) -> list[tuple[int, list[DockApp]]]:
    """Walk backwards from today's dock: undo made-up additions/replacements/removals.

    Returns (days ago, dock) pairs, oldest first; the last one is `current` at day 0.
    The first and last dock items (usually the browser and Settings) stay put.
    """
    rng = random.Random(seed)
    keys = {a.key for a in current}
    pool = [a for a in (classics if classics is not None else CLASSICS) if a.key not in keys]
    states = [list(current)]
    dock = list(current)
    for _ in range(n - 1):
        middle = list(range(1, len(dock) - 1))
        ops = ["remove", "replace", "insert"] if middle else ["insert"]
        weights = [5, 4, 1] if middle else [1]
        for _ in range(1 + (rng.random() < 0.3)):
            op = rng.choices(ops, weights)[0]
            if op in ("replace", "insert") and not pool:
                op = "remove" if middle else None
            if op is None:
                continue
            if op == "remove" and len(dock) > 2:  # forward in time: this app was added
                del dock[rng.choice(range(1, len(dock) - 1))]
            elif op == "replace" and len(dock) > 2:  # forward: a classic got replaced
                dock[rng.choice(range(1, len(dock) - 1))] = pool.pop(rng.randrange(len(pool)))
            else:  # forward: a classic got removed
                dock.insert(rng.randint(1, max(1, len(dock) - 1)), pool.pop(rng.randrange(len(pool))))
            middle = list(range(1, len(dock) - 1))
        if dock == states[-1]:
            dock.insert(1, pool.pop()) if pool else dock.pop(1) if len(dock) > 2 else None
        states.append(list(dock))
    states.reverse()
    gaps = [rng.randint(28, 64) for _ in range(n - 1)]
    days = [sum(gaps[k:]) for k in range(n - 1)] + [0]
    return list(zip(days, states))


def fake_screenshot(icons: list[Path], wallpaper: Path | None, out: Path) -> Path:
    """A vertical left-dock crop like the real capture produces."""
    icon, pad = 64, 10
    h = len(icons) * (icon + pad) + 40
    bg = Image.open(wallpaper).convert("RGB").resize((180, h)) if wallpaper else Image.new("RGB", (180, h), (60, 60, 60))
    img = bg.convert("RGBA")
    for k, p in enumerate(icons):
        if p.exists():
            ic = Image.open(p).convert("RGBA").resize((icon, icon))
            img.alpha_composite(ic, (20, 20 + k * (icon + pad)))
    img.convert("RGB").save(out)
    return out


def build_poc(root: Path, mac, today: dt.date | None = None, seed: int = 7,
              wallpaper: Path | None = None) -> Store:
    today = today or dt.date.today()
    store = Store(root)
    current = parse_dock_prefs(mac.dock_prefs())
    wp = (wallpaper, wallpaper.read_bytes()) if wallpaper else mac.wallpaper()
    wallpaper = _content_addressed(store, "wallpapers", wp[0].stem, wp[0].suffix, wp[1]) if wp else None
    for days_ago, dock in invent_history(current, seed=seed):
        when = dt.datetime.combine(today - dt.timedelta(days=days_ago), dt.time(10, 0))
        icons = {}
        for app in dock:
            png = mac.icon_png(app)
            if png:
                icons[app.key] = _content_addressed(store, "icons", app.key, ".png", png)
        store.observe(dock, when, icons=icons, wallpaper=wallpaper)
        shot = fake_screenshot([root / icons[a.key] for a in dock if a.key in icons],
                               root / wallpaper if wallpaper else None, root / "tmp-shot.png")
        store.attach_screenshot(shot)
        shot.unlink()
    return store
