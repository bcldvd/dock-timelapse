from dock_timelapse.visibility import dock_visibility

SCREEN = (1512, 982)


def win(owner, x, y, w, h, layer=0):
    return {"kCGWindowOwnerName": owner, "kCGWindowLayer": layer,
            "kCGWindowBounds": {"X": x, "Y": y, "Width": w, "Height": h}}


def test_visible_normally():
    assert dock_visibility({"autohide": False}, [win("Arc", 70, 33, 1400, 900)], {}, SCREEN) == (True, "visible")


def test_autohide_means_hidden():
    assert dock_visibility({"autohide": True}, [], {}, SCREEN) == (False, "autohide")


def test_locked_screen():
    assert dock_visibility({}, [], {"CGSSessionScreenIsLocked": True}, SCREEN) == (False, "locked")


def test_not_on_console_eg_other_user():
    assert dock_visibility({}, [], {"kCGSSessionOnConsoleKey": False}, SCREEN) == (False, "not-on-console")


def test_fullscreen_app_hides_dock():
    assert dock_visibility({}, [win("Keynote", 0, 0, 1512, 982)], {}, SCREEN) == (False, "fullscreen:Keynote")


def test_fullscreen_windows_of_system_layers_are_ignored():
    windows = [win("Dock", 0, 0, 1512, 982, layer=20), win("Window Server", 0, 0, 1512, 982, layer=25)]
    assert dock_visibility({}, windows, {}, SCREEN) == (True, "visible")


def test_display_asleep():
    assert dock_visibility({}, [], {}, SCREEN, display_asleep=True) == (False, "display-asleep")
