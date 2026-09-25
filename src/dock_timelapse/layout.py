"""Screen geometry for the two video formats (pure, no drawing)."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Format:
    name: str
    width: int
    height: int
    margin: int


LANDSCAPE = Format("landscape", 1920, 1080, 120)
PORTRAIT = Format("portrait", 1080, 1920, 90)
FORMATS = {f.name: f for f in (LANDSCAPE, PORTRAIT)}

SLOT_PER_ICON = 1.22
PAD_SLOTS = 0.35  # dock padding at each end, in slots


@dataclass(frozen=True)
class DockGeometry:
    fmt: Format
    horizontal: bool
    slot: float
    icon: int
    pad: float
    cross: float  # dock center on the axis perpendicular to the dock
    region: tuple[float, float]  # extent along the dock axis the dock is centered in

    @property
    def thickness(self) -> float:
        return self.icon + 2 * self.pad * 0.9

    def extent(self, length: float) -> tuple[float, float]:
        mid = (self.region[0] + self.region[1]) / 2
        span = length * self.slot + 2 * self.pad
        return mid - span / 2, mid + span / 2

    def along(self, pos: float, length: float) -> float:
        return self.extent(length)[0] + self.pad + pos * self.slot

    def icon_center(self, pos: float, length: float) -> tuple[float, float]:
        a = self.along(pos, length)
        return (a, self.cross) if self.horizontal else (self.cross, a)


def dock_geometry(fmt: Format, max_apps: int) -> DockGeometry:
    n = max(1, max_apps) + 2 * PAD_SLOTS
    if fmt.width >= fmt.height:
        region = (fmt.margin, fmt.width - fmt.margin)
        slot = min(134.0, (region[1] - region[0]) / n)
        icon = int(slot / SLOT_PER_ICON)
        return DockGeometry(fmt, True, slot, icon, PAD_SLOTS * slot, fmt.height * 0.64, region)
    region = (fmt.height * 0.215, fmt.height * 0.905)
    slot = min(120.0, (region[1] - region[0]) / n)
    icon = int(slot / SLOT_PER_ICON)
    pad = PAD_SLOTS * slot
    return DockGeometry(fmt, False, slot, icon, pad, fmt.margin + (icon + 2 * pad * 0.9) / 2, region)


@dataclass(frozen=True)
class Placement:
    start: float
    row: int


def place_labels(items: list[tuple[float, float]], gap: float) -> list[Placement]:
    """Greedy 1-D packing: each label as close to its anchor as possible, extra rows on collision."""
    order = sorted(range(len(items)), key=lambda k: items[k][0])
    row_ends: list[float] = []
    out: dict[int, Placement] = {}
    for k in order:
        center, width = items[k]
        start = center - width / 2
        for r, end in enumerate(row_ends):
            if end + gap <= start:
                row_ends[r] = start + width
                out[k] = Placement(start, r)
                break
        else:
            row_ends.append(start + width)
            out[k] = Placement(start, len(row_ends) - 1)
    return [out[k] for k in range(len(items))]
