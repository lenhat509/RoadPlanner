#!/usr/bin/env python3
"""Renders the App Store product-page header in both accepted sizes (RGB, no alpha).

The app icon's scene, widened: the road runs to the horizon where the sun sits low, the planned
stops (rest, fuel, overnight, in the app's stop colours) get smaller into the distance, and low
mesas line the horizon on either side. There's no text, and everything that matters sits in the
middle, so the App Store can crop the sides for each device and orientation.

Usage: python3 scripts/generate_store_header.py [output-directory]
"""
import math
import os
import sys

from PIL import Image, ImageDraw

SIZES = [(5244, 2950), (3840, 1646)]
SCALE = 2  # supersample for smooth edges
HORIZON = 0.58  # as a share of the height

# The icon's palette.
SKY = [(0.0, (11, 69, 83)), (0.5, (26, 142, 148)), (HORIZON, (95, 184, 168))]
GROUND = [(HORIZON, (15, 75, 87)), (1.0, (8, 42, 51))]
SUN = (246, 196, 106)
ROAD = (244, 247, 247)
INK = (10, 52, 64)
FAR_MESAS = (64, 150, 148)
NEAR_MESAS = (24, 98, 108)
STOPS = [(1.25, (0, 158, 115)), (2.2, (230, 159, 0)), (4.2, (204, 121, 167))]


def gradient_color(stops, share):
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if share <= b:
            t = 0 if b == a else max(0.0, (share - a) / (b - a))
            return tuple(round(x + (y - x) * t) for x, y in zip(ca, cb))
    return stops[-1][1]


def ridge(width, height, horizon, peak, phase, keep_clear):
    """A low mesa skyline: flat tops and steep sides, kept away from the centre (the sun)."""
    points = [(0, horizon)]
    steps = 240
    for i in range(steps + 1):
        x = width * i / steps
        wave = (math.sin(x / width * 9.0 + phase) + 0.6 * math.sin(x / width * 23.0 + phase * 2.1)
                + 0.3 * math.sin(x / width * 51.0 + phase * 3.7))
        mesa = max(0.0, min(1.0, (wave + 0.2) * 1.6))  # clipped: flat tops, steep sides
        # Nothing near the centre, then a gentle rise.
        clear = max(0.0, min(1.0, (abs(x - width / 2) - keep_clear * 0.55) / (keep_clear * 0.45)))
        rise = peak * height * mesa * clear * clear * (3 - 2 * clear)
        points.append((x, horizon - (rise if rise > height * 0.004 else 0)))
    points.append((width, horizon))
    return points


def render(width, height):
    W, H = width * SCALE, height * SCALE
    image = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(image)
    horizon = round(H * HORIZON)
    for row in range(H):
        share = row / H
        draw.line([(0, row), (W, row)], fill=gradient_color(SKY if row < horizon else GROUND, share))

    unit = H / 1024  # the icon's grid, scaled to the height
    cx = W / 2

    # The sun's warm glow, above the horizon only.
    radius = round(560 * unit)
    glow = Image.new("L", (256, 256))
    glow.putdata([
        round(255 * 0.55 * max(0.0, 1 - ((x - 127.5) ** 2 + (y - 127.5) ** 2) ** 0.5 / 128) ** 1.4)
        for y in range(256) for x in range(256)
    ])
    glow = glow.resize((radius * 2, radius * 2), Image.BILINEAR)
    mask = Image.new("L", (W, H), 0)
    mask.paste(glow, (round(cx) - radius, horizon - radius))
    mask.paste(0, (0, horizon, W, H))
    image.paste(SUN, mask=mask)

    # Mesas on the horizon, far then near, leaving the sun clear.
    draw.polygon(ridge(W, H, horizon, 0.075, 0.7, W * 0.22), fill=FAR_MESAS)
    draw.polygon(ridge(W, H, horizon, 0.045, 2.9, W * 0.30), fill=NEAR_MESAS)

    sun = 118 * unit
    draw.pieslice([cx - sun, horizon - sun, cx + sun, horizon + sun], 180, 360, fill=SUN)

    # The road to the horizon, with its centre dashes in perspective.
    def depth_y(z):
        return horizon + (H - horizon) / z

    half_bottom, half_top = 255 * unit, 9 * unit
    draw.polygon([(cx - half_bottom, H), (cx + half_bottom, H), (cx + half_top, horizon), (cx - half_top, horizon)], fill=ROAD)
    for z0 in (1.0, 1.6, 2.5, 3.9, 6.0, 9.5):
        z1 = z0 * 1.28
        y0, y1 = depth_y(z0), depth_y(z1)
        w0, w1 = 13 * unit / z0, 13 * unit / z1
        draw.polygon([(cx - w0, y0), (cx + w0, y0), (cx + w1, y1), (cx - w1, y1)], fill=INK)

    for z, color in STOPS:
        y = depth_y(z)
        inner = 58 * unit / z ** 0.8
        ring = max(5 * unit, 17 * unit / z ** 0.8) / 2
        draw.ellipse([cx - inner - ring, y - inner - ring, cx + inner + ring, y + inner + ring], fill=(255, 255, 255))
        inner -= ring
        draw.ellipse([cx - inner, y - inner, cx + inner, y + inner], fill=color)

    return image.resize((width, height), Image.LANCZOS).convert("RGB")


def main(directory):
    os.makedirs(directory, exist_ok=True)
    for width, height in SIZES:
        path = os.path.join(directory, f"header-{width}x{height}.png")
        image = render(width, height)
        image.save(path, "PNG", optimize=True)
        print(f"wrote {path} ({image.size[0]}x{image.size[1]}, mode {image.mode}, {os.path.getsize(path) // 1024} KB)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "fastlane/store_assets")
