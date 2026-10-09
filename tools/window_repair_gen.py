#!/usr/bin/env python3
"""Native storage-window jigsaw assets, using the world's exact shapes and window material.

Owns assets/maps/base_interior/windows/inspection/: intact/damaged panes, six connected
glass fragments per shape, catalog.json and the real six-frame multitool working gauntlet.
The inside-facing silhouettes mirror arc X and invert world Z. All damage is clipped inside
the inspection pane. interior_gen.py owns the pickups and four-view repaired world patches.
Run through make windows (also follows make interior). No external or painted art.
"""
import heapq
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

import astronaut_sprite_gen as A
import interior_gen as I
import mars_map_gen as M

OUT = Path(I.OUT) / 'windows' / 'inspection'
W, H, SIZE = 298, 96, 92
BOARD = (103, 4)


def partition(mask):
    """Geodesic Voronoi: six connected fragments even in the concave crescent."""
    yy, xx = np.nonzero(mask)
    pixels = np.stack([xx, yy], -1)
    seeds = [pixels[int(len(pixels) * .32)]]
    while len(seeds) < 6:
        score = np.min([np.sum((pixels - s) ** 2, axis=1) for s in seeds], axis=0)
        seeds.append(pixels[np.argmax(score)])
    owner = np.full(mask.shape, -1, np.int8)
    distance = np.full(mask.shape, np.inf)
    heap = []
    for i, (x, y) in enumerate(seeds):
        owner[y, x], distance[y, x] = i, 0
        heapq.heappush(heap, (0., int(y), int(x), i))
    while heap:
        d, y, x, i = heapq.heappop(heap)
        if d != distance[y, x]:
            continue
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1)):
            nx, ny = x + dx, y + dy
            if not (0 <= nx < SIZE and 0 <= ny < SIZE and mask[ny, nx]):
                continue
            dd = d + (math.sqrt(2) if dx and dy else 1)
            if dd < distance[ny, nx]:
                distance[ny, nx], owner[ny, nx] = dd, i
                heapq.heappush(heap, (dd, ny, nx, i))
    assert np.all(owner[mask] >= 0)
    return owner


def inspection(kind, angle):
    yy, xx = np.mgrid[:H, :W]
    per_px = (I.WIN[1] - I.WIN[0]) / H
    arc = math.radians(angle) * I.r_in('storage') - (xx.ravel() + .5 - W / 2) * per_px
    z = I.WIN[1] - (yy.ravel() + .5) * per_px
    xs = np.floor(xx.ravel() * per_px * 2 + 384).astype(int)
    ys = np.floor(yy.ravel() * per_px * 2 + 144).astype(int)
    col, _ = I.window_material(arc, z - I.WIN[0], M.BAYER[ys % 4, xs % 4], xs, ys)
    intact = np.clip(col, 0, 255).astype(np.uint8).reshape(H, W, 3)
    Image.fromarray(intact).save(OUT / f'{kind}_pane.png')
    poly, cracks = M.hole_shape(kind, (I.WIN[1] - I.WIN[0]) / 2.5 * 1.15,
                               np.random.default_rng(int(angle) % 360))
    y, x = np.mgrid[:SIZE, :SIZE]
    lx, ly = (46 - (x.ravel() + .5)) / 7, (46 - (y.ravel() + .5)) / 7
    mask = M._poly_inside(lx, ly, poly).reshape(SIZE, SIZE)
    owners = partition(mask)
    damage = Image.new('RGBA', (W, H))
    draw = ImageDraw.Draw(damage)
    aperture = tuple((I.SUNLIGHT * .5 + 255 * .5).astype(int)) + (255,)
    # Literal pixel edges match the accepted draft, never extend beyond the pane inset.
    rim = ndi.binary_dilation(mask) & ~mask
    for yy_, xx_ in zip(*np.nonzero(mask | rim)):
        draw.point((BOARD[0] + int(xx_), BOARD[1] + int(yy_)), fill=aperture if mask[yy_, xx_] else (255, 255, 255, 255))
    for stroke in cracks:
        points = [(BOARD[0] + round(46 - v[0] * 7), BOARD[1] + round(46 - v[1] * 7)) for v in stroke]
        draw.line(points, fill=(237, 249, 245, 255), width=1)
    rgba = np.array(damage)
    rgba[:2] = rgba[-2:] = 0
    rgba[:, :2] = rgba[:, -2:] = 0
    Image.fromarray(rgba).save(OUT / f'{kind}_damage.png')
    pieces = []
    for i in range(6):
        hit = owners == i
        assert ndi.label(hit, np.ones((3, 3)))[1] == 1, (kind, i)
        yy_, xx_ = np.nonzero(hit)
        x0, y0, x1, y1 = xx_.min(), yy_.min(), xx_.max() + 1, yy_.max() + 1
        ax, ay = int((x0 + x1 - 1) // 2), int((y0 + y1 - 1) // 2)
        fragment = np.zeros((SIZE, SIZE, 4), np.uint8)
        fragment[hit, :3] = intact[BOARD[1]:BOARD[1] + SIZE, BOARD[0]:BOARD[0] + SIZE][hit]
        fragment[hit, 3] = 255
        edge = hit & ~ndi.binary_erosion(hit)
        fragment[edge, :3] = (217, 245, 237)
        fragment[edge & ((x + y) % 4 == 0), :3] = 255
        fn = f'{kind}_piece_{i}.png'
        Image.fromarray(fragment[y0:y1, x0:x1]).save(OUT / fn)
        pieces.append(dict(file=fn, target=[BOARD[0] + ax, BOARD[1] + ay], anchor=[ax - int(x0), ay - int(y0)],
                           rotation=[1, 3, 2, 1, 2, 3][i]))
    return dict(id=kind, pane=f'{kind}_pane.png', damage=f'{kind}_damage.png', pieces=pieces,
                cost=6, scan_seconds=2.4, outline=poly.tolist(), angle=angle, inside_facing=True)


def tool_strip():
    frames = []
    for i in range(6):
        pose = A.pose_use(i / 6)
        parts, _ = A.build_parts(pose)
        tip, compass = pose['_tip'], 90
        turn = A.rz(-compass * A.D2R)
        base = A.Camera(W=40, H=32, anchor=(0, 0), scale=.4330127)
        anchor = (30 - tip @ (base.r @ turn) / base.s, 16 + tip @ (base.u @ turn) / base.s)
        camera = A.Camera(W=40, H=32, anchor=anchor, scale=base.s)
        camera.L = A.nz([-.42, -.62, .66])
        frames.append(A.render([p for p in parts if p.group == 'tool'], compass, cam=camera, center=tip, radius=18))
    Image.fromarray(np.concatenate(frames, axis=1)).save(OUT / 'multitool_fix.png')


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    catalog = {kind: inspection(kind, angle) for kind, angle in I.HOLES}
    tool_strip()
    (OUT / 'catalog.json').write_text(json.dumps(catalog, indent=1), encoding='utf-8')
    print('Window inspections: three source-matched silhouettes, eighteen connected pieces and working gauntlet.')


if __name__ == '__main__':
    build()
