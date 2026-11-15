#!/usr/bin/env python3
"""Assemble the public website into build/site/ (deploy that folder as a static site).

    /                  the landing page (site/: index.html, style.css, main.js, img/)
    /play/             the browser version (build/web-split, from tools/web_split_pck.py)
    /downloads/        the Windows and Linux zips (build/GTFO-*.zip) cut into parts under 100 MB,
                       plus manifest.json (sizes, part sizes and SHA-256) that site/main.js reads

Hosts like Vercel refuse any single file over 100 MB, so the zips are split and the page's download
button joins them in the browser and checks the SHA-256 before it saves the file.

    make export                          # the three builds and their zips
    python3 tools/web_split_pck.py       # build/web-split
    python3 tools/build_site.py          # build/site
    vercel deploy build/site --prod

site/img/*.png are 1920x1080 captures of the game (5x its 384x216 viewport) with the HUD and the cutscene bars
cropped off: the overworld with --time=17.5 or --time=22 --suit-light, --spawn=230,2300 (forest), --spawn=1050,1500
(ice), the opening with --intro --seconds=3.2 / 22 / 31, and the comms room with --comms-reply --reply-auto=6
--seconds=7.5.
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / 'site'
BUILD = ROOT / 'build'
OUT = BUILD / 'site'
PARTS = 3

ZIPS = {'windows': BUILD / 'GTFO-windows.zip', 'linux': BUILD / 'GTFO-linux.zip'}
WEB = BUILD / 'web-split'

for p in [WEB, *ZIPS.values()]:
    if not p.exists():
        sys.exit(f'missing {p}: run make export and tools/web_split_pck.py first')

if OUT.exists():
    shutil.rmtree(OUT)
shutil.copytree(SITE, OUT)
shutil.copytree(WEB, OUT / 'play')

downloads = OUT / 'downloads'
downloads.mkdir()
manifest = {}
for os_name, zip_path in ZIPS.items():
    data = zip_path.read_bytes()
    size = -(-len(data) // PARTS)
    names, sizes = [], []
    for i in range(PARTS):
        chunk = data[i * size:(i + 1) * size]
        name = f'{zip_path.name}.part{i}'
        (downloads / name).write_bytes(chunk)
        assert len(chunk) < 100 * 1024 * 1024, name
        names.append(f'downloads/{name}')
        sizes.append(len(chunk))
    manifest[os_name] = {'name': zip_path.name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                         'parts': names, 'partSizes': sizes}
(downloads / 'manifest.json').write_text(json.dumps(manifest, indent=1))

total = sum(f.stat().st_size for f in OUT.rglob('*') if f.is_file())
print(f'{OUT}: {total / 1e6:.0f} MB')
for os_name, m in manifest.items():
    print(f'  {os_name}: {m["size"] / 1e6:.1f} MB in {len(m["parts"])} parts, sha256 {m["sha256"][:16]}...')
