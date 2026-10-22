# /// script
# requires-python = ">=3.12"
# dependencies = ["resvg-py", "pillow"]
# ///
"""Writes packaging/windows/workbench.ico: the exe's own icon (Explorer, the taskbar, shortcuts, Settings > Apps).

The picture is the window's: `WINDOW_ICON` in workbench/workbench.odin, the SVG data URL the title bar shows.
It is read from there rather than copied, so re-run this after changing the mark:  just icon
The .ico is checked in, so a build needs neither this script nor its dependencies.
"""

import io
import re
import sys
import urllib.parse
from pathlib import Path

import resvg_py
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SIZES = [16, 20, 24, 32, 40, 48, 64, 256]

source = (ROOT / "workbench" / "workbench.odin").read_text(encoding="utf-8")
found = re.search(r'^WINDOW_ICON :: "data:image/svg\+xml,(.*)"$', source, re.MULTILINE)
if not found:
    sys.exit("no WINDOW_ICON data URL in workbench/workbench.odin")
svg = urllib.parse.unquote(found.group(1))

images = []
for size in SIZES:
    png = resvg_py.svg_to_bytes(svg_string=svg, width=size, height=size)
    images.append(Image.open(io.BytesIO(bytes(png))).convert("RGBA"))

out = ROOT / "packaging" / "windows" / "workbench.ico"
# Pillow writes each size from the largest image unless given them all: append_images supplies the
# renders made at each size, so small icons are drawn small, not shrunk from 256px.
images[-1].save(out, format="ICO", sizes=[(s, s) for s in SIZES], append_images=images[:-1])
print(f"{out} ({', '.join(str(s) for s in SIZES)} px, {out.stat().st_size:,} bytes)")
