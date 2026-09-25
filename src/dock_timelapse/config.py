"""Per-data-dir settings (config.json)."""

from __future__ import annotations

import json
from pathlib import Path

DEFAULTS = {"screenshots": False}


def load(data: Path) -> dict:
    p = data / "config.json"
    cfg = dict(DEFAULTS)
    if p.exists():
        cfg.update(json.loads(p.read_text()))
    return cfg


def save(data: Path, **values) -> dict:
    data.mkdir(parents=True, exist_ok=True)
    cfg = load(data) | values
    (data / "config.json").write_text(json.dumps(cfg, indent=2))
    return cfg
