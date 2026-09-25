"""On-disk history: one snapshot per day on which the dock changed.

Layout of the data dir:
    snapshots.json   ordered list of snapshots (the source of truth for rendering)
    checks.json      every day the dock was inspected (proves "unchanged" days)
    shots/           cropped dock screenshots, one per snapshot
    icons/           app icons as PNG, content-addressed so icon redesigns are kept
    wallpapers/      desktop wallpapers seen over time
"""

from __future__ import annotations

import datetime as dt
import json
import shutil
from dataclasses import dataclass, field
from pathlib import Path

from dock_timelapse.diff import Change, diff_docks
from dock_timelapse.dockdata import DockApp


@dataclass
class Snapshot:
    date: str
    captured_at: str
    apps: list[DockApp]
    changes: list[Change] = field(default_factory=list)
    screenshot: str | None = None
    icons: dict[str, str] = field(default_factory=dict)
    wallpaper: str | None = None

    @property
    def day(self) -> dt.date:
        return dt.date.fromisoformat(self.date)

    def to_dict(self) -> dict:
        return {
            "date": self.date,
            "captured_at": self.captured_at,
            "apps": [a.to_dict() for a in self.apps],
            "changes": [c.to_dict() for c in self.changes],
            "screenshot": self.screenshot,
            "icons": self.icons,
            "wallpaper": self.wallpaper,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Snapshot":
        def change(c):
            return Change(c["kind"], DockApp.from_dict(c["app"]), DockApp.from_dict(c["old"]) if c.get("old") else None)

        return cls(
            date=d["date"],
            captured_at=d["captured_at"],
            apps=[DockApp.from_dict(a) for a in d["apps"]],
            changes=[change(c) for c in d.get("changes", [])],
            screenshot=d.get("screenshot"),
            icons=d.get("icons", {}),
            wallpaper=d.get("wallpaper"),
        )


class Store:
    def __init__(self, root: Path | str):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self._snap_file = self.root / "snapshots.json"
        self._checks_file = self.root / "checks.json"

    # -- persistence -----------------------------------------------------
    def snapshots(self) -> list[Snapshot]:
        if not self._snap_file.exists():
            return []
        return [Snapshot.from_dict(d) for d in json.loads(self._snap_file.read_text())]

    def _save(self, snaps: list[Snapshot]) -> None:
        tmp = self._snap_file.with_suffix(".tmp")
        tmp.write_text(json.dumps([s.to_dict() for s in snaps], indent=2, ensure_ascii=False))
        tmp.replace(self._snap_file)

    def _checks(self) -> list[str]:
        return json.loads(self._checks_file.read_text()) if self._checks_file.exists() else []

    def _mark_checked(self, day: dt.date) -> None:
        checks = self._checks()
        if day.isoformat() not in checks:
            checks.append(day.isoformat())
            self._checks_file.write_text(json.dumps(checks, indent=0))

    def checked_on(self, day: dt.date) -> bool:
        return day.isoformat() in self._checks()

    # -- behaviour -------------------------------------------------------
    def observe(
        self,
        apps: list[DockApp],
        now: dt.datetime,
        icons: dict[str, str] | None = None,
        wallpaper: str | None = None,
    ) -> Snapshot | None:
        """Record what the dock shows now. Returns the new/updated snapshot, or None if unchanged."""
        today = now.date().isoformat()
        snaps = self.snapshots()
        self._mark_checked(now.date())
        if snaps and snaps[-1].apps == apps:
            return None
        # A same-day change folds into today's snapshot (diffed against the previous day).
        if snaps and snaps[-1].date == today:
            snaps.pop()
            if snaps and snaps[-1].apps == apps:  # reverted to yesterday's state
                self._save(snaps)
                return None
        previous = snaps[-1].apps if snaps else []
        snap = Snapshot(
            date=today,
            captured_at=now.isoformat(timespec="seconds"),
            apps=list(apps),
            changes=diff_docks(previous, apps),
            icons=dict(icons or {}),
            wallpaper=wallpaper,
        )
        snaps.append(snap)
        self._save(snaps)
        return snap

    def pending_screenshot(self) -> Snapshot | None:
        snaps = self.snapshots()
        return snaps[-1] if snaps and snaps[-1].screenshot is None else None

    def attach_screenshot(self, image: Path) -> str:
        snaps = self.snapshots()
        snap = snaps[-1]
        rel = f"shots/{snap.date}{image.suffix}"
        (self.root / "shots").mkdir(exist_ok=True)
        shutil.copyfile(image, self.root / rel)
        snap.screenshot = rel
        self._save(snaps)
        return rel

    def done_for(self, day: dt.date) -> bool:
        return self.checked_on(day) and self.pending_screenshot() is None
