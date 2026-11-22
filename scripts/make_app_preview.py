#!/usr/bin/env python3
"""Cuts an App Store app preview from a screen recording, with captions.

    python3 scripts/make_app_preview.py SPEC.json RECORDING.mp4 OUTPUT.mp4

SPEC.json lists the parts of the recording to use, each with a speed and a caption:

    {"crop_top": 236, "segments": [{"from": 0.0, "to": 1.9, "speed": 1.0, "caption": "Long drives,\\nplanned end to end"}, ...]}

`crop_top` removes that many pixels from the top of the recording: iOS's status bar, the red
screen-recording indicator and the AssistiveTouch button are not part of the app. Consecutive parts
with the same caption keep it on screen through the cut.

The recording is placed on the app's green "road sign" (store_theme.py) below the caption, with
small rounded corners and a thin border, and the parts are joined with short dissolves. The output follows Apple's app-preview format:
886 x 1920 (or the recording's own size), 30 fps, H.264 High, a silent stereo AAC track, 15-30 s.
Only the app's own screen recording is shown (App Store guideline 2.3.4); captions explain it.
"""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import store_theme as theme  # noqa: E402

FPS = 30
SIZE = (886, 1920)
SCALE = SIZE[0] / 1320  # store_theme sizes are for a 1320-pixel-wide image
TOP, BOTTOM = 400, 60  # caption band above the recording, margin below it
DISSOLVE = 4  # frames


def screen_geometry(src_w, src_h):
    height = SIZE[1] - TOP - BOTTOM
    width = round(src_w * height / src_h) // 2 * 2
    return width, height, (SIZE[0] - width) // 2, TOP


def rounded_mask(width, height, radius):
    return np.asarray(theme.rounded_mask((width, height), radius), dtype=np.float32)[..., None] / 255


def framed_background(width, height, x, y, radius):
    """The green road sign with a thin dark-green border where the recording goes."""
    canvas = theme.sign(SIZE, SCALE)
    theme.screen_frame(canvas, (x, y, width, height), radius, max(2, round(5 * SCALE)))
    return np.asarray(canvas, dtype=np.float32)


def caption_size(captions):
    """One text size for every caption in a preview: the largest at which each line fits."""
    lines = [line for caption in captions for line in caption.split("\n")]
    return theme.fitting_size(lines, SIZE[0] - round(220 * SCALE), round(104 * SCALE), round(60 * SCALE))


def caption_layer(text, size):
    """The caption as an RGBA band of height TOP (over the sign's green)."""
    layer = Image.new("RGBA", (SIZE[0], TOP), (0, 0, 0, 0))
    theme.draw_caption(layer, text, (round(80 * SCALE), round(70 * SCALE), SIZE[0] - round(80 * SCALE), TOP - 20), size)
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
    radius = round(40 * SCALE)
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
