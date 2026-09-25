import datetime as dt
from pathlib import Path

from dock_timelapse.poc import build_poc
from dock_timelapse.render import Renderer
from dock_timelapse.layout import LANDSCAPE, PORTRAIT
from dock_timelapse.timeline import Timeline, build_scenes

from PIL import Image


def _tile(label, bid, path):
    return {"tile-type": "file-tile", "tile-data": {"file-label": label, "bundle-identifier": bid,
            "file-data": {"_CFURLString": f"file://{path}/"}}}


TODAY_DOCK = [
    ("Arc", "company.thebrowser.Browser"), ("Google Chrome", "com.google.Chrome"), ("Calendrier", "com.apple.iCal"),
    ("Slack", "com.tinyspeck.slackmacgap"), ("WhatsApp", "net.whatsapp.WhatsApp"), ("Linear", "com.linear"),
    ("Cursor", "com.todesktop.230313mzl4w4u92"), ("cmux", "com.cmuxterm.app"), ("Superset", "com.superset.desktop"),
    ("Claude", "com.anthropic.claudefordesktop"), ("Réglages Système", "com.apple.systempreferences"),
]


class FakeMac:
    def dock_prefs(self):
        return {"persistent-apps": [_tile(l, b, f"/Applications/{l}.app") for l, b in TODAY_DOCK]}

    def icon_png(self, app):
        import io
        buf = io.BytesIO()
        Image.new("RGBA", (64, 64), (hash(app.key) % 255, 120, 200, 255)).save(buf, "PNG")
        return buf.getvalue()

    def wallpaper(self):
        import io
        buf = io.BytesIO()
        Image.new("RGB", (320, 200), (30, 120, 60)).save(buf, "JPEG")
        return Path("grass.jpg"), buf.getvalue()


def test_poc_history_is_seven_snapshots_ending_with_todays_dock(tmp_path):
    store = build_poc(tmp_path, FakeMac(), today=dt.date(2026, 9, 25))
    snaps = store.snapshots()
    assert len(snaps) == 7
    assert snaps[-1].date == "2026-09-25"
    assert [a.bundle_id for a in snaps[-1].apps] == [b for _, b in TODAY_DOCK]
    assert all(s.screenshot for s in snaps)
    assert all(s.changes for s in snaps)


def test_frames_render_at_format_size_and_are_deterministic(tmp_path):
    store = build_poc(tmp_path, FakeMac(), today=dt.date(2026, 9, 25))
    tl = Timeline(build_scenes(store.snapshots()))
    for fmt in (LANDSCAPE, PORTRAIT):
        for bg in ("wallpaper", "white"):
            r = Renderer(tmp_path, fmt, tl, bg)
            t = tl.scene_starts[2] + 0.5
            a, b = r.frame(tl.at(t)), r.frame(tl.at(t))
            assert a.size == (fmt.width, fmt.height)
            assert a.tobytes() == b.tobytes()
