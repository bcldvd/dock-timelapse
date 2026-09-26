"""Run the Python engine as an oracle and write fixtures the Swift port must reproduce.

    uv run python scripts/gen_swift_fixtures.py   # → mac/Tests/Fixtures/*.json
"""

from __future__ import annotations

import datetime as dt
import json
import random
import shutil
import tempfile
from pathlib import Path

from dock_timelapse.diff import diff_docks
from dock_timelapse.dockdata import DockApp
from dock_timelapse.layout import FORMATS, dock_geometry, place_labels
from dock_timelapse.poc import CLASSICS, invent_history
from dock_timelapse.store import Snapshot, Store
from dock_timelapse.timeline import Timeline, build_scenes, summarize

OUT = Path(__file__).resolve().parent.parent / "mac/Tests/Fixtures"
POOL = [chr(c) for c in range(ord("a"), ord("q"))]


def app(key: str) -> DockApp:
    return DockApp(label=key.upper(), bundle_id=key, path=f"/Applications/{key.upper()}.app")


def change_dict(c) -> dict:
    return c.to_dict()


# -- diff ------------------------------------------------------------------------------------
def mutate(rng: random.Random, dock: list[str]) -> list[str]:
    new = list(dock)
    for _ in range(rng.randint(0, 4)):
        op = rng.choice(["insert", "remove", "move", "replace", "swap"])
        spare = [k for k in POOL if k not in new]
        if op == "insert" and spare:
            new.insert(rng.randint(0, len(new)), rng.choice(spare))
        elif op == "remove" and new:
            new.pop(rng.randrange(len(new)))
        elif op == "move" and len(new) > 1:
            k = new.pop(rng.randrange(len(new)))
            new.insert(rng.randint(0, len(new)), k)
        elif op == "replace" and new and spare:
            new[rng.randrange(len(new))] = rng.choice(spare)
        elif op == "swap" and len(new) > 1:
            i, j = rng.sample(range(len(new)), 2)
            new[i], new[j] = new[j], new[i]
    return new


def diff_cases() -> list[dict]:
    rng = random.Random(1)
    cases = []
    for n in range(1500):
        old = rng.sample(POOL, rng.randint(0, 12))
        new = mutate(rng, old) if n % 5 else rng.sample(POOL, rng.randint(0, 12))
        cases.append({"old": old, "new": new,
                      "changes": [change_dict(c) for c in diff_docks([app(k) for k in old], [app(k) for k in new])]})
    return cases


# -- timeline --------------------------------------------------------------------------------
def history(states: list[tuple[str, list[str]]], wallpapers: bool = True) -> list[Snapshot]:
    """Snapshots as Store.observe would build them, with icons and (changing) wallpapers."""
    tmp = Path(tempfile.mkdtemp())
    store = Store(tmp)
    for k, (day, keys) in enumerate(states):
        apps = [app(x) for x in keys]
        icons = {a.key: f"icons/{a.key}.png" for a in apps}
        wp = f"wallpapers/w{k // 2}.jpg" if wallpapers else None
        store.observe(apps, dt.datetime.fromisoformat(day + "T10:00:00"), icons=icons, wallpaper=wp)
    snaps = store.snapshots()
    shutil.rmtree(tmp)
    return snaps


def invented() -> list[tuple[str, list[str]]]:
    current = [app(k) for k in "abcdefghij"]
    classics = [DockApp(c.label, c.bundle_id, c.path) for c in CLASSICS]
    today = dt.date(2026, 9, 26)
    return [((today - dt.timedelta(days=d)).isoformat(), [a.key for a in dock])
            for d, dock in invent_history(current, n=7, seed=7, classics=classics)]


HISTORIES = {
    "invented": invented(),
    "single": [("2026-03-01", list("abcde"))],
    "mixed": [("2025-12-30", list("abcdef")), ("2026-01-02", list("abxcdef")), ("2026-01-02", list("abxcdefg")),
              ("2026-02-11", list("axbcdf")), ("2026-02-12", list("afxbc")), ("2026-06-01", list("afxbcghij")),
              ("2026-06-02", list("fx"))],
    "long": [("2024-01-01", list("abcdefghijklmnop")), ("2024-01-02", list("abcdefghijklmno")),
             ("2025-03-04", list("pbcdefghijklmnoa"))],
}


def tile_dict(t) -> dict:
    return {"key": t.app.key, "pos": t.pos, "slot": t.slot, "scale": t.scale, "alpha": t.alpha,
            "icon": t.icon, "highlight": t.highlight}


def label_dict(l) -> dict:
    return {"change": change_dict(l.change), "alpha": l.alpha, "anchor": l.anchor, "icon": l.icon,
            "old_icon": l.old_icon}


def timeline_cases() -> dict:
    out = {}
    for name, states in HISTORIES.items():
        snaps = history(states)
        # Icons from earlier scenes only, to exercise the timeline's icon fallback.
        for s in snaps[1:]:
            s.icons = {k: v for k, v in list(s.icons.items())[::2]}
        tl = Timeline(build_scenes(snaps))
        frames = []
        steps = int(tl.duration / 0.05) + 2
        for k in range(steps):
            t = round(k * 0.05, 4)
            s = tl.at(t)
            frames.append({"t": t, "scene_index": s.scene_index, "phase": s.phase, "p": s.p,
                           "tiles": [tile_dict(x) for x in s.tiles], "length": s.length, "day": s.day,
                           "date": s.date.isoformat(), "labels": [label_dict(x) for x in s.labels],
                           "progress": s.progress, "outro": s.outro, "title": s.title,
                           "wallpaper": s.wallpaper, "wallpaper_from": s.wallpaper_from,
                           "wallpaper_mix": s.wallpaper_mix})
        sm = summarize(tl.scenes)
        out[name] = {"snapshots": [x.to_dict() for x in snaps], "duration": tl.duration,
                     "outro_start": tl.outro_start, "scene_starts": tl.scene_starts, "frames": frames,
                     "summary": {"days": sm.days, "n_changes": sm.n_changes,
                                 "arrived": [a.key for a in sm.arrived], "left": [a.key for a in sm.left],
                                 "stayed": [a.key for a in sm.stayed], "final_count": sm.final_count}}
    return out


# -- layout ----------------------------------------------------------------------------------
def layout_cases() -> dict:
    geos = []
    for fmt in FORMATS.values():
        for n in range(0, 31):
            g = dock_geometry(fmt, n)
            geos.append({"format": fmt.name, "max_apps": n, "horizontal": g.horizontal, "slot": g.slot,
                         "icon": g.icon, "pad": g.pad, "cross": g.cross, "region": list(g.region),
                         "thickness": g.thickness, "extent_7_5": list(g.extent(7.5)),
                         "center_3_2": list(g.icon_center(3.2, 9.0))})
    rng = random.Random(3)
    labels = []
    for _ in range(300):
        items = [(rng.uniform(0, 1800), rng.uniform(80, 500)) for _ in range(rng.randint(0, 8))]
        if items and rng.random() < 0.3:
            items.append((items[0][0], rng.uniform(80, 300)))  # tie on the anchor
        placed = place_labels(items, gap=16)
        labels.append({"items": items, "placed": [{"start": p.start, "row": p.row} for p in placed]})
    return {"geometry": geos, "labels": labels}


# -- store -----------------------------------------------------------------------------------
def store_case() -> dict:
    """A data dir written by the Python engine: live recordings, a same-day fold, a merged import."""
    tmp = Path(tempfile.mkdtemp())
    store = Store(tmp)
    store.observe([app("a"), app("vscode")], dt.datetime(2026, 1, 10, 9), icons={"a": "icons/a-1.png"},
                  wallpaper="wallpapers/Grass-abc.jpg")
    store.observe([app("a"), app("cursor")], dt.datetime(2026, 1, 11, 9))
    store.observe([app("a"), app("cursor"), app("linear")], dt.datetime(2026, 1, 11, 15))
    store.merge([Snapshot(date="2025-06-01", captured_at="2025-06-01T12:00:00", apps=[app("a"), app("xcode")],
                          source="time-machine")])
    out = {"snapshots_json": (tmp / "snapshots.json").read_text(), "checks_json": (tmp / "checks.json").read_text()}
    shutil.rmtree(tmp)
    return out


# -- golden frames ---------------------------------------------------------------------------
GOLDEN_SIZE = {"landscape": (480, 270), "portrait": (270, 480)}


def synthetic_data(root: Path) -> None:
    """A data dir with generated icons and wallpaper (no Apple artwork in the repo)."""
    from PIL import Image, ImageDraw

    colors = {k: ((37 * i) % 200 + 40, (91 * i) % 200 + 40, (53 * i) % 200 + 40) for i, k in enumerate(POOL)}
    (root / "icons").mkdir(parents=True)
    for k, c in colors.items():
        img = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((50, 50, 462, 462), 92, fill=c + (255,))
        d.ellipse((150, 150, 362, 362), fill=(255, 255, 255, 230))
        d.rectangle((236, 100, 276, 412), fill=c + (255,))
        img.save(root / f"icons/{k}.png")
    (root / "wallpapers").mkdir()
    palettes = [((30, 60, 120), (200, 120, 60)), ((20, 90, 60), (220, 220, 120)), ((90, 30, 80), (240, 170, 120)),
                ((10, 20, 40), (60, 140, 200))]
    for n, (top, bottom) in enumerate(palettes):
        wp = Image.new("RGB", (1600, 1000))
        d = ImageDraw.Draw(wp)
        for y in range(1000):
            t = y / 999
            d.line((0, y, 1600, y), fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))
        d.ellipse((900, 150, 1400, 650), fill=(250, 230, 180))
        d.rectangle((100, 600, 700, 900), fill=(40, 40, 70))
        wp.save(root / f"wallpapers/w{n}.jpg", quality=92)
    snaps = history(HISTORIES["mixed"])
    for s in snaps:
        s.icons = {a.key: f"icons/{a.key}.png" for a in s.apps}
    (root / "snapshots.json").write_text(json.dumps([x.to_dict() for x in snaps], indent=2))


def golden_frames() -> dict:
    from dock_timelapse.layout import FORMATS
    from dock_timelapse.render import Renderer

    data = OUT / "render-data"
    shutil.rmtree(data, ignore_errors=True)
    synthetic_data(data)
    tl = Timeline(build_scenes(Store(data).snapshots()))
    times = {"intro": 0.9, "title": 2.0, "transition": tl.scene_starts[2] + 0.55,
             "hold": tl.scene_starts[3] + 1.6, "moves": tl.scene_starts[4] + 1.5,
             "outro": tl.duration - 0.2}
    frames = []
    gold = OUT / "golden"
    shutil.rmtree(gold, ignore_errors=True)
    gold.mkdir()
    for fmt in FORMATS.values():
        for bg in ("wallpaper", "white"):
            r = Renderer(data, fmt, tl, bg)
            for name, t in times.items():
                img = r.frame(tl.at(t)).resize(GOLDEN_SIZE[fmt.name], resample=1)  # LANCZOS
                path = f"golden/{fmt.name}-{bg}-{name}.png"
                img.save(OUT / path)
                frames.append({"format": fmt.name, "background": bg, "name": name, "t": t, "path": path})
    return {"frames": frames}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "golden.json").write_text(json.dumps(golden_frames()))
    print("golden.json")
    for name, data in {"diff": diff_cases(), "timeline": timeline_cases(), "layout": layout_cases(),
                       "store": store_case()}.items():
        (OUT / f"{name}.json").write_text(json.dumps(data, ensure_ascii=False))
        print(f"{name}.json")


if __name__ == "__main__":
    main()
