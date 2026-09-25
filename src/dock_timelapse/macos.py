"""Real macOS side effects. Kept thin: all decisions live in capture/visibility."""

from __future__ import annotations

import subprocess
from pathlib import Path

from dock_timelapse.capture import dock_crop_box
from dock_timelapse.dockdata import DockApp, read_dock_prefs
from dock_timelapse.visibility import dock_visibility

DEFAULT_TILESIZE = 48  # macOS default when the Dock size was never changed


class RealMac:
    def dock_prefs(self) -> dict:
        return read_dock_prefs()

    def _screen(self):
        import Quartz

        display = Quartz.CGMainDisplayID()
        bounds = Quartz.CGDisplayBounds(display)
        px = (Quartz.CGDisplayPixelsWide(display), Quartz.CGDisplayPixelsHigh(display))
        mode = Quartz.CGDisplayCopyDisplayMode(display)
        scale = Quartz.CGDisplayModeGetPixelWidth(mode) / Quartz.CGDisplayModeGetWidth(mode)
        return display, (int(bounds.size.width), int(bounds.size.height)), scale

    def visibility(self, prefs: dict) -> tuple[bool, str]:
        import Quartz

        display, size, _ = self._screen()
        windows = Quartz.CGWindowListCopyWindowInfo(
            Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID
        ) or []
        session = dict(Quartz.CGSessionCopyCurrentDictionary() or {})
        windows = [dict(w, kCGWindowBounds=dict(w.get("kCGWindowBounds", {}))) for w in windows]
        return dock_visibility(prefs, windows, session, size, display_asleep=bool(Quartz.CGDisplayIsAsleep(display)))

    def icon_png(self, app: DockApp, size: int = 512) -> bytes | None:
        import AppKit

        if not app.path or not Path(app.path).exists():
            return None
        # Resolve symlinks (e.g. /Applications/Safari.app) or macOS adds an alias arrow badge.
        image = AppKit.NSWorkspace.sharedWorkspace().iconForFile_(str(Path(app.path).resolve()))
        rep = AppKit.NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
            None, size, size, 8, 4, True, False, AppKit.NSDeviceRGBColorSpace, 0, 0
        )
        AppKit.NSGraphicsContext.saveGraphicsState()
        AppKit.NSGraphicsContext.setCurrentContext_(AppKit.NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))
        image.drawInRect_fromRect_operation_fraction_(((0, 0), (size, size)), ((0, 0), (0, 0)), AppKit.NSCompositingOperationCopy, 1.0)
        AppKit.NSGraphicsContext.restoreGraphicsState()
        data = rep.representationUsingType_properties_(AppKit.NSBitmapImageFileTypePNG, {})
        return bytes(data) if data else None

    def wallpaper(self) -> tuple[Path, bytes] | None:
        try:
            import AppKit

            url = AppKit.NSWorkspace.sharedWorkspace().desktopImageURLForScreen_(AppKit.NSScreen.mainScreen())
            path = Path(url.path()) if url else None
        except Exception:
            path = None
        if path is None or not path.is_file():
            out = subprocess.run(
                ["osascript", "-e", 'tell application "System Events" to get picture of current desktop'],
                capture_output=True, text=True,
            ).stdout.strip()
            path = Path(out) if out else None
        if path is None or not path.is_file():
            return None
        if path.suffix.lower() in {".heic", ".tiff", ".tif"}:  # normalise to jpg for Pillow
            tmp = Path("/tmp/dock-timelapse-wallpaper.jpg")
            subprocess.run(["sips", "-s", "format", "jpeg", str(path), "--out", str(tmp)], capture_output=True)
            return (path.with_suffix(".jpg"), tmp.read_bytes()) if tmp.exists() else None
        return path, path.read_bytes()

    def dock_screenshot(self, prefs: dict, out: Path) -> Path | None:
        from PIL import Image

        full = out.with_name("full.png")
        r = subprocess.run(["/usr/sbin/screencapture", "-x", "-m", "-t", "png", str(full)], capture_output=True)
        if r.returncode != 0 or not full.exists():
            return None
        _, _, scale = self._screen()
        img = Image.open(full)
        box = dock_crop_box(prefs.get("orientation", "bottom"), img.size, scale, int(prefs.get("tilesize", DEFAULT_TILESIZE)))
        img.crop(box).save(out)
        return out
