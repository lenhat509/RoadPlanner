#!/usr/bin/env python3
"""Renders the Cadence app icon (1024×1024, RGB, no alpha — App Store requirement).

Usage: python3 scripts/generate_app_icon.py [output.png]
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # supersample for smooth edges
S = SIZE * SCALE


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def stroke(draw, points, width, fill):
    """Draws a smooth thick stroke by stamping discs along a dense path."""
    radius = width / 2
    for x, y in points:
        draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=fill)


def road_points(steps=3000):
    """A gentle S-curve from bottom-left to top-right."""
    points = []
    for i in range(steps + 1):
        t = i / steps
        x = 0.16 + 0.68 * t
        y = 0.86 - 0.72 * t + 0.10 * math.sin(t * math.pi * 2)
        points.append((x * S, y * S))
    return points


def main(path):
    top, bottom = (14, 124, 134), (9, 44, 61)
    image = Image.new("RGB", (S, S))
    pixels = ImageDraw.Draw(image)
    for row in range(S):
        pixels.line([(0, row), (S, row)], fill=lerp(top, bottom, row / S))

    # Soft glow behind the road.
    glow = Image.new("L", (S, S), 0)
    stroke(ImageDraw.Draw(glow), road_points(), S * 0.20, 110)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.03))
    image.paste((40, 170, 175), mask=glow)

    draw = ImageDraw.Draw(image)
    points = road_points()
    stroke(draw, points, S * 0.115, (245, 248, 250))

    # Dashed centre line.
    dash_color = (9, 44, 61)
    period, dash = 190, 95
    for start in range(60, len(points) - 60, period):
        stroke(draw, points[start:start + dash], S * 0.016, dash_color)

    # Stops: rest (green), fuel (amber), lodging (indigo).
    for t, color in ((0.30, (46, 158, 106)), (0.55, (227, 155, 45)), (0.80, (91, 91, 214))):
        x, y = points[int(t * (len(points) - 1))]
        outer, inner = S * 0.062, S * 0.044
        draw.ellipse([x - outer, y - outer, x + outer, y + outer], fill=(255, 255, 255))
        draw.ellipse([x - inner, y - inner, x + inner, y + inner], fill=color)

    image = image.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")
    image.save(path, "PNG", optimize=True)
    print(f"wrote {path} ({image.size[0]}x{image.size[1]}, mode {image.mode})")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
