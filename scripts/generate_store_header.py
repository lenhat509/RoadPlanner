#!/usr/bin/env python3
"""Renders the App Store product-page header in both accepted sizes (RGB, no alpha).

One long driving day as a panorama: daylight on the left turns to sunset in the middle and night
on the right. A road winds from the foreground into the distance, and the trip's stops stand along
it as pins in the app's stop colours: a break, fuel, and a motel lit up for the night. There's no
text, and the stops sit in the middle so the App Store can crop the sides for each device.

Usage: python3 scripts/generate_store_header.py [output-directory]
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw

SIZES = [(5244, 2950), (3840, 1646)]
SS = 3  # supersampling for the shape masks
HORIZON = 0.60  # as a share of the height

# Colour stops across the width (0 = left, daytime; 1 = right, night).
SKY_TOP = [(0.0, (22, 116, 140)), (0.42, (24, 102, 132)), (0.62, (46, 70, 112)), (0.82, (16, 28, 60)), (1.0, (9, 16, 38))]
SKY_LOW = [(0.0, (156, 212, 202)), (0.38, (184, 216, 196)), (0.55, (250, 196, 124)), (0.66, (236, 146, 112)),
           (0.80, (82, 66, 108)), (1.0, (26, 36, 68))]
FAR_HILLS = [(0.0, (104, 168, 170)), (0.45, (140, 150, 160)), (0.62, (150, 112, 128)), (0.8, (52, 50, 86)), (1.0, (26, 32, 62))]
NEAR_HILLS = [(0.0, (44, 122, 124)), (0.45, (60, 104, 112)), (0.62, (78, 72, 98)), (0.8, (28, 34, 64)), (1.0, (14, 20, 44))]
GROUND_TOP = [(0.0, (34, 110, 106)), (0.5, (40, 84, 92)), (0.7, (30, 44, 66)), (1.0, (12, 20, 40))]
GROUND_LOW = [(0.0, (12, 60, 64)), (0.5, (14, 46, 56)), (1.0, (6, 12, 26))]
ROAD = [(0.0, (238, 241, 238)), (0.5, (226, 222, 214)), (0.75, (150, 150, 168)), (1.0, (92, 98, 124))]
SUN = (250, 204, 120)
LINE = (246, 196, 106)
WINDOW = (255, 214, 140)
WHITE = (255, 255, 255)
STOPS = [  # (position along the road, colour, glyph)
    (0.36, (0, 158, 115), "rest"),
    (0.57, (230, 159, 0), "fuel"),
    (0.77, (204, 121, 167), "bed"),
]


def palette(keys, t):
    """Colours along `keys` for each value in the array t (any shape) → t.shape + (3,)."""
    ts = np.array([k for k, _ in keys], dtype=np.float32)
    cs = np.array([c for _, c in keys], dtype=np.float32)
    return np.stack([np.interp(t, ts, cs[:, i]) for i in range(3)], axis=-1).astype(np.float32)


def bezier(p0, p1, p2, p3, s):
    u = 1 - s
    return tuple(u ** 3 * a + 3 * u * u * s * b + 3 * u * s * s * c + s ** 3 * d for a, b, c, d in zip(p0, p1, p2, p3))


class Canvas:
    """Final-size RGB image plus helpers that draw anti-aliased shapes through supersampled masks."""

    def __init__(self, width, height):
        self.w, self.h = width, height
        self.pixels = np.zeros((height, width, 3), dtype=np.float32)

    def mask(self):
        layer = Image.new("L", (self.w * SS, self.h * SS), 0)
        return layer, ImageDraw.Draw(layer)

    def fill(self, layer, color, opacity=1.0):
        """Blends `color` (an RGB tuple, or an array the size of the image) through the mask, with
        `opacity` a number or an array (e.g. one value per column)."""
        alpha = np.asarray(layer.resize((self.w, self.h), Image.LANCZOS), dtype=np.float32)[..., None] / 255 * opacity
        color = np.asarray(color, dtype=np.float32)
        self.pixels = self.pixels * (1 - alpha) + color * alpha

    def image(self):
        return Image.fromarray(np.clip(self.pixels + 0.5, 0, 255).astype(np.uint8), "RGB")


def ridge_points(c, base, peak, waves, seed):
    """A hill line across the width, `peak` (share of the height) above `base` at most."""
    rng = random.Random(seed)
    phases = [rng.uniform(0, math.tau) for _ in waves]
    points = [(0, c.h * SS)]
    for i in range(401):
        x = i / 400
        wave = sum(amp * math.sin(x * freq + ph) for (freq, amp), ph in zip(waves, phases))
        height = peak * (0.55 + 0.45 * wave)
        points.append((x * c.w * SS, (base - height) * c.h * SS))
    points.append((c.w * SS, c.h * SS))
    return points


def glyph(draw, kind, cx, cy, r):
    """A small white symbol for the stop inside its pin, `r` being the pin's inner radius."""
    k = r / 100
    if kind == "rest":  # a cup with steam
        draw.rounded_rectangle([cx - 40 * k, cy - 18 * k, cx + 26 * k, cy + 44 * k], radius=14 * k, fill=255)
        draw.ellipse([cx + 12 * k, cy - 6 * k, cx + 52 * k, cy + 30 * k], outline=255, width=round(12 * k))
        for dx in (-22, 0):
            draw.arc([cx + (dx - 12) * k, cy - 62 * k, cx + (dx + 12) * k, cy - 26 * k], 100, 260, fill=255, width=round(9 * k))
    elif kind == "fuel":  # a pump with its hose and nozzle
        draw.rounded_rectangle([cx - 44 * k, cy - 50 * k, cx + 14 * k, cy + 50 * k], radius=10 * k, fill=255)
        draw.rectangle([cx - 32 * k, cy - 36 * k, cx + 2 * k, cy - 8 * k], fill=0)
        draw.line([(cx + 14 * k, cy - 30 * k), (cx + 40 * k, cy - 10 * k), (cx + 40 * k, cy + 30 * k)], fill=255, width=round(10 * k))
        draw.rounded_rectangle([cx + 32 * k, cy + 22 * k, cx + 50 * k, cy + 46 * k], radius=5 * k, fill=255)
    else:  # a bed
        draw.rectangle([cx - 54 * k, cy - 40 * k, cx - 40 * k, cy + 40 * k], fill=255)
        draw.rounded_rectangle([cx - 40 * k, cy + 2 * k, cx + 54 * k, cy + 26 * k], radius=6 * k, fill=255)
        draw.rectangle([cx + 42 * k, cy + 18 * k, cx + 54 * k, cy + 40 * k], fill=255)
        draw.rounded_rectangle([cx - 34 * k, cy - 22 * k, cx - 6 * k, cy - 2 * k], radius=8 * k, fill=255)
        draw.rounded_rectangle([cx - 2 * k, cy - 16 * k, cx + 54 * k, cy + 2 * k], radius=8 * k, fill=255)


def render(width, height):
    c = Canvas(width, height)
    xs = np.linspace(0, 1, width, dtype=np.float32)
    ys = np.linspace(0, 1, height, dtype=np.float32)
    horizon = HORIZON * height
    unit = height / 1000  # sizes below are in thousandths of the height

    # Sky: day to night across, top to horizon down.
    top, low = palette(SKY_TOP, xs), palette(SKY_LOW, xs)
    v = np.clip(ys / HORIZON, 0, 1)[:, None, None] ** 1.8
    c.pixels = top[None] * (1 - v) + low[None] * v

    # The setting sun's glow, then the stars and the moon on the night side.
    sun_x, sun_y = 0.585 * width, horizon - 18 * unit
    dx, dy = (np.arange(width)[None, :] - sun_x) / width, (np.arange(height)[:, None] - sun_y) / height
    glow = np.clip(1 - np.sqrt((dx * 1.25) ** 2 + (dy * 1.6) ** 2) / 0.42, 0, 1) ** 2.2 * 0.55
    c.pixels = c.pixels * (1 - glow[..., None]) + np.array(SUN, np.float32) * glow[..., None]

    layer, draw = c.mask()
    rng = random.Random(7)
    for _ in range(int(900 * width / 5244)):
        x, y = rng.uniform(0.66, 1.0), rng.uniform(0.0, HORIZON * 0.8)
        if rng.random() > (x - 0.66) / 0.24:  # fewer towards the dusk
            continue
        s = rng.choice([1.2, 1.6, 2.2, 3.2]) * unit * SS
        draw.ellipse([x * width * SS - s, y * height * SS - s, x * width * SS + s, y * height * SS + s], fill=rng.randint(120, 255))
    c.fill(layer, WHITE)
    layer, draw = c.mask()
    mx, my, mr = 0.885 * width * SS, 0.17 * height * SS, 46 * unit * SS
    draw.ellipse([mx - mr, my - mr, mx + mr, my + mr], fill=255)
    draw.ellipse([mx - mr + 30 * unit * SS, my - mr - 10 * unit * SS, mx + mr + 30 * unit * SS, my + mr - 10 * unit * SS], fill=0)
    c.fill(layer, (238, 236, 220))

    layer, draw = c.mask()
    sr = 92 * unit * SS
    draw.ellipse([sun_x * SS - sr, sun_y * SS - sr, sun_x * SS + sr, sun_y * SS + sr], fill=255)
    c.fill(layer, SUN)

    # Hills: far, then near, coloured by the time of day above them.
    layer, draw = c.mask()
    draw.polygon(ridge_points(c, HORIZON, 0.075, [(7, 0.55), (17, 0.3), (41, 0.15)], 3), fill=255)
    c.fill(layer, palette(FAR_HILLS, xs)[None])
    # The land: the near hills running down into the ground, shaded with no seam between them.
    g = np.clip((ys - (HORIZON - 0.04)) / (1 - HORIZON + 0.04), 0, 1)[:, None, None] ** 0.8
    near, ground_top, ground_low = palette(NEAR_HILLS, xs)[None], palette(GROUND_TOP, xs)[None], palette(GROUND_LOW, xs)[None]
    land = np.where(g < 0.18, near + (ground_top - near) * (g / 0.18), ground_top + (ground_low - ground_top) * ((g - 0.18) / 0.82))
    layer, draw = c.mask()
    draw.polygon(ridge_points(c, HORIZON + 0.012, 0.04, [(5, 0.6), (13, 0.3), (29, 0.1)], 11), fill=255)
    c.fill(layer, land)

    # The road: from the bottom left, winding right into the distance, narrowing with depth.
    p0, p1, p2, p3 = (0.24 * width, 1.30 * height), (0.44 * width, 0.80 * height), (0.50 * width, 0.66 * height), (0.84 * width, horizon + 22 * unit)

    def road_at(s):
        x, y = bezier(p0, p1, p2, p3, s)
        x2, y2 = bezier(p0, p1, p2, p3, min(1, s + 0.002))
        x1, y1 = bezier(p0, p1, p2, p3, max(0, s - 0.002))
        length = math.hypot(x2 - x1, y2 - y1) or 1
        nx, ny = -(y2 - y1) / length, (x2 - x1) / length
        half = (160 * (1 - s) ** 1.5 + 1.2) * unit
        return x, y, nx, ny, half

    samples = [road_at(i / 600) for i in range(601)]
    left = [((x + nx * h) * SS, (y + ny * h) * SS) for x, y, nx, ny, h in samples]
    right = [((x - nx * h) * SS, (y - ny * h) * SS) for x, y, nx, ny, h in samples]
    layer, draw = c.mask()
    draw.polygon(left + right[::-1], fill=255)
    fade = np.clip((0.83 - xs) / 0.13, 0, 1)[None, :, None]  # the far end melts into the dusk
    c.fill(layer, palette(ROAD, xs)[None], fade)

    # Centre line dashes, shorter and thinner with depth.
    layer, draw = c.mask()
    s = 0.0
    while s < 0.9:
        x, y, nx, ny, half = road_at(s)
        step = 0.012 + 0.03 * (1 - s) ** 2
        x2, y2, _, _, _ = road_at(min(1, s + step * 0.55))
        draw.line([(x * SS, y * SS), (x2 * SS, y2 * SS)], fill=255, width=max(2, round(half * 0.08 * SS)))
        s += step
    c.fill(layer, LINE, fade)

    # The motel for the night: just off the road by the last stop, windows lit.
    bx, by, _, _, bhalf = road_at(0.81)
    scale = 0.5
    bw, bh = 300 * unit * scale, 110 * unit * scale
    bx += 34 * unit
    by -= 6 * unit
    layer, draw = c.mask()
    draw.rectangle([bx * SS, (by - bh) * SS, (bx + bw) * SS, by * SS], fill=255)
    draw.rectangle([(bx + bw * 0.12) * SS, (by - bh * 1.35) * SS, (bx + bw * 0.3) * SS, (by - bh) * SS], fill=255)
    c.fill(layer, (22, 26, 48))
    layer, draw = c.mask()
    for row in range(2):
        for col in range(7):
            wx = bx + bw * (0.06 + col * 0.135)
            wy = by - bh * (0.82 - row * 0.42)
            draw.rectangle([wx * SS, wy * SS, (wx + bw * 0.07) * SS, (wy + bh * 0.22) * SS], fill=255 if (row * 7 + col) % 5 else 90)
    draw.rectangle([(bx + bw * 0.14) * SS, (by - bh * 1.3) * SS, (bx + bw * 0.28) * SS, (by - bh * 1.06) * SS], fill=255)
    c.fill(layer, WINDOW)

    # The stops: pins standing on the road, with a soft shadow, in the app's stop colours.
    for at, color, kind in STOPS:
        x, y, _, _, half = road_at(at)
        r = (80 - 52 * at) * unit
        cy = y - r * 2.1
        layer, draw = c.mask()
        draw.ellipse([(x - r * 0.9) * SS, (y - r * 0.18) * SS, (x + r * 0.9) * SS, (y + r * 0.18) * SS], fill=255)
        c.fill(layer, (0, 0, 0), 0.22)
        ring = r * 0.14
        layer, draw = c.mask()
        draw.ellipse([(x - r - ring) * SS, (cy - r - ring) * SS, (x + r + ring) * SS, (cy + r + ring) * SS], fill=255)
        tip = [((x - r * 0.62) * SS, (cy + r * 0.72) * SS), ((x + r * 0.62) * SS, (cy + r * 0.72) * SS), (x * SS, y * SS)]
        draw.polygon(tip, fill=255)
        c.fill(layer, WHITE)
        layer, draw = c.mask()
        draw.ellipse([(x - r) * SS, (cy - r) * SS, (x + r) * SS, (cy + r) * SS], fill=255)
        c.fill(layer, color)
        layer, draw = c.mask()
        glyph(draw, kind, x * SS, cy * SS, r * 0.88 * SS)
        c.fill(layer, WHITE)

    return c.image()


def main(directory):
    os.makedirs(directory, exist_ok=True)
    for width, height in SIZES:
        path = os.path.join(directory, f"header-{width}x{height}.png")
        image = render(width, height)
        image.save(path, "PNG", optimize=True)
        print(f"wrote {path} ({image.size[0]}x{image.size[1]}, mode {image.mode}, {os.path.getsize(path) // 1024} KB)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fastlane/store_assets")
