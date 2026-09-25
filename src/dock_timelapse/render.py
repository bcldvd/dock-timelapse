"""Draw a FrameState: Apple-style re-rendered dock over the (blurred) real wallpaper."""

from __future__ import annotations

import datetime as dt
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

from dock_timelapse.layout import Format, dock_geometry
from dock_timelapse.timeline import FrameState, Label, Summary, Timeline, clamp01, ease_out

SF = "/System/Library/Fonts/SFNS.ttf"
SS = 3  # supersampling for anti-aliased shapes

THEMES = {
    # wallpaper: blurred real wallpaper, light text.  white: Apple-keynote white, dark text.
    "wallpaper": dict(fg=(255, 255, 255), fg2=(255, 255, 255, 175), plate=(255, 255, 255, 46),
                      stroke=(255, 255, 255, 90), shadow=70, green=(48, 209, 88), red=(255, 69, 58),
                      pill=(18, 20, 26, 120), track=(255, 255, 255, 60)),
    "white": dict(fg=(29, 29, 31), fg2=(29, 29, 31, 150), plate=(255, 255, 255, 190),
                  stroke=(0, 0, 0, 22), shadow=38, green=(40, 170, 70), red=(230, 55, 45),
                  pill=(255, 255, 255, 230), track=(0, 0, 0, 30)),
}
THEMES["desktop"] = THEMES["wallpaper"]


@lru_cache(maxsize=256)
def font(size: int, weight: int = 400) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(SF, size)
    try:
        f.set_variation_by_axes([100, max(17, min(96, size)), 400, weight])
    except OSError:
        pass
    return f


@lru_cache(maxsize=512)
def rounded_mask(w: int, h: int, r: int, outline: int = 0) -> Image.Image:
    """Anti-aliased rounded-rect mask (optionally just its outline)."""
    w, h = max(1, w), max(1, h)
    big = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(big)
    rr = min(r, w // 2, h // 2) * SS
    if outline:
        d.rounded_rectangle((0, 0, w * SS - 1, h * SS - 1), rr, outline=255, width=outline * SS)
    else:
        d.rounded_rectangle((0, 0, w * SS - 1, h * SS - 1), rr, fill=255)
    return big.resize((w, h), Image.LANCZOS)


@lru_cache(maxsize=256)
def shadow_mask(w: int, h: int, r: int, blur: int) -> Image.Image:
    m = Image.new("L", (w + 4 * blur, h + 4 * blur), 0)
    m.paste(rounded_mask(w, h, r), (2 * blur, 2 * blur))
    return m.filter(ImageFilter.GaussianBlur(blur))


def _cover(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(img.convert("RGB"), size, Image.LANCZOS, centering=(0.5, 0.5))


def _with_alpha(img: Image.Image, alpha: float) -> Image.Image:
    if alpha >= 0.999:
        return img
    out = img.copy()
    out.putalpha(img.getchannel("A").point(lambda a: int(a * alpha)))
    return out


class Renderer:
    def __init__(self, data_root: Path | str, fmt: Format, timeline: Timeline, background: str = "wallpaper"):
        self.root = Path(data_root)
        self.fmt = fmt
        self.tl = timeline
        self.mode = background
        self.theme = THEMES[background]
        self.geo = dock_geometry(fmt, max(len(s.apps) for s in timeline.scenes))
        self._bg: dict[str | None, tuple[Image.Image, Image.Image]] = {}
        self._icons: dict[tuple[str | None, int, bool], Image.Image] = {}
        self._first = timeline.scenes[0].date
        self._last = timeline.scenes[-1].date

    # -- backgrounds --------------------------------------------------------
    def _backgrounds(self, wallpaper: str | None) -> tuple[Image.Image, Image.Image]:
        key = wallpaper if self.mode != "white" else None
        if key in self._bg:
            return self._bg[key]
        size = (self.fmt.width, self.fmt.height)
        path = self.root / wallpaper if wallpaper else None
        if self.mode == "white" or not path or not path.exists():
            base = Image.new("RGB", size, (245, 245, 247) if self.mode == "white" else (38, 44, 58))
            frosted = Image.new("RGB", size, (255, 255, 255) if self.mode == "white" else (70, 76, 92))
        else:
            wp = _cover(Image.open(path), size)
            small = wp.resize((size[0] // 4, size[1] // 4), Image.LANCZOS)
            soft = 2 if self.mode == "desktop" else 7
            base = small.filter(ImageFilter.GaussianBlur(soft)).resize(size, Image.BICUBIC)
            if self.mode == "desktop":
                base = wp.filter(ImageFilter.GaussianBlur(1.5))
            # Darken for legible white type, a bit more at the top where the header sits.
            shade = Image.linear_gradient("L").resize(size).point(lambda v: int(105 - v * 0.3))
            base = Image.composite(Image.new("RGB", size, (8, 10, 14)), base, shade)
            frosted = small.filter(ImageFilter.GaussianBlur(14)).resize(size, Image.BICUBIC)
            frosted = Image.blend(frosted, Image.new("RGB", size, (255, 255, 255)), 0.18)
        self._bg[key] = (base.convert("RGBA"), frosted.convert("RGBA"))
        return self._bg[key]

    # -- icons ----------------------------------------------------------------
    def _icon(self, rel: str | None, size: int, gray: bool = False) -> Image.Image:
        size = max(1, int(size))
        key = (rel, size, gray)
        if key in self._icons:
            return self._icons[key]
        path = self.root / rel if rel else None
        if path and path.exists():
            img = Image.open(path).convert("RGBA")
            # macOS icons carry ~10% transparent margin; crop it so size means "visible tile".
            bbox = img.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox() or (0, 0, *img.size)
            side = max(bbox[2] - bbox[0], bbox[3] - bbox[1])
            cx, cy = (bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2
            img = img.crop((int(cx - side / 2), int(cy - side / 2), int(cx + side / 2), int(cy + side / 2)))
            img = img.resize((size, size), Image.LANCZOS)
        else:
            img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            img.paste((120, 124, 134, 255), (0, 0), rounded_mask(size, size, int(size * 0.23)))
        if gray:
            a = img.getchannel("A")
            img = ImageOps.grayscale(img.convert("RGB")).convert("RGBA")
            img.putalpha(a)
        if len(self._icons) > 4000:
            self._icons.clear()
        self._icons[key] = img
        return img

    # -- primitives -----------------------------------------------------------
    def _glass(self, canvas, frosted, box, radius, fill, stroke, shadow=True):
        x0, y0, x1, y1 = (int(round(v)) for v in box)
        w, h = x1 - x0, y1 - y0
        if w < 2 or h < 2:
            return
        if shadow and self.theme["shadow"]:
            blur = max(6, h // 5)
            sm = shadow_mask(w, h, radius, blur)
            layer = Image.new("RGBA", sm.size, (0, 0, 0, 0))
            layer.putalpha(sm.point(lambda a: a * self.theme["shadow"] // 255))
            canvas.alpha_composite(layer, (x0 - 2 * blur, y0 - 2 * blur + blur // 2))
        mask = rounded_mask(w, h, radius)
        canvas.paste(frosted.crop((x0, y0, x1, y1)), (x0, y0), mask)
        tint = Image.new("RGBA", (w, h), fill[:3] + (0,))
        tint.putalpha(mask.point(lambda a: a * fill[3] // 255))
        canvas.alpha_composite(tint, (x0, y0))
        ring = Image.new("RGBA", (w, h), stroke[:3] + (0,))
        ring.putalpha(rounded_mask(w, h, radius, outline=1).point(lambda a: a * stroke[3] // 255))
        canvas.alpha_composite(ring, (x0, y0))

    def _text(self, draw, xy, text, size, weight=400, fill=None, anchor="la", tracking=0.0, alpha=1.0):
        fill = fill or self.theme["fg"]
        rgba = fill[:3] + (int((fill[3] if len(fill) == 4 else 255) * alpha),)
        f = font(size, weight)
        if not tracking:
            draw.text(xy, text, font=f, fill=rgba, anchor=anchor)
            return f.getlength(text)
        x, y = xy
        total = sum(f.getlength(c) for c in text) + tracking * size * (len(text) - 1)
        if anchor[0] == "m":
            x -= total / 2
        for c in text:
            draw.text((x, y), c, font=f, fill=rgba, anchor="l" + anchor[1])
            x += f.getlength(c) + tracking * size
        return total

    # -- frame ------------------------------------------------------------------
    def frame(self, s: FrameState) -> Image.Image:
        base, frosted = self._backgrounds(s.wallpaper)
        if s.wallpaper_from != s.wallpaper and s.wallpaper_mix < 1:
            b0, f0 = self._backgrounds(s.wallpaper_from)
            base, frosted = Image.blend(b0, base, s.wallpaper_mix), Image.blend(f0, frosted, s.wallpaper_mix)
        canvas = base.copy()
        self._draw_dock(canvas, frosted, s)
        self._draw_labels(canvas, frosted, s)
        overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        draw = ImageDraw.Draw(overlay)
        self._draw_header(draw, s)
        self._draw_progress(draw, s)
        self._draw_outro(overlay, draw, s)
        canvas.alpha_composite(overlay)
        return canvas.convert("RGB")

    def _dock_box(self, length: float) -> tuple[float, float, float, float]:
        g = self.geo
        a0, a1 = g.extent(length)
        t = g.thickness
        if g.horizontal:
            return a0, g.cross - t / 2, a1, g.cross + t / 2
        return g.cross - t / 2, a0, g.cross + t / 2, a1

    def _draw_dock(self, canvas, frosted, s: FrameState):
        g = self.geo
        if s.length > 0.02:
            box = self._dock_box(s.length)
            r = int(g.thickness * 0.34)
            self._glass(canvas, frosted, box, r, self.theme["plate"], self.theme["stroke"])
        dot = Image.new("RGBA", (8, 8), (0, 0, 0, 0))
        ImageDraw.Draw(dot).ellipse((0, 0, 7, 7), fill=self.theme["fg"] + (230,))
        for tile in s.tiles:
            if tile.alpha <= 0.01 or tile.scale <= 0.02:
                continue
            size = g.icon * tile.scale
            cx, cy = g.icon_center(tile.center, s.length)
            lift = g.icon * 0.16 * tile.highlight
            if g.horizontal:
                cy -= lift
            else:
                cx += lift
            img = _with_alpha(self._icon(tile.icon, size), tile.alpha)
            canvas.alpha_composite(img, (int(round(cx - img.width / 2)), int(round(cy - img.height / 2))))
            if tile.highlight > 0.02:
                d = _with_alpha(dot, tile.highlight)
                if g.horizontal:
                    canvas.alpha_composite(d, (int(cx - 4), int(g.cross + g.thickness / 2 - 11)))
                else:
                    canvas.alpha_composite(d, (int(g.cross - g.thickness / 2 + 4), int(cy - 4)))

    # labels ------------------------------------------------------------------
    def _label_parts(self, lab: Label):
        c = lab.change
        th = self.theme
        if c.kind == "replaced":
            return [("icon", lab.old_icon, True), ("text", "→", th["fg2"], 500), ("icon", lab.icon, False),
                    ("text", c.app.label, th["fg"], 600), ("text", f"replaces {c.old.label}", th["fg2"], 400)]
        if c.kind == "added":
            return [("badge", "+", th["green"]), ("icon", lab.icon, False), ("text", c.app.label, th["fg"], 600)]
        if c.kind == "removed":
            return [("badge", "−", th["red"]), ("icon", lab.icon, True), ("text", c.app.label, th["fg2"], 500)]
        return [("text", "↕", th["fg2"], 600), ("icon", lab.icon, False), ("text", c.app.label, th["fg"], 600)]

    def _pill_size(self, parts, h):
        fs, isz, gap = int(h * 0.42), int(h * 0.62), int(h * 0.22)
        w = h * 0.42 * 2 - gap
        for p in parts:
            w += (isz if p[0] == "icon" else int(h * 0.4) if p[0] == "badge" else font(fs, p[3]).getlength(p[1])) + gap
        return int(w), fs, isz, gap

    def _draw_pill(self, canvas, frosted, x, y, h, parts, alpha):
        w, fs, isz, gap = self._pill_size(parts, h)
        layer = Image.new("RGBA", (w + 80, h + 80), (0, 0, 0, 0))
        fr = frosted.crop((int(x) - 40, int(y) - 40, int(x) + w + 40, int(y) + h + 40))
        self._glass(layer, fr, (40, 40, 40 + w, 40 + h), h // 2, self.theme["pill"], self.theme["stroke"])
        d = ImageDraw.Draw(layer)
        cx = 40 + h * 0.42
        for p in parts:
            if p[0] == "badge":
                b = int(h * 0.4)
                layer.alpha_composite(self._badge(p[1], p[2], b), (int(cx), int(40 + (h - b) / 2)))
                cx += b + gap
            elif p[0] == "icon":
                ic = self._icon(p[1], isz, gray=p[2])
                layer.alpha_composite(_with_alpha(ic, 0.55) if p[2] else ic, (int(cx), int(40 + (h - isz) / 2)))
                cx += isz + gap
            else:
                d.text((cx, 40 + h / 2), p[1], font=font(fs, p[3]), fill=p[2], anchor="lm")
                cx += font(fs, p[3]).getlength(p[1]) + gap
        canvas.alpha_composite(_with_alpha(layer, alpha), (int(x) - 40, int(y) - 40))
        return w

    @lru_cache(maxsize=16)
    def _badge(self, sign: str, color: tuple, d: int) -> Image.Image:
        big = Image.new("RGBA", (d * SS, d * SS), (0, 0, 0, 0))
        dr = ImageDraw.Draw(big)
        dr.ellipse((0, 0, d * SS - 1, d * SS - 1), fill=color + (255,))
        c, arm, lw = d * SS / 2, d * SS * 0.26, max(2, int(d * SS * 0.13))
        dr.line((c - arm, c, c + arm, c), fill=(255, 255, 255, 255), width=lw)
        if sign == "+":
            dr.line((c, c - arm, c, c + arm), fill=(255, 255, 255, 255), width=lw)
        return big.resize((d, d), Image.LANCZOS)

    def _draw_labels(self, canvas, frosted, s: FrameState):
        from dock_timelapse.layout import place_labels

        labels = [l for l in s.labels if l.alpha > 0.01]
        if not labels:
            return
        g, F = self.geo, self.fmt
        h = 62 if g.horizontal else 58
        parts = [self._label_parts(l) for l in labels]
        widths = [self._pill_size(p, h)[0] for p in parts]
        line = ImageDraw.Draw(canvas)
        if g.horizontal:
            anchors = [g.icon_center(l.anchor, s.length)[0] for l in labels]
            placed = place_labels(list(zip(anchors, widths)), gap=16)
            top = g.cross - g.thickness / 2
            for l, p, w, pl, ax in zip(labels, parts, widths, placed, anchors):
                x = min(max(pl.start, F.margin * 0.5), F.width - F.margin * 0.5 - w)
                y = top - 70 - h - pl.row * (h + 18) + 16 * (1 - l.alpha)
                a = int(120 * l.alpha)
                line.line((ax, y + h, ax, top - 8), fill=self.theme["fg"] + (a,), width=2)
                self._draw_pill(canvas, frosted, x, y, h, p, l.alpha)
        else:
            anchors = [g.icon_center(l.anchor, s.length)[1] for l in labels]
            order = sorted(range(len(labels)), key=lambda k: anchors[k])
            ys, prev_end = {}, -1e9
            for k in order:  # nudge down to avoid overlaps
                y = max(anchors[k] - h / 2, prev_end + 12)
                ys[k], prev_end = y, y + h
            x0 = g.cross + g.thickness / 2
            for k, (l, p) in enumerate(zip(labels, parts)):
                x = x0 + 56 - 16 * (1 - l.alpha)
                a = int(120 * l.alpha)
                line.line((x0 + 10, anchors[k], x0 + 30, anchors[k], x0 + 44, ys[k] + h / 2, x, ys[k] + h / 2),
                          fill=self.theme["fg"] + (a,), width=2, joint="curve")
                self._draw_pill(canvas, frosted, x, ys[k], h, p, l.alpha)

    # header / progress / outro -------------------------------------------------
    def _draw_header(self, draw, s: FrameState):
        F = self.fmt
        land = F.width > F.height
        x, y = (F.margin, 96) if land else (F.margin, 150)
        a = (1 - s.title) * (1 - s.outro)
        if a > 0.01:
            self._text(draw, (x, y), "MY DOCK", 24 if land else 26, 600, self.theme["fg2"], tracking=0.14, alpha=a)
            date = s.date.strftime("%-d %B %Y")
            self._text(draw, (x, y + 30), date, 88 if land else 92, 650, alpha=a)
            day = int(round(s.day))
            n = sum(1 for t in s.tiles if t.slot > 0.5)
            sub = f"Day {day}   ·   {n} apps"
            self._text(draw, (x, y + (140 if land else 146)), sub, 40 if land else 42, 450, self.theme["fg2"], alpha=a)
        if s.title > 0.01:
            cy = F.height * (0.3 if land else 0.14)
            k = s.title
            self._text(draw, (F.width / 2, cy), "My Dock", 120 if land else 128, 700, anchor="ms", alpha=k)
            span = f"{self._first.strftime('%B %Y')} – {self._last.strftime('%B %Y')}"
            self._text(draw, (F.width / 2, cy + 64), span, 40, 450, self.theme["fg2"], anchor="ms", alpha=k)

    def _draw_progress(self, draw, s: FrameState):
        F = self.fmt
        land = F.width > F.height
        y = F.height - (86 if land else 104)
        x0, x1 = F.margin, F.width - F.margin
        track = self.theme["track"]
        draw.rounded_rectangle((x0, y - 2, x1, y + 2), 2, fill=track)
        px = x0 + (x1 - x0) * clamp01(s.progress)
        draw.rounded_rectangle((x0, y - 2, max(x0 + 4, px), y + 2), 2, fill=self.theme["fg"] + (230,))
        span = max(1, self.tl.span_days)
        for sc in self.tl.scenes:
            tx = x0 + (x1 - x0) * (sc.day - self.tl.scenes[0].day) / span
            passed = tx <= px + 0.5
            r = 5
            draw.ellipse((tx - r, y - r, tx + r, y + r), fill=self.theme["fg"] + (255 if passed else 90,))
        draw.ellipse((px - 9, y - 9, px + 9, y + 9), fill=self.theme["fg"] + (255,))
        fs = 24 if land else 26
        self._text(draw, (x0, y + 22), self._first.strftime("%-d %b %Y"), fs, 500, self.theme["fg2"], anchor="lt")
        self._text(draw, (x1, y + 22), self._last.strftime("%-d %b %Y"), fs, 500, self.theme["fg2"], anchor="rt")

    def _draw_outro(self, overlay, draw, s: FrameState):
        if s.outro <= 0.01:
            return
        from dock_timelapse.timeline import summarize

        sm: Summary = summarize(self.tl.scenes)
        F, g, a = self.fmt, self.geo, s.outro
        land = F.width > F.height
        rise = 24 * (1 - ease_out(a))
        if land:
            cx, y = F.width / 2, F.height * 0.25 + rise
            self._text(draw, (cx, y), f"{sm.days} days.  {sm.n_changes} changes.", 84, 700, anchor="ms", alpha=a)
            lines = self._summary_lines(sm)
            for k, line in enumerate(lines):
                self._text(draw, (cx, y + 66 + k * 46), line, 34, 450, self.theme["fg2"], anchor="ms", alpha=a)
        else:
            x, y = F.margin, 150 + rise
            self._text(draw, (x, y), "MY DOCK", 26, 600, self.theme["fg2"], tracking=0.14, alpha=a)
            self._text(draw, (x, y + 30), f"{sm.days} days.", 92, 700, alpha=a)
            self._text(draw, (x, y + 130), f"{sm.n_changes} changes.", 92, 700, alpha=a)
            x = g.cross + g.thickness / 2 + 60
            for k, line in enumerate(self._summary_lines(sm, wrap=True)):
                self._text(draw, (x, F.height * 0.42 + k * 50 + rise), line, 36, 600 if line.endswith(":") else 450,
                           self.theme["fg" if line.endswith(":") else "fg2"], alpha=a)

    @staticmethod
    def _summary_lines(sm: Summary, wrap: bool = False) -> list[str]:
        def names(apps, n=4):
            ns = [x.label for x in apps]
            return ", ".join(ns[:n]) + (f" +{len(ns) - n}" if len(ns) > n else "")

        lines = []
        if sm.arrived:
            lines += (["Arrived:", names(sm.arrived, 3)] if wrap else [f"Arrived  {names(sm.arrived)}"])
        if sm.left:
            lines += (["Left:", names(sm.left, 3)] if wrap else [f"Left  {names(sm.left)}"])
        lines.append(f"{len(sm.stayed)} apps there since day one")
        return lines
