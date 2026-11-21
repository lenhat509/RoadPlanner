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

# Flat colours: no gradients anywhere in the app.
SKY = (17, 104, 113)
GROUND = (11, 56, 67)
SUN = (246, 196, 106)
ROAD = (244, 247, 247)
INK = (10, 52, 64)
# The app's stop colours (Okabe–Ito): rest, fuel, overnight.
STOPS = [(1.25, (0, 158, 115)), (2.2, (230, 159, 0)), (4.2, (204, 121, 167))]


def px(value):
    """1024-grid units → supersampled pixels."""
    return value * S / 1024


def depth_y(z):
    """Screen y (1024 grid) of a point on the road at depth z (1 = the bottom edge)."""
    return 1024 * HORIZON + 464 / z


def main(path):
    image = Image.new("RGB", (S, S), SKY)
    draw = ImageDraw.Draw(image)
    horizon = round(S * HORIZON)
    draw.rectangle([0, horizon, S, S], fill=GROUND)

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
