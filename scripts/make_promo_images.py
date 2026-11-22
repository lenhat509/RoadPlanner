#!/usr/bin/env python3
"""Makes the App Store images: each screenshot under a short caption, in the app's look.

    python3 scripts/make_promo_images.py SPEC.json SCREENSHOT_DIR OUTPUT_DIR

SPEC.json lists the images in store order, each with the screenshot to use and its caption
(lines split with \\n; start with a verb, plain words):

    {"size": [1320, 2868], "images": [{"name": "01-plan", "screenshot": "01-form-stops.png",
      "caption": "Plan a road trip\\nwith the places you love"}, ...]}

The output is SIZE (1320 x 2868 fills the 6.9-inch slot; the store scales it down for smaller
iPhones). The whole screenshot is shown, status bar included, with small rounded corners and a
thin border, on the green "road sign" of store_theme.py. Every caption uses the same text size.
"""
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store_theme as theme  # noqa: E402

CAPTION_TOP, CAPTION_HEIGHT = 150, 420  # caption band (at 1320 wide)
BOTTOM = 120  # margin under the screen


def make(screenshot, caption, size, text_size):
    width, height = size
    scale = width / 1320
    canvas = theme.sign(size, scale)
    shot = Image.open(screenshot).convert("RGB")
    top = round((CAPTION_TOP + CAPTION_HEIGHT + 30) * scale)
    screen_height = height - top - round(BOTTOM * scale)
    screen_width = round(shot.width * screen_height / shot.height)
    shot = shot.resize((screen_width, screen_height), Image.LANCZOS)
    left = (width - screen_width) // 2
    radius, border = round(40 * scale), max(2, round(5 * scale))
    theme.screen_frame(canvas, (left, top, screen_width, screen_height), radius, border)
    canvas.paste(shot, (left, top), theme.rounded_mask((screen_width, screen_height), radius))
    theme.draw_caption(
        canvas, caption,
        (round(110 * scale), round(CAPTION_TOP * scale), width - round(110 * scale), round((CAPTION_TOP + CAPTION_HEIGHT) * scale)),
        text_size,
    )
    return canvas


def main(spec_path, screenshots, output):
    spec = json.load(open(spec_path))
    size = tuple(spec.get("size", (1320, 2868)))
    scale = size[0] / 1320
    lines = [line for image in spec["images"] for line in image["caption"].split("\n")]
    text_size = theme.fitting_size(lines, size[0] - round(220 * scale), round(104 * scale), round(64 * scale))
    os.makedirs(output, exist_ok=True)
    for image in spec["images"]:
        target = os.path.join(output, f"{image['name']}.png")
        make(os.path.join(screenshots, image["screenshot"]), image["caption"], size, text_size).save(target, optimize=True)
        print(f"wrote {target}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
