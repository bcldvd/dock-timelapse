from dock_timelapse import config


def test_defaults_screenshots_off(tmp_path):
    assert config.load(tmp_path) == {"screenshots": False}


def test_save_merges_and_persists(tmp_path):
    config.save(tmp_path, screenshots=True)
    assert config.load(tmp_path)["screenshots"] is True
