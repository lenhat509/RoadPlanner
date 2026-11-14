#!/usr/bin/env python3
"""Builds the public website (privacy policy, support, terms) from the Markdown in docs/.

The App Store needs a privacy policy URL and a support URL; the app links to the same pages.
The Markdown in docs/ stays the single source; this script only adds a page frame and fills in
the contact address from site/site.json.

Usage: python3 scripts/build_site.py OUTPUT_DIR [--allow-placeholders]
"""
import html
import json
import re
import shutil
import sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parent.parent
PAGES = [
    # (folder, source, title)
    ("privacy", "docs/PRIVACY_POLICY.md", "Privacy Policy"),
    ("support", "docs/SUPPORT.md", "Support"),
    ("terms", "docs/TERMS_OF_USE.md", "Terms of Use"),
]
PLACEHOLDER = re.compile(r"[\w.+-]+@waystage\.example\.com")

STYLE = """
:root { --bg: #F3F5F4; --card: #FFFFFF; --fg: #12282D; --muted: #56696D; --line: rgba(18,40,45,.1); --accent: #127A80; }
@media (prefers-color-scheme: dark) { :root { --bg: #0B1416; --card: #121D20; --fg: #E5EEEE; --muted: #97AAAD; --line: rgba(229,238,238,.1); --accent: #54C4C6; color-scheme: dark; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--fg); font: 17px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif; }
.wrap { max-width: 760px; margin: 0 auto; padding: 32px max(16px, env(safe-area-inset-left)) 64px; }
header { display: flex; align-items: center; gap: 12px; margin-bottom: 28px; }
header img { width: 44px; height: 44px; border-radius: 10px; }
header a { color: inherit; text-decoration: none; font-weight: 800; font-size: 20px; letter-spacing: -0.01em; }
nav { margin-left: auto; display: flex; gap: 16px; flex-wrap: wrap; font-size: 15px; }
nav a { color: var(--accent); text-decoration: none; font-weight: 600; }
nav a[aria-current] { color: var(--fg); }
main { background: var(--card); border: 1px solid var(--line); border-radius: 18px; padding: 28px; }
h1 { font-size: 30px; line-height: 1.2; margin: 0 0 8px; letter-spacing: -0.02em; }
h2 { font-size: 20px; margin: 28px 0 8px; }
a { color: var(--accent); }
table { border-collapse: collapse; width: 100%; font-size: 15px; display: block; overflow-x: auto; }
th, td { text-align: left; vertical-align: top; padding: 8px 10px; border-top: 1px solid var(--line); }
footer { margin-top: 24px; color: var(--muted); font-size: 14px; }
.hero { text-align: center; padding: 24px 0 8px; }
.hero img { width: 112px; height: 112px; border-radius: 25px; box-shadow: 0 8px 24px rgba(0,0,0,.18); }
.hero p { color: var(--muted); }
"""


def page(site, title, body, current=None, root="../"):
    current_attr = ' aria-current="page"'
    links = "".join(
        f'<a href="{root}{folder}/"{current_attr if folder == current else ""}>{html.escape(name)}</a>'
        for folder, _, name in PAGES
    )
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{html.escape(title)} · {html.escape(site["name"])}</title>
<link rel="icon" href="{root}icon.png">
<style>{STYLE}</style>
</head>
<body>
<div class="wrap">
<header><img src="{root}icon.png" alt=""><a href="{root}">{html.escape(site["name"])}</a><nav>{links}</nav></header>
<main>
{body}
</main>
<footer>© {html.escape(site["name"])}. Maps, directions and places by Google Maps.</footer>
</div>
</body>
</html>
"""


def contact_markdown(site, kind):
    email = site.get("contactEmail", "").strip()
    issues = site.get("issuesURL", "").strip()
    parts = []
    if email:
        parts.append(f"email [{email}](mailto:{email})")
    if kind == "support" and issues:
        parts.append(f"[open an issue on GitHub]({issues})")
    return " or ".join(parts)


def prepare(source, site, kind):
    text = (ROOT / source).read_text(encoding="utf-8")
    # Notes for maintainers (blockquotes about keeping copies in sync) aren't for the public.
    text = re.sub(r"(?m)^> .*(?:\n> .*)*\n?", "", text)
    contact = contact_markdown(site, kind)
    if contact:
        text = re.sub(r"(?m)^.*@waystage\.example\.com.*$",
                      f"Contact: {contact}." if kind != "privacy" else f"Questions about privacy: {contact}.", text)
    return text


def build(output, allow_placeholders=False):
    site = json.loads((ROOT / "site/site.json").read_text(encoding="utf-8"))
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    shutil.copy(ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", output / "icon.png")
    problems = []
    for folder, source, title in PAGES:
        text = prepare(source, site, folder)
        if PLACEHOLDER.search(text):
            problems.append(f"{source}: placeholder contact address; set contactEmail in site/site.json")
        body = markdown.markdown(text, extensions=["tables"])
        (output / folder).mkdir()
        (output / folder / "index.html").write_text(page(site, title, body, current=folder), encoding="utf-8")
    links = "".join(f'<p><a href="{folder}/">{html.escape(title)}</a></p>' for folder, _, title in PAGES)
    home = (f'<div class="hero"><img src="icon.png" alt="{html.escape(site["name"])} app icon">'
            f'<h1>{html.escape(site["name"])}</h1><p>{html.escape(site["tagline"])}</p></div>{links}')
    (output / "index.html").write_text(page(site, site["tagline"], home, root=""), encoding="utf-8")
    (output / ".nojekyll").write_text("")
    if problems and not allow_placeholders:
        sys.exit("Not publishing:\n  " + "\n  ".join(problems))
    print(f"built {output} ({len(PAGES) + 1} pages)" + (" with placeholders" if problems else ""))


if __name__ == "__main__":
    build(Path(sys.argv[1]), allow_placeholders="--allow-placeholders" in sys.argv)
