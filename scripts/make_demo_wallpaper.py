"""Generate a license-free, macOS-style gradient wallpaper for the README previews."""

import sys

import numpy as np
from PIL import Image, ImageFilter

W, H = 2560, 1600
rng = np.random.default_rng(4)
y, x = np.mgrid[0:H, 0:W].astype(np.float32)
img = np.zeros((H, W, 3), np.float32) + np.array([18, 22, 58], np.float32)
blobs = [((0.15, 0.85), 0.55, (255, 120, 60)), ((0.55, 0.95), 0.6, (240, 70, 120)),
         ((0.9, 0.7), 0.5, (120, 80, 230)), ((0.35, 0.35), 0.45, (40, 110, 220)),
         ((0.8, 0.15), 0.4, (60, 190, 210))]
for (cx, cy), r, col in blobs:
    d = ((x / W - cx) ** 2 + ((y / H - cy) * H / W) ** 2) / (r * r)
    w = np.exp(-d * 2.2)[..., None]
    img = img * (1 - w * 0.85) + np.array(col, np.float32) * w * 0.85
img += rng.normal(0, 2.0, img.shape)
out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(3))
out.save(sys.argv[1] if len(sys.argv) > 1 else "docs/demo-wallpaper.jpg", quality=92)
