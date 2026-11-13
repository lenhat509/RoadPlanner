#!/usr/bin/env python3
"""Collects screenshots exported from an .xcresult bundle.

    xcrun xcresulttool export attachments --path X.xcresult --output-path raw
    python3 scripts/print_screenshots.py raw screenshots [--print]

* Copies each attachment to <output>/<test-given name>.png (e.g. 01-Plan.png).
* With --print, also prints a small JPEG preview of each screenshot as base64 between markers,
  so the images can be reviewed from the CI job log without downloading artifacts.
  (macOS only: uses `sips` to resize.)
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile


def attachments(node):
    """Yields (exported file name, suggested human-readable name) from the export manifest."""
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node["exportedFileName"], node.get("suggestedHumanReadableName") or node["exportedFileName"]
        for value in node.values():
            yield from attachments(value)
    elif isinstance(node, list):
        for value in node:
            yield from attachments(value)


def clean_name(name):
    # "01-Plan_0_5C2E….png" → "01-Plan"
    base = os.path.splitext(name)[0]
    return re.sub(r"_\d+_[0-9A-Fa-f-]{8,}$", "", base)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    source, output = sys.argv[1], sys.argv[2]
    print_previews = "--print" in sys.argv
    manifest_path = os.path.join(source, "manifest.json")
    if not os.path.exists(manifest_path):
        print(f"No manifest at {manifest_path}; nothing exported.")
        return 1
    with open(manifest_path) as handle:
        manifest = json.load(handle)
    os.makedirs(output, exist_ok=True)
    saved = []
    for exported, suggested in attachments(manifest):
        path = os.path.join(source, exported)
        if not os.path.exists(path) or not exported.lower().endswith((".png", ".jpg", ".jpeg")):
            continue
        name = clean_name(suggested)
        target = os.path.join(output, f"{name}.png")
        shutil.copyfile(path, target)
        saved.append((name, target))
    saved.sort()
    print(f"Saved {len(saved)} screenshots to {output}: {', '.join(name for name, _ in saved)}")

    if print_previews:
        with tempfile.TemporaryDirectory() as scratch:
            for name, target in saved:
                preview = os.path.join(scratch, f"{name}.jpg")
                subprocess.run(
                    ["sips", "-Z", "720", "-s", "format", "jpeg", "-s", "formatOptions", "60", target, "--out", preview],
                    check=True, stdout=subprocess.DEVNULL,
                )
                with open(preview, "rb") as handle:
                    encoded = base64.b64encode(handle.read()).decode("ascii")
                print(f"=====SCREENSHOT {name}=====")
                for start in range(0, len(encoded), 4000):
                    print(encoded[start:start + 4000])
                print("=====END=====")
    return 0


if __name__ == "__main__":
    sys.exit(main())
