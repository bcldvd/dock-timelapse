"""Prepare site/ assets from a demo data dir and demo renders.

    uv run python scripts/build_site.py demo-data out/demo
"""

import json
import shutil
import sys
from pathlib import Path

from PIL import Image

from dock_timelapse.store import Store

data, renders = Path(sys.argv[1]), Path(sys.argv[2])
site = Path("site")
(site / "icons").mkdir(parents=True, exist_ok=True)
(site / "media").mkdir(parents=True, exist_ok=True)

states, first = [], None
for snap in Store(data).snapshots():
    first = first or snap.day
    apps = []
    for a in snap.apps:
        src = data / snap.icons[a.key]
        name = src.stem.split("-")[0].replace(".", "-") + ".png"
        out = site / "icons" / name
        if not out.exists():
            Image.open(src).convert("RGBA").resize((160, 160), Image.LANCZOS).save(out, optimize=True)
        apps.append({"key": a.key, "label": a.label, "icon": f"icons/{name}"})
    states.append({"date": snap.date, "day": (snap.day - first).days + 1, "apps": apps,
                   "changes": [{"kind": c.kind, "label": c.app.label, "old": c.old.label if c.old else None}
                               for c in snap.changes] if states else []})
(site / "data.json").write_text(json.dumps(states, ensure_ascii=False, indent=1))

Image.open("docs/demo-wallpaper.jpg").convert("RGB").resize((1920, 1200), Image.LANCZOS).save(
    site / "media/wallpaper.jpg", quality=85)
for f in ["dock-landscape-wallpaper.mp4", "dock-portrait-wallpaper.mp4"]:
    shutil.copyfile(renders / f, site / "media" / f.replace("-wallpaper", ""))
shutil.copyfile("docs/replaced.png", site / "media/poster-landscape.png")
shutil.copyfile("docs/portrait.png", site / "media/poster-portrait.png")
print(f"{len(states)} states, {len(list((site / 'icons').iterdir()))} icons")
