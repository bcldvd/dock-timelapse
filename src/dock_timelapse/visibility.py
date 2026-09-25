"""Decide whether the Dock is actually on screen right now (worth a screenshot)."""

from __future__ import annotations


def dock_visibility(
    prefs: dict,
    windows: list[dict],
    session: dict,
    screen_size: tuple[int, int],
    display_asleep: bool = False,
) -> tuple[bool, str]:
    if display_asleep:
        return False, "display-asleep"
    if session.get("CGSSessionScreenIsLocked"):
        return False, "locked"
    if session.get("kCGSSessionOnConsoleKey") is False:
        return False, "not-on-console"
    if prefs.get("autohide"):
        return False, "autohide"
    sw, sh = screen_size
    for w in windows:
        if w.get("kCGWindowLayer", 0) != 0:
            continue
        b = w.get("kCGWindowBounds", {})
        if b.get("X", 1) <= 0 and b.get("Y", 1) <= 0 and b.get("Width", 0) >= sw and b.get("Height", 0) >= sh:
            return False, f"fullscreen:{w.get('kCGWindowOwnerName', '?')}"
    return True, "visible"
