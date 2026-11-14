#!/usr/bin/env python3
"""Cuts an App Store app preview from a screen recording, with captions.

    python3 scripts/make_app_preview.py SPEC.json RECORDING.mp4 OUTPUT.mp4

SPEC.json lists the parts of the recording to use, each with a speed and a caption:

    {"crop_top": 236, "segments": [{"from": 0.0, "to": 1.9, "speed": 1.0, "caption": "Long drives,\\nplanned end to end"}, ...]}

`crop_top` removes that many pixels from the top of the recording: iOS's status bar, the red
screen-recording indicator and the AssistiveTouch button are not part of the app. Consecutive parts
with the same caption keep it on screen through the cut.

The recording is placed on the brand's teal background below the caption, with rounded corners,
and the parts are joined with short dissolves. The output follows Apple's app-preview format:
886 x 1920 (or the recording's own size), 30 fps, H.264 High, a silent stereo AAC track, 15-30 s.
Only the app's own screen recording is shown (App Store guideline 2.3.4); captions explain it.
"""
import json
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FPS = 30
SIZE = (886, 1920)
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf"
TOP, BOTTOM = 440, 56  # caption band above the recording, margin below it
DISSOLVE = 4  # frames
STOP_COLOURS = [(0, 158, 115), (230, 159, 0), (204, 121, 167)]


def background():
    w, h = SIZE
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    top, bottom = np.array((17, 112, 120), np.float32), np.array((7, 36, 46), np.float32)
    canvas = top * (1 - t) + bottom * t
    # A soft light behind the caption.
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    glow = np.clip(1 - np.hypot((xx - w / 2) / (w * 0.75), (yy - 200) / 520), 0, 1) ** 2 * 0.22
    canvas = canvas * (1 - glow[..., None]) + np.array((120, 210, 200), np.float32) * glow[..., None]
    return np.broadcast_to(canvas, (h, w, 3)).copy()


def screen_geometry(src_w, src_h):
    height = SIZE[1] - TOP - BOTTOM
    width = round(src_w * height / src_h) // 2 * 2
    return width, height, (SIZE[0] - width) // 2, TOP


def rounded_mask(width, height, radius):
    scale = 4
    layer = Image.new("L", (width * scale, height * scale), 0)
    ImageDraw.Draw(layer).rounded_rectangle([0, 0, width * scale - 1, height * scale - 1], radius=radius * scale, fill=255)
    return np.asarray(layer.resize((width, height), Image.LANCZOS), dtype=np.float32)[..., None] / 255


def framed_background(width, height, x, y, radius):
    canvas = background()
    # Drop shadow and a faint rim around the recording.
    shadow = Image.new("L", SIZE, 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 18, x + width, y + height + 18], radius=radius, fill=150)
    shadow = np.asarray(shadow.filter(ImageFilter.GaussianBlur(28)), dtype=np.float32)[..., None] / 255
    canvas = canvas * (1 - shadow * 0.7)
    rim = Image.new("L", SIZE, 0)
    ImageDraw.Draw(rim).rounded_rectangle([x - 3, y - 3, x + width + 3, y + height + 3], radius=radius + 3, fill=255)
    rim = np.asarray(rim, dtype=np.float32)[..., None] / 255 * 0.14
    return canvas * (1 - rim) + 255 * rim


def caption_size(captions, largest=68, smallest=40):
    """One text size for every caption in a preview: the largest at which each line fits."""
    draw = ImageDraw.Draw(Image.new("L", (1, 1)))
    lines = [line for caption in captions for line in caption.split("\n")]
    for size in range(largest, smallest - 1, -2):
        font = ImageFont.truetype(FONT, size)
        if max(draw.textlength(line, font=font) for line in lines) <= SIZE[0] - 110:
            return size
    return smallest


def caption_layer(text, size):
    """The caption (and the three stop-colour dots under it) as an RGBA band of height TOP."""
    w = SIZE[0]
    layer = Image.new("RGBA", (w, TOP), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    lines = text.split("\n")
    font = ImageFont.truetype(FONT, size)
    widths = [draw.textlength(line, font=font) for line in lines]
    line_height = round(size * 1.14)
    block = line_height * len(lines)
    y = (TOP - 70 - block) // 2 + 20
    for line, lw in zip(lines, widths):
        draw.text(((w - lw) / 2, y), line, font=font, fill=(255, 255, 255, 255))
        y += line_height
    dots_y = TOP - 62
    for i, colour in enumerate(STOP_COLOURS):
        cx = w / 2 + (i - 1) * 34
        draw.ellipse([cx - 9, dots_y - 9, cx + 9, dots_y + 9], fill=colour + (255,))
    rgba = np.asarray(layer, dtype=np.float32)
    return rgba[..., :3], rgba[..., 3:] / 255


def segment_frames(source, segment, width, height, crop_top):
    """Yields the segment's frames (height x width x 3, uint8) at 30 fps after the speed change."""
    speed = float(segment.get("speed", 1))
    command = [
        "ffmpeg", "-v", "error", "-ss", str(segment["from"]), "-to", str(segment["to"]), "-i", source,
        "-vf", f"crop=iw:ih-{crop_top}:0:{crop_top},setpts=(PTS-STARTPTS)/{speed},fps={FPS},"
               f"scale={width}:{height}:flags=lanczos",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE)
    frame_bytes = width * height * 3
    while True:
        data = process.stdout.read(frame_bytes)
        if len(data) < frame_bytes:
            break
        yield np.frombuffer(data, np.uint8).reshape(height, width, 3)
    process.wait()


def main(spec_path, source, output):
    spec = json.load(open(spec_path))
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                            "-of", "csv=p=0", source], capture_output=True, text=True, check=True)
    src_w, src_h = (int(v) for v in probe.stdout.strip().split(","))
    crop_top = int(spec.get("crop_top", 0))
    width, height, x, y = screen_geometry(src_w, src_h - crop_top)
    radius = 46
    base = framed_background(width, height, x, y, radius)
    mask = rounded_mask(width, height, radius)

    encoder = subprocess.Popen([
        "ffmpeg", "-v", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{SIZE[0]}x{SIZE[1]}", "-r", str(FPS), "-i", "-",
        "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
        "-shortest", "-map", "0:v", "-map", "1:a",
        "-c:v", "libx264", "-profile:v", "high", "-level", "4.0", "-pix_fmt", "yuv420p",
        "-b:v", "10M", "-maxrate", "12M", "-bufsize", "20M", "-r", str(FPS), "-g", "60",
        "-c:a", "aac", "-b:a", "256k", "-ar", "44100", "-ac", "2", "-movflags", "+faststart", output,
    ], stdin=subprocess.PIPE)

    total = 0
    previous_last = None
    segments = spec["segments"]
    text_size = caption_size(segment["caption"] for segment in segments)
    for index, segment in enumerate(segments):
        caption_rgb, caption_alpha = caption_layer(segment["caption"], text_size)
        frames = list(segment_frames(source, segment, width, height, crop_top))
        count = len(frames)
        for n, frame in enumerate(frames):
            screen = frame.astype(np.float32)
            if previous_last is not None and n < DISSOLVE:  # dissolve from the last part
                t = (n + 1) / (DISSOLVE + 1)
                screen = previous_last * (1 - t) + screen * t
            out = base.copy()
            region = out[y:y + height, x:x + width]
            out[y:y + height, x:x + width] = region * (1 - mask) + screen * mask
            # The caption fades in after a cut and out before the next one.
            same_before = index > 0 and segments[index - 1]["caption"] == segment["caption"]
            same_after = index < len(segments) - 1 and segments[index + 1]["caption"] == segment["caption"]
            fade_in = 1.0 if index == 0 or same_before else min(1.0, (n + 1) / 6)
            fade_out = 1.0 if index == len(segments) - 1 or same_after else min(1.0, (count - n) / 5)
            a = caption_alpha * min(fade_in, fade_out)
            out[:TOP] = out[:TOP] * (1 - a) + caption_rgb * a
            encoder.stdin.write(np.clip(out + 0.5, 0, 255).astype(np.uint8).tobytes())
        previous_last = frames[-1].astype(np.float32) if frames else previous_last
        total += count
        print(f"  {segment['from']:>5.1f}-{segment['to']:<5.1f} x{segment.get('speed', 1):<4} {count / FPS:5.2f}s  {segment['caption']!r}")
    encoder.stdin.close()
    encoder.wait()
    seconds = total / FPS
    print(f"wrote {output}: {seconds:.2f}s")
    if not 15 <= seconds <= 30:
        sys.exit(f"App previews must be 15-30 seconds long; this one is {seconds:.2f}s")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
