"""The look of Waystage's App Store images and preview clips, shared by make_promo_images.py and
make_app_preview.py. It follows the app (docs/DESIGN.md): one solid highway-sign green, white text,
small corner radii, thin borders, no gradients or glows. The thin white rule around the edge is a
highway sign's border.
"""
from PIL import Image, ImageDraw, ImageFont

BRAND = (0, 107, 69)  # Theme.brand
BRAND_DARK = (0, 74, 48)  # the border around a screen
WHITE = (255, 255, 255)
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf"  # closest to the iPhone's system font


def font(size):
    return ImageFont.truetype(FONT, size)


def sign(size, scale):
    """The background: solid green with a thin white border inset from the edge, like a road sign.
    `scale` is 1 for a 1320-pixel-wide image."""
    width, height = size
    canvas = Image.new("RGB", size, BRAND)
    inset, stroke, radius = round(34 * scale), max(2, round(7 * scale)), round(44 * scale)
    ImageDraw.Draw(canvas).rounded_rectangle(
        [inset, inset, width - inset - 1, height - inset - 1], radius=radius, outline=WHITE, width=stroke
    )
    return canvas


def fitting_size(lines, max_width, largest, smallest):
    """The largest text size at which every line fits in `max_width`."""
    draw = ImageDraw.Draw(Image.new("L", (1, 1)))
    for size in range(largest, smallest - 1, -2):
        face = font(size)
        if max(draw.textlength(line, font=face) for line in lines) <= max_width:
            return size
    return smallest


def draw_caption(image, text, box, size, fill=WHITE + (255,)):
    """Draws `text` (lines split on \\n) centred in `box` = (left, top, right, bottom)."""
    draw = ImageDraw.Draw(image)
    face = font(size)
    lines = text.split("\n")
    line_height = round(size * 1.16)
    ascent, descent = face.getmetrics()
    block = line_height * (len(lines) - 1) + ascent + descent
    left, top, right, bottom = box
    y = top + (bottom - top - block) / 2
    for line in lines:
        width = draw.textlength(line, font=face)
        draw.text((left + (right - left - width) / 2, y), line, font=face, fill=fill)
        y += line_height


def rounded_mask(size, radius, supersample=4):
    width, height = size
    layer = Image.new("L", (width * supersample, height * supersample), 0)
    ImageDraw.Draw(layer).rounded_rectangle(
        [0, 0, width * supersample - 1, height * supersample - 1], radius=radius * supersample, fill=255
    )
    return layer.resize(size, Image.LANCZOS)


def screen_frame(canvas, box, radius, border):
    """A thin dark-green border around where a screen goes (box = left, top, width, height)."""
    left, top, width, height = box
    ImageDraw.Draw(canvas).rounded_rectangle(
        [left - border, top - border, left + width + border - 1, top + height + border - 1],
        radius=radius + border, fill=BRAND_DARK,
    )
