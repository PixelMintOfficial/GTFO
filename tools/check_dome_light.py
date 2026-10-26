#!/usr/bin/env python3
"""Regression for floating night glare: opaque native dome shells cannot emit old interior light.
Uses the generator's ray/depth visibility, all four views, and verifies actual light PNGs.
"""
import json
import numpy as np
from PIL import Image
import mars_map_gen as M

M._snapshot()
failures = 0
for k in range(4):
    M.VIEW, M.SFX = k, M.view_sfx(k)
    M.apply_view_constants(k)
    meta = json.load(open(f'{M.OUT}/red_planet_map{M.SFX}.json'))
    M.W, M.H = meta['size']
    M.AX, M.AY = meta['origin_px']
    encoded = np.asarray(Image.open(f"{M.OUT}/{meta['game']['depth_png']}")).astype(float)
    depth = (encoded[...,0]*256 + encoded[...,1])/M.DEPTH_SCALE
    shell = M.opaque_dome_pixels(depth)
    light = np.asarray(Image.open(f"{M.OUT}/{meta['game']['light_png']}"))
    stray = np.count_nonzero(light[shell])
    failures += int(stray != 0)
    print(f'view {k}: {shell.sum()} visible shell pixels, {stray} stale emissive pixels')
print(f'DOME LIGHT: 4 checks, {failures} failures')
raise SystemExit(bool(failures))
