"""Read and parse the Dock's own preferences (the ground truth of what it shows)."""

from __future__ import annotations

import plistlib
import subprocess
from dataclasses import asdict, dataclass
from urllib.parse import unquote, urlparse

# Everything after the Settings app is ignored (running apps, junk we don't care about).
SETTINGS_BUNDLE_IDS = {"com.apple.systempreferences", "com.apple.SystemSettings"}


@dataclass(frozen=True)
class DockApp:
    label: str
    bundle_id: str | None
    path: str

    @property
    def key(self) -> str:
        return self.bundle_id or self.path

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "DockApp":
        return cls(label=d["label"], bundle_id=d.get("bundle_id"), path=d["path"])


def _url_to_path(url: str | None) -> str:
    if not url:
        return ""
    path = unquote(urlparse(url).path)
    return path.rstrip("/") or path


def parse_dock_prefs(prefs: dict) -> list[DockApp]:
    apps: list[DockApp] = []
    for t in prefs.get("persistent-apps", []):
        if t.get("tile-type") != "file-tile":
            continue
        td = t.get("tile-data", {})
        app = DockApp(
            label=td.get("file-label") or "",
            bundle_id=td.get("bundle-identifier"),
            path=_url_to_path((td.get("file-data") or {}).get("_CFURLString")),
        )
        apps.append(app)
        if app.bundle_id in SETTINGS_BUNDLE_IDS:
            break
    return apps


def read_dock_prefs() -> dict:
    raw = subprocess.run(
        ["/usr/bin/defaults", "export", "com.apple.dock", "-"], check=True, capture_output=True
    ).stdout
    return plistlib.loads(raw)
