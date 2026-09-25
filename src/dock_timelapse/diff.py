"""Compute human-meaningful changes between two dock states."""

from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
from typing import Literal

from dock_timelapse.dockdata import DockApp

Kind = Literal["added", "removed", "replaced", "moved"]


@dataclass(frozen=True)
class Change:
    kind: Kind
    app: DockApp
    old: DockApp | None = None

    def describe(self) -> str:
        if self.kind == "replaced":
            return f"{self.old.label} → {self.app.label}"
        return {"added": "+ ", "removed": "− ", "moved": "↕ "}[self.kind] + self.app.label

    def to_dict(self) -> dict:
        return {"kind": self.kind, "app": self.app.to_dict(), "old": self.old.to_dict() if self.old else None}


def diff_docks(old: list[DockApp], new: list[DockApp]) -> list[Change]:
    old_keys = [a.key for a in old]
    new_keys = [a.key for a in new]
    removed: list[DockApp] = []
    added: list[DockApp] = []
    pairs: list[tuple[DockApp, DockApp]] = []
    for op, i1, i2, j1, j2 in SequenceMatcher(a=old_keys, b=new_keys, autojunk=False).get_opcodes():
        if op == "delete":
            removed += old[i1:i2]
        elif op == "insert":
            added += new[j1:j2]
        elif op == "replace":
            olds, news = old[i1:i2], new[j1:j2]
            n = min(len(olds), len(news))
            pairs += list(zip(olds[:n], news[:n]))
            removed += olds[n:]
            added += news[n:]

    # An app that disappears in one place and reappears elsewhere just moved.
    new_set, old_set = set(new_keys), set(old_keys)
    moved_keys = {a.key for a in removed if a.key in new_set} | {a.key for a in added if a.key in old_set}
    changes: list[Change] = []
    for o, n in pairs:
        if o.key in new_set or n.key in old_set:
            for a in (o, n):
                if a.key in new_set and a.key in old_set:
                    moved_keys.add(a.key)
            if o.key not in new_set:
                removed.append(o)
            if n.key not in old_set:
                added.append(n)
        else:
            changes.append(Change("replaced", n, o))
    changes += [Change("added", a) for a in added if a.key not in moved_keys]
    changes += [Change("removed", a) for a in removed if a.key not in moved_keys]
    changes += [Change("moved", a) for a in new if a.key in moved_keys]
    return changes
