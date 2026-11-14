#!/usr/bin/env python3
"""Renders the App Store product-page header (both accepted sizes) and the search-results asset
(3840 x 2560), all RGB with no alpha.

One long driving day as a panorama: daylight on the left turns to sunset in the middle and night
on the right. A road winds from the foreground into the distance, toward a city lit up on the horizon (the
destination). The trip's stops are places beside the road, each with a driveway: a rest area, a
gas station and a motel for the night; their markers stand on the road as pins in the app's stop
colours. There's no text, and the stops sit in the middle so the App Store can crop the sides.

Usage: python3 scripts/generate_store_header.py [output-directory]
"""
import math
import os
import random
import sys

import numpy as np
from PIL import Image, ImageDraw

SIZES = [("header", 5244, 2950), ("header", 3840, 1646), ("search", 3840, 2560)]
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
    (0.30, (0, 158, 115), "rest"),
    (0.56, (230, 159, 0), "fuel"),
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


class Site:
    """A roadside place drawn in design units from its base centre (x right, y down, k px/unit)."""

    def __init__(self, c, bx, by, k):
        self.c, self.bx, self.by, self.k = c, bx, by, k

    def box(self, x0, y0, x1, y1):
        return [(self.bx + x0 * self.k) * SS, (self.by + y0 * self.k) * SS, (self.bx + x1 * self.k) * SS, (self.by + y1 * self.k) * SS]

    def points(self, *xy):
        return [((self.bx + x * self.k) * SS, (self.by + y * self.k) * SS) for x, y in xy]

    def paint(self, color, shapes, opacity=1.0):
        layer, draw = self.c.mask()
        shapes(draw)
        self.c.fill(layer, color, opacity)


def rest_area(site):
    """A small rest-area building with a gabled roof, trees and a picnic table."""
    for tx, tr in ((-82, 26), (74, 33)):
        site.paint((84, 64, 48), lambda d: d.rectangle(site.box(tx - 4, -tr * 1.1, tx + 4, 0), fill=255))
        site.paint((46, 136, 100), lambda d: d.ellipse(site.box(tx - tr, -tr * 2.9, tx + tr, -tr * 0.9), fill=255))
        site.paint((34, 110, 84), lambda d: d.ellipse(site.box(tx - tr * 0.2, -tr * 2.3, tx + tr, -tr * 0.9), fill=255))
    site.paint((232, 234, 228), lambda d: d.rectangle(site.box(-42, -40, 42, 0), fill=255))
    site.paint((168, 96, 72), lambda d: d.polygon(site.points((-52, -38), (52, -38), (0, -74)), fill=255))
    site.paint((58, 82, 92), lambda d: d.rectangle(site.box(-9, -27, 9, 0), fill=255))
    site.paint((176, 214, 222), lambda d: [d.rectangle(site.box(x, -30, x + 15, -16), fill=255) for x in (-34, 19)])
    site.paint((128, 90, 62), lambda d: [d.rectangle(site.box(*b), fill=255) for b in
                                         ((104, -16, 144, -12), (108, -12, 111, 0), (137, -12, 140, 0), (100, -7, 148, -5))])


def gas_station(site):
    """A canopy over two pumps, the shop behind, and a tall price sign."""
    site.paint((214, 204, 192), lambda d: d.rectangle(site.box(14, -46, 100, 0), fill=255))
    site.paint((255, 226, 160), lambda d: d.rectangle(site.box(24, -36, 90, -16), fill=255))
    site.paint((255, 236, 190), lambda d: d.ellipse(site.box(-104, -40, 32, 14), fill=255), 0.18)
    site.paint((172, 178, 184), lambda d: [d.rectangle(site.box(x, -70, x + 6, 0), fill=255) for x in (-88, 12)])
    site.paint((246, 246, 242), lambda d: [d.rectangle(site.box(x, -30, x + 13, 0), fill=255) for x in (-64, -30)])
    site.paint((230, 159, 0), lambda d: [d.rectangle(site.box(x, -30, x + 13, -23), fill=255) for x in (-64, -30)])
    site.paint((246, 246, 242), lambda d: d.rectangle(site.box(-100, -86, 26, -70), fill=255))
    site.paint((230, 159, 0), lambda d: d.rectangle(site.box(-100, -77, 26, -70), fill=255))
    site.paint((150, 156, 164), lambda d: d.rectangle(site.box(122, -104, 128, 0), fill=255))
    site.paint((230, 159, 0), lambda d: d.rounded_rectangle(site.box(105, -140, 145, -100), radius=3 * site.k * SS, fill=255))
    site.paint((255, 255, 255), lambda d: [d.rectangle(site.box(111, y, 139, y + 6), fill=255) for y in (-132, -119, -107)])


def motel(site):
    """A two-storey motel at night with lit windows and a glowing sign."""
    site.paint((26, 30, 56), lambda d: d.rectangle(site.box(-80, -58, 80, 0), fill=255))
    site.paint((44, 50, 84), lambda d: d.rectangle(site.box(-86, -64, 86, -56), fill=255))

    def windows(d):
        for row in range(2):
            for col in range(8):
                if (row * 8 + col) % 5 != 3:
                    x, y = -70 + col * 18.5, -48 + row * 24
                    d.rectangle(site.box(x, y, x + 10, y + 13), fill=255)
    site.paint(WINDOW, windows)
    site.paint((150, 156, 164), lambda d: d.rectangle(site.box(100, -118, 105, 0), fill=255))
    site.paint((204, 121, 167), lambda d: d.ellipse(site.box(72, -176, 134, -96), fill=255), 0.28)
    site.paint((204, 121, 167), lambda d: d.rounded_rectangle(site.box(86, -150, 120, -114), radius=4 * site.k * SS, fill=255))
    site.paint((255, 236, 246), lambda d: d.rectangle(site.box(92, -136, 114, -128), fill=255))


def city(c, x0, x1, base, unit):
    """The destination: a small skyline with lit windows and a warm glow above it."""
    rng = random.Random(21)
    towers, x = [], x0
    while x < x1:
        w = rng.uniform(9, 22) * unit
        h = rng.uniform(16, 46) * unit * (1.5 if abs(x - (x0 + x1) / 2) < (x1 - x0) * 0.2 else 1.0)
        towers.append((x, w, h))
        x += w + rng.uniform(1, 4) * unit
    layer, draw = c.mask()
    for x, w, h in towers:
        draw.rectangle([x * SS, (base - h) * SS, (x + w) * SS, (base + 4 * unit) * SS], fill=255)
    c.fill(layer, (18, 22, 46))
    layer, draw = c.mask()
    for x, w, h in towers:
        for wy in np.arange(base - h + 4 * unit, base - 3 * unit, 6 * unit):
            for wx in np.arange(x + 2.5 * unit, x + w - 3 * unit, 5 * unit):
                if rng.random() < 0.45:
                    draw.rectangle([wx * SS, wy * SS, (wx + 2.2 * unit) * SS, (wy + 2.8 * unit) * SS], fill=255)
    c.fill(layer, WINDOW)


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

    # The destination: a city on the horizon where the road leads, with a warm glow above it.
    city_x0, city_x1, city_base = 0.865 * width, 0.975 * width, horizon + 26 * unit
    gx, gy = (np.arange(width)[None, :] - (city_x0 + city_x1) / 2) / width, (np.arange(height)[:, None] - city_base) / height
    glow = np.clip(1 - np.sqrt((gx * 1.0) ** 2 + (gy * 2.4) ** 2) / 0.11, 0, 1) ** 2 * 0.35
    c.pixels = c.pixels * (1 - glow[..., None]) + np.array((255, 196, 140), np.float32) * glow[..., None]
    city(c, city_x0, city_x1, city_base, unit)

    # The road: from the bottom left, winding right into the distance, narrowing with depth.
    p0, p1, p2, p3 = (-0.03 * width, 0.89 * height), (0.30 * width, 0.755 * height), (0.56 * width, 0.655 * height), (0.86 * width, horizon + 22 * unit)

    def road_at(s):
        x, y = bezier(p0, p1, p2, p3, s)
        x2, y2 = bezier(p0, p1, p2, p3, min(1, s + 0.002))
        x1, y1 = bezier(p0, p1, p2, p3, max(0, s - 0.002))
        length = math.hypot(x2 - x1, y2 - y1) or 1
        nx, ny = -(y2 - y1) / length, (x2 - x1) / length
        half = (118 * (1 - s) ** 1.5 + 1.2) * unit
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

    # The places to stop, beside the road with a driveway each: (where, which side, gap, scale).
    def place(at, side, gap, scale, lot, draw_site):
        x, y, nx, ny, half = road_at(at)
        ex, ey = x + side * nx * half, y + side * ny * half  # the road's edge
        bx, by = x + side * nx * (half + gap * unit), y + side * ny * (half + gap * unit)
        k = scale * unit
        tx, ty = road_at(at + 0.01)[:2]
        ux, uy = (tx - x), (ty - y)
        length = math.hypot(ux, uy) or 1
        ux, uy = ux / length * 22 * k, uy / length * 22 * k
        layer, draw = c.mask()
        draw.polygon([((ex - ux) * SS, (ey - uy) * SS), ((ex + ux) * SS, (ey + uy) * SS),
                      ((bx + 24 * k) * SS, (by - 6 * k) * SS), ((bx - 24 * k) * SS, (by - 6 * k) * SS)], fill=255)
        draw.rounded_rectangle([(bx - lot * k) * SS, (by - 8 * k) * SS, (bx + lot * k) * SS, (by + 10 * k) * SS], radius=4 * k * SS, fill=255)
        c.fill(layer, palette(ROAD, xs)[None] * 0.72, fade * 0.9)
        draw_site(Site(c, bx, by, k))

    place(0.30, 1, 82, 0.92, 110, rest_area)
    place(0.56, 1, 110, 0.78, 120, gas_station)
    place(0.78, 1, 78, 0.68, 100, motel)

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
    for name, width, height in SIZES:
        path = os.path.join(directory, f"{name}-{width}x{height}.png")
        image = render(width, height)
        image.save(path, "PNG", optimize=True)
        print(f"wrote {path} ({image.size[0]}x{image.size[1]}, mode {image.mode}, {os.path.getsize(path) // 1024} KB)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fastlane/store_assets")
