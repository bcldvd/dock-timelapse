from dock_timelapse.layout import LANDSCAPE, PORTRAIT, dock_geometry, place_labels


def test_icons_fit_on_screen_for_max_apps():
    for fmt in (LANDSCAPE, PORTRAIT):
        g = dock_geometry(fmt, max_apps=25)
        span = g.slot * 25 + 2 * g.pad
        assert span <= (fmt.width if g.horizontal else fmt.height) - 2 * fmt.margin


def test_landscape_is_horizontal_portrait_is_vertical_like_a_left_dock():
    assert dock_geometry(LANDSCAPE, 18).horizontal
    assert not dock_geometry(PORTRAIT, 18).horizontal


def test_icon_center_is_centered_for_a_centered_dock():
    g = dock_geometry(LANDSCAPE, 10)
    length = 10
    first = g.icon_center(0.5, length)
    last = g.icon_center(9.5, length)
    assert abs((first[0] + last[0]) / 2 - LANDSCAPE.width / 2) < 1
    assert first[1] == last[1]


def test_icon_size_capped_for_small_docks():
    assert dock_geometry(LANDSCAPE, 3).icon <= 120


def test_place_labels_never_overlap_on_the_same_row():
    # anchors (center along the dock) and widths
    placed = place_labels([(100, 200), (150, 200), (160, 200), (900, 200)], gap=12)
    rows = {}
    for (center, width), row in zip([(100, 200), (150, 200), (160, 200), (900, 200)], placed):
        rows.setdefault(row.row, []).append((row.start, row.start + width))
    for spans in rows.values():
        spans.sort()
        for (a0, a1), (b0, b1) in zip(spans, spans[1:]):
            assert a1 + 12 <= b0
    assert placed[3].row == 0


def test_place_labels_keep_near_anchor():
    placed = place_labels([(500, 100)], gap=10)
    assert placed[0].start == 450 and placed[0].row == 0
