"""Draw the app icon (1024 px, macOS icon grid) and build AppIcon.icns.

    uv run python mac/scripts/make_icon.py
"""

from __future__ import annotations

import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "Bundle"
S = 4  # supersampling
SIZE = 1024


def squircle_mask(size: int, inset: int, n: float = 5.0) -> Image.Image:
    """Apple-style continuous-corner shape (a superellipse) on the macOS icon grid."""
    big = size * S
    m = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(m)
    r = (size - 2 * inset) * S / 2
    c = big / 2
    pts = []
    for k in range(720):
        t = 2 * math.pi * k / 720
        ct, st = math.cos(t), math.sin(t)
        x = c + r * math.copysign(abs(ct) ** (2 / n), ct)
        y = c + r * math.copysign(abs(st) ** (2 / n), st)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def gradient(size: int, stops: list[tuple[float, tuple[int, int, int]]]) -> Image.Image:
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (0.75 * y + 0.25 * x) / size
            for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
                if t0 <= t <= t1:
                    u = (t - t0) / (t1 - t0)
                    px[x, y] = tuple(int(a + (b - a) * u) for a, b in zip(c0, c1))
                    break
    return img


def rounded(draw: ImageDraw.ImageDraw, box, r, **kw):
    draw.rounded_rectangle([v * S for v in box], r * S, **kw)


def main() -> None:
    inset = 100  # 824 px shape on the 1024 grid
    mask = squircle_mask(SIZE, inset)
    bg = gradient(SIZE, [(0, (42, 50, 140)), (0.55, (112, 58, 214)), (1.0, (236, 96, 150))]).convert("RGBA")

    # Soft light from the top-left.
    glow = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(glow).ellipse((60, -260, 900, 520), fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    bg = Image.composite(Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255)), bg, glow.point(lambda v: v * 0.35))

    layer = Image.new("RGBA", (SIZE * S, SIZE * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Timeline: a track with a filled part, stops, and the knob.
    y = 395
    rounded(d, (250, y - 9, 774, y + 9), 9, fill=(255, 255, 255, 80))
    rounded(d, (250, y - 9, 610, y + 9), 9, fill=(255, 255, 255, 235))
    for x, on in ((250, True), (400, True), (520, True), (700, False)):
        d.ellipse([(x - 16) * S, (y - 16) * S, (x + 16) * S, (y + 16) * S], fill=(255, 255, 255, 255 if on else 110))
    d.ellipse([(610 - 34) * S, (y - 34) * S, (610 + 34) * S, (y + 34) * S], fill=(255, 255, 255, 255))

    layer = layer.resize((SIZE, SIZE), Image.LANCZOS)
    bg.alpha_composite(layer)

    # The glass Dock: shadow, frosted plate, hairline, four app tiles (the last one springing in).
    dock = (190, 540, 834, 750)
    sh = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(sh).rounded_rectangle((dock[0], dock[1] + 30, dock[2], dock[3] + 30), 70, fill=150)
    sh = sh.filter(ImageFilter.GaussianBlur(36))
    bg = Image.composite(Image.new("RGBA", (SIZE, SIZE), (20, 10, 60, 255)), bg, sh.point(lambda v: v * 0.55))
    frosted = bg.filter(ImageFilter.GaussianBlur(28))
    frosted = Image.blend(frosted, Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255)), 0.28)
    pm = Image.new("L", (SIZE * S, SIZE * S), 0)
    rounded(ImageDraw.Draw(pm), dock, 72, fill=255)
    pm = pm.resize((SIZE, SIZE), Image.LANCZOS)
    bg = Image.composite(frosted, bg, pm)

    top = Image.new("RGBA", (SIZE * S, SIZE * S), (0, 0, 0, 0))
    t = ImageDraw.Draw(top)
    rounded(t, dock, 72, outline=(255, 255, 255, 170), width=4 * S)
    tiles = [((66, 153, 255), (20, 100, 230)), ((52, 211, 120), (20, 160, 80)), ((255, 170, 60), (245, 110, 30)),
             ((255, 90, 120), (220, 40, 90))]
    tile, gap = 116, 30
    x = (dock[0] + dock[2]) / 2 - (4 * tile + 3 * gap) / 2
    for k, (c0, c1) in enumerate(tiles):
        s = tile * (0.78 if k == 3 else 1.0)
        cx, cy = x + tile / 2, (dock[1] + dock[3]) / 2 - (10 if k == 3 else 0)
        box = (cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2)
        tg = Image.new("RGBA", (int(s * S), int(s * S)))
        tp = tg.load()
        for yy in range(tg.height):
            u = yy / max(1, tg.height - 1)
            row = tuple(int(a + (b - a) * u) for a, b in zip(c0, c1)) + (255,)
            for xx in range(tg.width):
                tp[xx, yy] = row
        tm = Image.new("L", tg.size, 0)
        ImageDraw.Draw(tm).rounded_rectangle((0, 0, tg.width - 1, tg.height - 1), int(s * 0.26 * S), fill=255)
        tg.putalpha(tm)
        top.alpha_composite(tg, (int(box[0] * S), int(box[1] * S)))
        x += tile + gap
    # Highlight dot under the arriving app.
    dx = x - gap - tile / 2
    t.ellipse([(dx - 9) * S, (dock[3] - 34) * S, (dx + 9) * S, (dock[3] - 16) * S], fill=(255, 255, 255, 230))
    bg.alpha_composite(top.resize((SIZE, SIZE), Image.LANCZOS))

    # Hairline edge + drop shadow on the icon shape itself.
    edge = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(5)))
    bg = Image.composite(Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 255)), bg, edge.point(lambda v: v * 0.25))
    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow = mask.filter(ImageFilter.GaussianBlur(18)).point(lambda v: v * 0.45)
    icon.paste((0, 0, 0, 255), (0, 12), shadow)
    body = bg.copy()
    body.putalpha(mask)
    icon.alpha_composite(body)

    OUT.mkdir(parents=True, exist_ok=True)
    icon.save(OUT / "AppIcon-1024.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for px in (16, 32, 128, 256, 512):
            icon.resize((px, px), Image.LANCZOS).save(iconset / f"icon_{px}x{px}.png")
            icon.resize((px * 2, px * 2), Image.LANCZOS).save(iconset / f"icon_{px}x{px}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "AppIcon.icns")], check=True)
    print(OUT / "AppIcon.icns")


if __name__ == "__main__":
    main()
