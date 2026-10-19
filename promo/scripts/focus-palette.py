#!/usr/bin/env python3
"""Blurs the vault window behind the command palette in the palette captures, so the palette stands out.

Reads public/shots/palette-{light,dark}.png (from `Triwarden --demo-full --shoot`) and writes
public/shots/palette-focus-{light,dark}.png for the film and ../site/public/assets/shots/palette-focus-*.webp.
The window's own shape and shadow are kept; only its inside, outside the palette panel, is blurred.

    python3 scripts/focus-palette.py
"""
import os
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(HERE, "..", "public", "shots")
SITE = os.path.join(HERE, "..", "..", "site", "public", "assets", "shots")
PANEL = (650, 458, 2054, 1466)   # the palette panel in the 2704 × 2084 capture
RADIUS = 36                      # its corner radius
BLUR = 18

for mode in ("light", "dark"):
    im = Image.open(os.path.join(SHOTS, f"palette-{mode}.png")).convert("RGBA")
    a = np.asarray(im).astype(np.float32) / 255
    alpha = a[..., 3:4]

    # Blur premultiplied colour, so transparent pixels around the window don't bleed in as a dark fringe.
    pre = Image.fromarray((np.concatenate([a[..., :3] * alpha, alpha], -1) * 255).astype(np.uint8), "RGBA")
    b = np.asarray(pre.filter(ImageFilter.GaussianBlur(BLUR))).astype(np.float32) / 255
    blurred_rgb = b[..., :3] / np.maximum(b[..., 3:4], 1e-4)

    # Where to blur: the opaque window body, minus the palette panel.
    body = (alpha[..., 0] > 0.999).astype(np.float32)
    keep = Image.new("L", im.size, 0)
    ImageDraw.Draw(keep).rounded_rectangle(PANEL, RADIUS, fill=255)
    keep = np.asarray(keep.filter(ImageFilter.GaussianBlur(1.5))).astype(np.float32) / 255
    w = (body * (1 - keep))[..., None]

    rgb = a[..., :3] * (1 - w) + np.clip(blurred_rgb, 0, 1) * w
    out = Image.fromarray((np.concatenate([rgb, alpha], -1) * 255).round().astype(np.uint8), "RGBA")
    png = os.path.join(SHOTS, f"palette-focus-{mode}.png")
    out.save(png)
    webp = os.path.join(SITE, f"palette-focus-{mode}.webp")
    subprocess.run(["cwebp", "-quiet", "-q", "86", "-alpha_q", "90", "-resize", "1800", "0", png, "-o", webp], check=True)
    print("wrote", os.path.normpath(png), "and", os.path.normpath(webp))
