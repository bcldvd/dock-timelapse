"""Pure animation model: snapshots -> scenes -> the state of every frame at time t."""

from __future__ import annotations

import datetime as dt
import math
from dataclasses import dataclass, field
from difflib import SequenceMatcher

from dock_timelapse.diff import Change
from dock_timelapse.dockdata import DockApp
from dock_timelapse.store import Snapshot


# -- easing --------------------------------------------------------------
def clamp01(x: float) -> float:
    return 0.0 if x < 0 else 1.0 if x > 1 else x


def ease_in_out(x: float) -> float:
    x = clamp01(x)
    return 4 * x**3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def ease_out(x: float) -> float:
    return 1 - (1 - clamp01(x)) ** 3


def spring(x: float) -> float:
    """Critically-underdamped spring: overshoots a little, settles at exactly 1."""
    x = clamp01(x)
    if x >= 1:
        return 1.0
    return 1 - math.exp(-6.5 * x) * math.cos(10.5 * x)


def _grow(x: float) -> tuple[float, float]:
    """(slot, scale) of an appearing icon: room opens first, the icon springs in without overlapping."""
    slot = ease_out(x)
    return slot, min(spring(x), slot * 1.1)


# -- model ---------------------------------------------------------------
@dataclass
class Scene:
    date: dt.date
    day: int
    apps: list[DockApp]
    changes: list[Change]
    icons: dict[str, str] = field(default_factory=dict)
    wallpaper: str | None = None
    screenshot: str | None = None


@dataclass
class Tile:
    app: DockApp
    pos: float  # leading edge, in icon slots from the start of the dock
    slot: float  # 0..1 how much room it takes
    scale: float  # icon drawing scale (can overshoot)
    alpha: float
    icon: str | None = None
    highlight: float = 0.0  # 0..1, app involved in the current scene's changes

    @property
    def center(self) -> float:
        return self.pos + self.slot / 2


@dataclass
class Label:
    change: Change
    alpha: float
    anchor: float  # center position (slots) of the tile it refers to
    icon: str | None = None
    old_icon: str | None = None


@dataclass
class FrameState:
    t: float
    scene_index: int
    phase: str  # intro | hold | transition | outro
    p: float  # progress within the phase
    tiles: list[Tile]
    length: float
    day: float
    date: dt.date
    labels: list[Label]
    progress: float
    outro: float
    title: float  # opacity of the intro title
    wallpaper: str | None
    wallpaper_from: str | None
    wallpaper_mix: float


@dataclass(frozen=True)
class Timing:
    intro: float = 1.6
    transition: float = 0.9
    hold_base: float = 1.4
    hold_per_change: float = 0.35
    outro: float = 3.0


def build_scenes(snapshots: list[Snapshot]) -> list[Scene]:
    if not snapshots:
        return []
    first = snapshots[0].day
    return [
        Scene(
            date=s.day,
            day=(s.day - first).days + 1,
            apps=s.apps,
            changes=s.changes,
            icons=s.icons,
            wallpaper=s.wallpaper,
            screenshot=s.screenshot,
        )
        for s in snapshots
    ]


class Timeline:
    def __init__(self, scenes: list[Scene], timing: Timing = Timing()):
        if not scenes:
            raise ValueError("no scenes to animate")
        self.scenes = scenes
        self.timing = timing
        self.scene_starts: list[float] = []
        t = 0.0
        for i, sc in enumerate(scenes):
            self.scene_starts.append(t)
            t += timing.intro if i == 0 else timing.transition
            t += self.hold(i)
        self.outro_start = t
        self.duration = t + timing.outro
        self.span_days = max(1, scenes[-1].day - scenes[0].day)
        self._icons: dict[str, str] = {}
        for sc in scenes:
            for k, v in sc.icons.items():
                self._icons.setdefault(k, v)

    def hold(self, i: int) -> float:
        n = 0 if i == 0 else len(self.scenes[i].changes)
        return self.timing.hold_base + self.timing.hold_per_change * n

    def _icon(self, scene: Scene, app: DockApp) -> str | None:
        return scene.icons.get(app.key) or self._icons.get(app.key)

    def _locate(self, t: float) -> tuple[int, str, float]:
        t = min(max(t, 0.0), self.duration)
        if t >= self.outro_start:
            return len(self.scenes) - 1, "outro", clamp01((t - self.outro_start) / self.timing.outro)
        i = max(k for k, s in enumerate(self.scene_starts) if s <= t)
        local = t - self.scene_starts[i]
        lead = self.timing.intro if i == 0 else self.timing.transition
        if local < lead:
            return i, ("intro" if i == 0 else "transition"), local / lead
        return i, "hold", clamp01((local - lead) / self.hold(i))

    def _tiles(self, i: int, phase: str, p: float) -> list[Tile]:
        new = self.scenes[i]
        changed = {c.app.key for c in new.changes} if i > 0 else set()
        hl = 0.0
        if i > 0 and phase in ("transition", "hold"):
            hl = ease_out((p - 0.4) / 0.6) if phase == "transition" else 1 - ease_in_out((p - 0.6) / 0.4)

        if phase == "intro":  # dock builds up icon by icon
            n = len(new.apps)
            tiles = []
            for k, app in enumerate(new.apps):
                start = 0.1 + 0.55 * (k / max(1, n - 1))
                x = (p - start) / 0.35
                tiles.append(Tile(app, 0, *_grow(x), clamp01(x * 2), self._icon(new, app)))
            return self._layout(tiles)

        if phase != "transition":
            return self._layout([
                Tile(a, 0, 1, 1, 1, self._icon(new, a), hl if a.key in changed else 0) for a in new.apps
            ])

        old = self.scenes[i - 1]
        out_x = p / 0.6
        in_x = (p - 0.3) / 0.7
        tiles: list[Tile] = []
        ok, nk = [a.key for a in old.apps], [a.key for a in new.apps]
        for op, i1, i2, j1, j2 in SequenceMatcher(a=ok, b=nk, autojunk=False).get_opcodes():
            if op == "equal":
                tiles += [Tile(a, 0, 1, 1, 1, self._icon(new, a), hl if a.key in changed else 0) for a in new.apps[j1:j2]]
                continue
            for a in old.apps[i1:i2]:
                s = 1 - ease_in_out(out_x)
                tiles.append(Tile(a, 0, s, s, clamp01(s * 1.5), self._icon(old, a)))
            for a in new.apps[j1:j2]:
                tiles.append(Tile(a, 0, *_grow(in_x), clamp01(in_x * 2), self._icon(new, a), hl))
        return self._layout(tiles)

    @staticmethod
    def _layout(tiles: list[Tile]) -> list[Tile]:
        x = 0.0
        for tile in tiles:
            tile.pos = x
            x += tile.slot
        return tiles

    def _labels(self, i: int, phase: str, p: float, tiles: list[Tile]) -> list[Label]:
        if i == 0 and phase != "transition":
            return []
        labels: list[Label] = []

        def anchor_for(change: Change, scene_index: int) -> float:
            # Prefer the live tile of the (new) app; removed apps point to the gap they left.
            cands = [t for t in tiles if t.app.key == change.app.key]
            if change.kind == "removed" and not cands:
                old, new = self.scenes[scene_index - 1].apps, {a.key for a in self.scenes[scene_index].apps}
                k = next(n for n, a in enumerate(old) if a.key == change.app.key)
                return float(sum(1 for a in old[:k] if a.key in new))
            if change.kind != "removed":
                cands = [t for t in cands if t.alpha > 0 or t.slot > 0] or cands
                cands = cands[-1:]
            return cands[0].center if cands else 0.0

        def add(k: int, alpha: float):
            if alpha <= 0:
                return
            scene = self.scenes[k]
            for c in scene.changes:
                labels.append(Label(c, alpha, anchor_for(c, k), self._icon(scene, c.app),
                                    self._icon(scene, c.old) if c.old else None))

        if phase == "transition":
            if i > 1:
                add(i - 1, 1 - ease_in_out(p / 0.35))
            add(i, ease_out((p - 0.45) / 0.55))
        elif phase == "hold":
            add(i, 1.0)
        elif phase == "outro" and i > 0:
            add(i, 1 - ease_in_out(p / 0.25))
        return labels

    def at(self, t: float) -> FrameState:
        i, phase, p = self._locate(t)
        sc = self.scenes[i]
        tiles = self._tiles(i, phase, p)
        if phase == "transition":
            prev = self.scenes[i - 1]
            e = ease_in_out(p)
            day = prev.day + (sc.day - prev.day) * e
            wp_from, mix = prev.wallpaper, e
        else:
            day, wp_from, mix = sc.day, sc.wallpaper, 1.0
        date = self.scenes[0].date + dt.timedelta(days=round(day) - 1)
        title = 1.0
        if i > 0 or phase == "outro":
            title = 1 - ease_in_out(p / 0.5) if (i == 1 and phase == "transition") else 0.0
        if len(self.scenes) == 1 and phase == "outro":
            title = 1 - ease_in_out(p / 0.3)
        outro = ease_in_out(p / 0.5) if phase == "outro" else 0.0
        return FrameState(
            t=t, scene_index=i, phase=phase, p=p, tiles=tiles,
            length=sum(tile.slot for tile in tiles),
            day=day, date=date,
            labels=self._labels(i, phase, p, tiles),
            progress=(day - self.scenes[0].day) / self.span_days if len(self.scenes) > 1 else 1.0,
            outro=outro, title=title,
            wallpaper=sc.wallpaper, wallpaper_from=wp_from, wallpaper_mix=mix,
        )


@dataclass
class Summary:
    days: int
    n_changes: int
    arrived: list[DockApp]  # in the final dock, not in the first one
    left: list[DockApp]  # in the first dock, gone at the end
    stayed: list[DockApp]  # there from day one to the end
    final_count: int


def summarize(scenes: list[Scene]) -> Summary:
    first, last = scenes[0].apps, scenes[-1].apps
    fk, lk = {a.key for a in first}, {a.key for a in last}
    return Summary(
        days=scenes[-1].day,
        n_changes=sum(len(s.changes) for s in scenes[1:]),
        arrived=[a for a in last if a.key not in fk],
        left=[a for a in first if a.key not in lk],
        stayed=[a for a in last if a.key in fk],
        final_count=len(last),
    )
