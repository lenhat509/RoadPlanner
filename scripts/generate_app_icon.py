#!/usr/bin/env python3
"""Renders the Waystage app icon (1024×1024, RGB, no alpha — App Store requirement).

The road runs from the bottom of the icon to the horizon, where the sun sits low; the planned
stops (rest, fuel, overnight, in the app's stop colours) get smaller into the distance.

Usage: python3 scripts/generate_app_icon.py [output.png]
"""
import sys

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # supersample for smooth edges
S = SIZE * SCALE
HORIZON = 560 / 1024  # as a share of the height

SKY = [(0.0, (11, 69, 83)), (0.5, (26, 142, 148)), (HORIZON, (95, 184, 168))]
GROUND = [(HORIZON, (15, 75, 87)), (1.0, (8, 42, 51))]
SUN = (246, 196, 106)
ROAD = (244, 247, 247)
INK = (10, 52, 64)
# The app's stop colours (Okabe–Ito): rest, fuel, overnight.
STOPS = [(1.25, (0, 158, 115)), (2.2, (230, 159, 0)), (4.2, (204, 121, 167))]


def px(value):
    """1024-grid units → supersampled pixels."""
    return value * S / 1024


def gradient_color(stops, share):
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if share <= b:
            t = 0 if b == a else max(0.0, (share - a) / (b - a))
            return tuple(round(x + (y - x) * t) for x, y in zip(ca, cb))
    return stops[-1][1]


def depth_y(z):
    """Screen y (1024 grid) of a point on the road at depth z (1 = the bottom edge)."""
    return 1024 * HORIZON + 464 / z


def main(path):
    image = Image.new("RGB", (S, S))
    draw = ImageDraw.Draw(image)
    horizon = round(S * HORIZON)
    for row in range(S):
        share = row / S
        draw.line([(0, row), (S, row)], fill=gradient_color(SKY if row < horizon else GROUND, share))

    # A warm glow around the sun, above the horizon only.
    radius = round(px(460))
    glow = Image.new("L", (256, 256))
    glow.putdata([
        round(255 * 0.55 * max(0.0, 1 - ((x - 127.5) ** 2 + (y - 127.5) ** 2) ** 0.5 / 128))
        for y in range(256) for x in range(256)
    ])
    glow = glow.resize((radius * 2, radius * 2), Image.BILINEAR)
    mask = Image.new("L", (S, S), 0)
    center = (round(px(512)), round(px(563)))
    mask.paste(glow, (center[0] - radius, center[1] - radius))
    mask.paste(0, (0, horizon, S, S))
    image.paste(SUN, mask=mask)

    sun = px(128)
    draw.pieslice([px(512) - sun, px(560) - sun, px(512) + sun, px(560) + sun], 180, 360, fill=SUN)

    # The road to the horizon, with its centre dashes in perspective.
    draw.polygon([(px(250), S), (px(774), S), (px(524), horizon), (px(500), horizon)], fill=ROAD)
    for z0 in (1.0, 1.6, 2.5, 3.9, 6.0, 9.5):
        z1 = z0 * 1.28
        y0, y1 = px(depth_y(z0)), px(depth_y(z1))
        w0, w1 = px(15 / z0), px(15 / z1)
        draw.polygon([(px(512) - w0, y0), (px(512) + w0, y0), (px(512) + w1, y1), (px(512) - w1, y1)], fill=INK)

    for z, color in STOPS:
        y = px(depth_y(z))
        inner = px(round(64 / z ** 0.8))
        ring = px(max(5, round(19 / z ** 0.8))) / 2
        draw.ellipse([px(512) - inner - ring, y - inner - ring, px(512) + inner + ring, y + inner + ring], fill=(255, 255, 255))
        inner -= ring
        draw.ellipse([px(512) - inner, y - inner, px(512) + inner, y + inner], fill=color)

    image = image.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    image.save(path, "PNG", optimize=True)
    print(f"wrote {path} ({image.size[0]}x{image.size[1]}, mode {image.mode})")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
