#!/usr/bin/env python3
"""
Test props for the multitool
============================

Renders the things the astronaut can work on with the multitool - ore rocks to mine, ore
chunks and metal scrap to gather, cargo crates to lift - in the map's art style (same SDF
renderer, sun, palette and outlines as tools/mars_map_gen.py), places a test set of them on
open ground near the spawn, and lists the dead path lamps by the base that can be fixed.

    python tools/props_gen.py          (run after mars_map_gen.py: it reads the map's data)

Writes assets/maps/red_planet/props/*.png and red_planet_props.json.
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mars_map_gen as M  # noqa: E402
import astronaut_sprite_gen as A  # noqa: E402

OUT = M.OUT
PROPS = os.path.join(OUT, 'props')
TEST_AREA = (-690.0, 1340.0)       # open ground just past the base's airlock, beside the road

M.O_RAMPS.update({
    'rocky':   ['#24181f', '#43303a', '#6a4c50', '#937066'],
    'orevein': ['#7a3412', '#e07a28', '#ffc455', '#fff3c0'],
    'white':   ['#6e6a86', '#a9a7bd', '#dddce8', '#fbfbff'],
})
M.O_NAMES[:] = list(M.O_RAMPS)
M.OID.clear()
M.OID.update({n: i for i, n in enumerate(M.O_NAMES)})
M.O_RGB[:] = [M.hexa(*M.O_RAMPS[n]) for n in M.O_NAMES]
M.EMISSIVE.add(M.OID['orevein'])
P_ = M.P_


# ------------------------------------------------------------------ models (world units, base at the origin)
CRACKS = [A.nz(v) for v in ([0.8, 0.3, 0.5], [-0.4, 0.9, 0.2], [0.2, -0.5, 0.85], [-0.7, -0.6, 0.3])]


def decal_ore_rock(stage):
    """Rock with veins of ore; cracks spread over it as it is mined (glowing hot at the end)."""
    def decal(part, P):
        q = part.sdf.local(P) if hasattr(part.sdf, 'local') else P
        qn = q / np.maximum(np.linalg.norm(q, axis=1), 1e-6)[:, None]
        out = np.full(len(P), M.OID['rocky'])
        vein = np.abs(np.sin(q[:, 0] * 0.9 + q[:, 2] * 0.7) + 0.6 * np.sin(q[:, 1] * 1.3 - q[:, 2] * 0.5)) < 0.16
        out[vein] = M.OID['orevein']
        for i in range(min(stage, 3)):
            wob = 0.05 * np.sin(q[:, 0] * 2.1 + q[:, 1] * 1.7 + i)
            crack = np.abs(qn @ CRACKS[i] + wob) < 0.07
            out[crack] = M.OID['orevein'] if stage >= 3 else M.OID['dark']
        return out
    return decal


def ore_rock(stage):
    rs = np.random.default_rng(31)
    deco = decal_ore_rock(stage)
    parts = [P_('rock', A.Ellipsoid(np.array([0, 0, 4.2]), (7.0, 6.0, 5.2), A.rz(0.4)), 'rocky', 'rock', deco),
             P_('rock', A.Ellipsoid(np.array([3.4, 1.8, 6.6]), (4.2, 3.8, 4.4), A.rz(-0.3)), 'rocky', 'rock', deco),
             P_('rock', A.Ellipsoid(np.array([-3.0, -1.2, 3.0]), (4.0, 3.6, 3.0)), 'rocky', 'rock', deco)]
    for k in range(5):                                  # ore crystals pushing out of it
        d = A.nz([math.cos(k * 1.3 + 0.4), math.sin(k * 1.3 + 0.4), 0.0])
        base = np.array([0, 0, 4.0]) + d * rs.uniform(3.0, 5.0) + np.array([0, 0, rs.uniform(0, 3.5)])
        tip = base + A.nz(d + np.array([0, 0, rs.uniform(0.6, 1.4)])) * rs.uniform(2.6, 4.4)
        parts.append(P_('xtal', A.RoundCone(base, tip, rs.uniform(0.8, 1.2), 0.25), 'orevein', 'xtal'))
    return parts


def ore_chunk(seed):
    rs = np.random.default_rng(seed)
    r = rs.uniform(1.6, 2.2)
    deco = decal_ore_rock(0)
    parts = [P_('rock', A.Ellipsoid(np.array([0, 0, r * 0.8]), (r * 1.2, r, r * 0.85), A.rz(rs.uniform(0, 3))), 'rocky', 'rock', deco)]
    d = A.nz([rs.uniform(-1, 1), rs.uniform(-1, 1), 0.0])
    parts.append(P_('xtal', A.RoundCone(np.array([0, 0, r * 0.9]) + d * r * 0.5,
                                        np.array([0, 0, r * 0.9]) + d * r * 0.5 + A.nz(d + [0, 0, 1.2]) * r * 1.3,
                                        r * 0.45, 0.2), 'orevein', 'xtal'))
    return parts


def scrap(kind):
    if kind == 0:     # a twisted hull plate
        R = A.rz(0.5) @ A.rx(0.25)
        return [P_('plate', A.RoundBox(np.array([0, 0, 1.2]), (4.6, 2.8, 0.45), 0.3, R), 'metal', 'plate'),
                P_('plate2', A.RoundBox(np.array([2.6, 1.0, 2.2]), (2.2, 2.4, 0.4), 0.3, A.rz(0.5) @ A.ry(-0.7)), 'coral', 'plate')]
    if kind == 1:     # a length of pipe with a coupling
        a, b = np.array([-4.0, -1.0, 1.1]), np.array([4.0, 1.5, 1.6])
        return [P_('pipe', A.RoundCone(a, b, 1.0, 1.0), 'dark', 'pipe'),
                P_('ring', A.Torus((a + b) / 2, 1.15, 0.45, M.frame_z(A.nz(b - a))), 'metal', 'pipe')]
    # a broken solar cell
    return [P_('cell', A.RoundBox(np.array([0, 0, 0.9]), (4.0, 3.0, 0.4), 0.25, A.rz(-0.4) @ A.rx(0.3)), 'panel', 'cell',
               M.decal_panel)]


def crate(size):
    k = size
    parts = [P_('body', A.RoundBox(np.array([0, 0, 4.2 * k]), np.array([5.6, 4.6, 4.2]) * k, 0.9 * k, A.rz(0.35)),
                'white', 'crate', decal_crate)]
    R = A.rz(0.35)
    for sx in (-1, 1):                                   # dark bumpers along the bottom and top edges
        for sz in (0.0, 1.0):
            c = np.array([0, 0, (0.7 + sz * 6.9) * k]) + R @ np.array([sx * 5.0 * k, 0, 0])
            parts.append(P_('bumper', A.RoundBox(c, np.array([0.9, 4.9, 0.8]) * k, 0.5 * k, R), 'dark', 'crate'))
    return parts


def decal_crate(part, P):
    q = part.sdf.local(P)
    h = part.sdf.half
    out = np.full(len(P), M.OID['white'])
    out[np.abs(q[:, 2]) < h[2] * 0.16] = M.OID['coral']                           # a coral band round it
    out[(np.abs(q[:, 1]) > h[1] - 0.6) & (np.abs(q[:, 0]) < h[0] * 0.3) & (q[:, 2] > h[2] * 0.3)] = M.OID['darkwin']  # label
    out[(q[:, 2] > h[2] - 0.5) & (np.abs(q[:, 0]) < h[0] * 0.6) & (np.abs(q[:, 1]) < 0.5)] = M.OID['dark']           # lid seam
    return out


# ------------------------------------------------------------------ rendering
def sheet(name, frames_parts):
    """All frames of one prop in a strip; the anchor is where its foot point sits."""
    box = M.sprite_box(frames_parts, pad=3)
    strip = np.concatenate([M.sprite_rgba(M.render_sprite(fp, box)) for fp in frames_parts], axis=1)
    fn = f'props/{name}.png'
    Image.fromarray(strip).save(os.path.join(OUT, fn))
    return dict(file=fn, frames=len(frames_parts), frame_size=[box[2], box[3]],
                anchor=[round(M.AX - box[0], 1), round(M.AY - box[1], 1)])


class Ground:
    """Heights and walkability from the map's walk grid."""

    def __init__(self, meta):
        g = meta['game']
        img = np.array(Image.open(os.path.join(OUT, g['walk_png']))).astype(np.float32)
        self.h = (img[..., 0] * 256 + img[..., 1]) / g['height_scale'] - g['height_offset']
        self.walk = img[..., 2] > 191
        self.n = g['grid_size']

    def cell(self, X, Y):
        u, v = (X + Y) / M.SQ2, (Y - X) / M.SQ2
        return int(v), int(u)

    def z(self, X, Y):
        r, c = self.cell(X, Y)
        return float(self.h[r, c])

    def open_ground(self, X, Y, r):
        for a in np.linspace(0, 2 * math.pi, 12, endpoint=False):
            for rr in (0.0, r * 0.5, r):
                rr_, cc = self.cell(X + math.cos(a) * rr, Y + math.sin(a) * rr)
                if not self.walk[rr_, cc]:
                    return False
        return True


def main():
    meta = json.load(open(os.path.join(OUT, 'red_planet_map.json')))
    M.W, M.H = meta['size']
    M.AX, M.AY = meta['origin_px']
    os.makedirs(PROPS, exist_ok=True)
    ground = Ground(meta)

    sprites = {
        'ore_rock': sheet('ore_rock', [ore_rock(s) for s in range(4)]),
        'ore_chunk': sheet('ore_chunk', [ore_chunk(s) for s in (5, 6, 7)]),
        'scrap': sheet('scrap', [scrap(k) for k in range(3)]),
        'crate': sheet('crate', [crate(1.0)]),
        'crate_small': sheet('crate_small', [crate(0.75)]),
    }
    jobs = dict(ore_rock='mine', ore_chunk='gather', scrap='gather', crate='lift', crate_small='lift')
    radius = dict(ore_rock=8.0, ore_chunk=2.5, scrap=4.0, crate=7.0, crate_small=5.5)
    solid = dict(ore_rock=True, ore_chunk=False, scrap=False, crate=True, crate_small=True)

    # the test set, around a spot beside the road
    want = [('ore_rock', -40, 30, 0), ('ore_rock', 12, 58, 0), ('ore_rock', 52, 18, 0),
            ('scrap', -18, -22, 0), ('scrap', 30, -30, 1), ('scrap', -58, -6, 2), ('scrap', 70, -8, 0), ('scrap', 6, 6, 1),
            ('crate', -64, 60, 0), ('crate_small', -40, 78, 0), ('crate', 78, 46, 0)]
    rs = np.random.default_rng(9)
    objects, placed = [], []
    for k, (kind, dx, dy, frame) in enumerate(want):
        r = radius[kind]
        for attempt in range(60):
            X = TEST_AREA[0] + dx + (rs.normal(0, 6) if attempt else 0)
            Y = TEST_AREA[1] + dy + (rs.normal(0, 6) if attempt else 0)
            if ground.open_ground(X, Y, r + 2) and all(math.hypot(X - x, Y - y) > r + rr + 6 for x, y, rr in placed):
                break
        placed.append((X, Y, r))
        objects.append(dict(id=f'{kind}{k}', kind=kind, sprite=kind, frame=frame, job=jobs[kind], world=[round(X, 2), round(Y, 2)],
                            radius=r, solid=solid[kind]))

    lamps, dead = M.path_lamps()
    lamp_out = []
    for i in sorted(dead):
        X, Y = lamps[i]
        z = ground.z(X, Y)
        head = M.scale_pt(M.cam(X, Y, z) + np.array([0, 0, 14.4]), M.cam(X, Y, z), M.LAMP_SCALE)
        hx, hy = M.project(*head)
        lamp_out.append(dict(world=[round(X, 2), round(Y, 2)], head_px=[round(float(hx), 1), round(float(hy), 1)],
                             height=round(14.4 * M.LAMP_SCALE, 1)))
    out = dict(sprites=sprites, objects=objects, lamps=lamp_out,
               note='Props the multitool works on. world = [X, Y] ground position; anchor = the foot point in each '
                    'frame (frames side by side). job: mine / gather / lift. lamps: dead path lamps to fix.')
    with open(os.path.join(OUT, 'red_planet_props.json'), 'w') as fh:
        json.dump(out, fh, indent=1)
    print(f'{len(objects)} test props, {len(lamp_out)} dead lamps -> {OUT}')


if __name__ == '__main__':
    main()
