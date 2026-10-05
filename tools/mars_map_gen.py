#!/usr/bin/env python3
"""
Red-planet outpost map generator
================================

Renders the whole outpost map with the same 2:1 isometric camera, light direction
and palette family as the astronaut sprites, at PX pixels per world unit of height.
The astronaut sprite is drawn 1:1 on top of this map, so with PX = 2 the astronaut
(44 px tall) is 22 world units tall: about as tall as a path lamp.

    python tools/mars_map_gen.py

Pipeline
  1. World: heightfield on a 1-unit grid - dunes, wind ripples, two-tier mesas,
     stepped pits, craters, boulders, spiky mountain ranges with frosted tips - and
     flattened pads for domes, paths, the landing pad and the solar field.
  2. Terrain: exact per-pixel ray/heightfield hits, solved per screen column with a
     running-max + binary search (no ray stepping), plus the cut-away crust walls.
  3. Light: cel-shaded ramps with ordered dithering, a sun shadow map, crevice AO,
     strata bands on cliff faces, rim highlights on cliff lips, lamp light pools.
  4. Props: SDF models ray-marched straight to pixels. Bases are modelled at design
     size and scaled up by DOME_SCALE as a whole (domes, interiors, airlocks, tower).
  5. Glass: back shell, interior, front shell with fresnel tint, ribs and shine.
  6. Lines, glows, space backdrop, and the game data (depth map, walk/height grid).
"""
import json
import math
import os
import sys
import time

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import astronaut_sprite_gen as A  # noqa: E402  (shared SDF primitives, ray-marcher, palette)

ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'assets', 'maps', 'red_planet')

# ================================================================== camera / scale
DEG = math.pi / 180
PX = 2.0                          # pixels per world unit of height (map pixel density)
S = math.cos(30 * DEG) / PX       # world units per pixel along the camera plane
KY = math.tan(30 * DEG)           # height-equivalent of one unit of depth
SQ2 = math.sqrt(2.0)
N = 1800                          # map side in world units (grid cells are 1 unit)
HALF = N / SQ2
W, H, AX, AY = 0, 0, 0.0, 0.0     # image frame, set by set_frame() once the world is known
F = np.array([0.0, math.cos(30 * DEG), -math.sin(30 * DEG)])
CR = np.array([1.0, 0.0, 0.0])
CU = np.array([0.0, math.sin(30 * DEG), math.cos(30 * DEG)])
SUN = A.nz([-0.62, -0.32, 0.62])  # same quadrant as the sprite light, a little lower for longer shadows
VIEWPORT = (384, 216)             # game view in px (project.godot); no two domes may share one
SEED = 11

# ================================================================== layout (camera X/Y, world units)
DOME_SCALE = 2.5                  # bases are designed at R0 and scaled as a whole (doors ~1.6x the astronaut)
LAMP_SCALE = 1.5                  # path lamps ~22 units: as tall as the astronaut
PAD_SCALE = 2.2
SOLAR_SCALE = 1.6
DOMES = {
    'base':    dict(X=-790.0, Y=1290.0, R0=120.0, ribs=36),
    'nursery': dict(X=900.0, Y=1300.0, R0=80.0, ribs=24),
    'comms':   dict(X=120.0, Y=540.0, R0=80.0, ribs=24),
}
for _d in DOMES.values():
    _d['R'] = _d['R0'] * DOME_SCALE
PAD = dict(X=-560.0, Y=820.0, R0=40.0)
PAD['R'] = PAD['R0'] * PAD_SCALE
SOLAR = dict(X=-420.0, Y=1760.0)
TOWER_TOP = 150.0                 # design units (scaled with the comms dome)
PATHS = [
    [(-790, 1290), (-420, 1480), (0, 1580), (450, 1520), (900, 1300)],      # base -> nursery
    [(-790, 1290), (-500, 1050), (-200, 780), (120, 540)],                  # base -> comms
    [(120, 540), (420, 640), (700, 900), (900, 1300)],                      # comms -> nursery
    [(-790, 1290), (-560, 820)],                                            # base -> landing pad
]
PATH_HALF = 9.5
WALK_SLOPE = 0.78                 # steepest ground an astronaut can walk (~38 degrees)
RAMP_SLOPE = 0.42                 # sand drifts piled against cliffs: gentle enough to climb
DRIFT_SIDE = 0.5                  # drift flanks: steep sand, still walkable on the diagonal
CRATERS = [  # X, Y, radius, depth, style: 'new' = rounded walkable bowl, 'old' = steep walls, jump in
    (-200.0, 1250.0, 86.0, 26.0, 'new'), (500.0, 1750.0, 60.0, 19.0, 'old'), (-320.0, 2060.0, 44.0, 14.0, 'old'),
    (-250.0, 420.0, 40.0, 13.0, 'new'), (700.0, 1650.0, 70.0, 24.0, 'old')]
# spiky mountain ranges: centre X, Y, peaks, spread, min/max height
SPIKE_RANGES = [
    (-420.0, 2080.0, 9, 150.0, 90.0, 190.0),     # back-left ridge
    (300.0, 2050.0, 6, 110.0, 80.0, 160.0),      # back-right
    (-50.0, 2250.0, 7, 130.0, 100.0, 210.0),     # the far back: a skyline
    (520.0, 1150.0, 5, 80.0, 90.0, 180.0),       # between the comms and the nursery
    (-680.0, 1720.0, 6, 90.0, 80.0, 160.0),      # back-left corner
    (-120.0, 260.0, 6, 110.0, 70.0, 150.0),      # front
    (-480.0, 600.0, 5, 90.0, 70.0, 140.0),       # front-left
    (150.0, 1150.0, 3, 50.0, 130.0, 210.0),      # lone spires in the middle
]


def to_grid(X, Y):
    return (X + Y) / SQ2, (Y - X) / SQ2


def to_cam(u, v):
    return (u - v) / SQ2, (u + v) / SQ2


def project(X, Y, Z):
    return AX + X / S, AY - (KY * Y + Z) * PX


def set_frame(G):
    """Size the image so the whole slab, its tallest peaks and the tower fit."""
    global W, H, AX, AY
    c = np.arange(N, dtype=np.float32) + 0.5
    Yg = (c[:, None] + c[None, :]) / SQ2
    top = float(np.max(KY * Yg + G['H']))
    cm = DOMES['comms']
    top = max(top, KY * cm['Y'] + (TOWER_TOP + 32) * DOME_SCALE)
    W = int(2 * HALF / S) + 240
    AX = W / 2.0
    AY = float(int(top * PX) + 90)
    H = int(AY + 120 * PX + 60)
    print(f'frame {W}x{H}')


def hexa(*hs):
    return np.array([A.hex2rgb(h) for h in hs], np.uint8)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


BAYER = (np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]], np.float32) + 0.5) / 16 - 0.5

# ================================================================== palette
# Terrain ramps run dark -> light; the dark ends lean violet so shadows stay cosy, lights lean peach.
T_RAMPS = {
    'ground': hexa('#1d1127', '#33172c', '#4f2133', '#6e2e38', '#8e403d', '#a95747', '#be6f53', '#d28b64'),
    'mesa':   hexa('#24152a', '#3e2037', '#5d2d3e', '#804046', '#a1574e', '#bb7059', '#d18d6b', '#e5ac82'),
    'pit':    hexa('#120c1c', '#1c1226', '#2a182e', '#3d2034', '#532a39', '#6c3940', '#844a47'),
    'path':   hexa('#36203a', '#573543', '#7d4f4c', '#a26c5a', '#bf8a6a', '#d6a67c', '#e8c294'),
    'rock':   hexa('#170e1e', '#281627', '#3f1f2c', '#5c2d34', '#7e413c', '#9e5a48', '#b97455'),
    'floor':  hexa('#2a2233', '#433747', '#62535e', '#877573', '#ab9789', '#cab49f', '#e4d2bb'),
    'walk':   hexa('#341f2e', '#552d36', '#7a403e', '#9c5848', '#b97257', '#cf8e6a', '#e2ab82'),
}
STRATA = [
    hexa('#25122a', '#45192e', '#6d2a36', '#953f3b', '#b65843'),   # rust
    hexa('#2c1729', '#542a35', '#82483f', '#ae694c', '#cd895f'),   # ochre
    hexa('#1c0f24', '#33172d', '#512033', '#722e3a', '#8f4140'),   # oxblood
    hexa('#322033', '#5f3d40', '#8d614f', '#b98864', '#d9ab80'),   # pale clay
    hexa('#23132a', '#3f1f39', '#642e41', '#8a4548', '#a95e50'),   # mauve
]
SPIKE_STRATA = [                                                   # darker basalt for the spires
    hexa('#170d1e', '#2b1729', '#462232', '#66333b', '#854846'),
    hexa('#140c1b', '#251525', '#3c1f2d', '#572c35', '#73403f'),
    hexa('#1e1226', '#382034', '#58323f', '#7c4b4b', '#9c6558'),
]
FROST = hexa('#3a3152', '#695d84', '#a094b6', '#d6cbe0', '#f4edf4')
O_RAMPS = {
    'metal': A.RAMPS['suit'], 'pack': A.RAMPS['pack'], 'dark': A.RAMPS['dark'], 'coral': A.RAMPS['coral'],
    'mustard': A.RAMPS['mustard'], 'teal': A.RAMPS['teal'], 'wood': A.RAMPS['wood'],
    'red':      ['#5a1a2e', '#962a36', '#cf4440', '#f2735a'],
    'tire':     ['#1a1424', '#2a2236', '#3e3450', '#5a4f6e'],
    'leaf':     ['#1d3637', '#2c6249', '#4b9558', '#93cf75'],
    'leaf2':    ['#213f3c', '#38725a', '#62aa73', '#ade29b'],
    'blossom':  ['#6e3355', '#b5617f', '#eb9cad', '#ffd5d8'],
    'soil':     ['#22141f', '#382028', '#4f2e2f', '#683f38'],
    'panel':    ['#10142b', '#1a2649', '#284270', '#4d78a8'],
    'pline':    ['#3a4a70', '#5a73a0', '#86a4c8', '#c4dcef'],
    'concrete': ['#4a4058', '#71667f', '#9d91a6', '#c7bcc4'],
    'glow':     A.RAMPS['bulb'],
    'window':   ['#8a5530', '#e0a050', '#ffd27a', '#fff4d0'],
    'screen':   ['#1b4f5e', '#3fb3a6', '#7fe6cf', '#d8fff2'],
    'beacon':   ['#7a1f2e', '#d8443e', '#ff7a5a', '#ffd6bf'],
    'void':     ['#000000'] * 4,
}
O_NAMES = list(O_RAMPS)
OID = {n: i for i, n in enumerate(O_NAMES)}
O_RGB = [hexa(*O_RAMPS[n]) for n in O_NAMES]
EMISSIVE = {OID[n] for n in ('glow', 'window', 'screen', 'beacon')}
OUTLINE = np.array(A.hex2rgb(A.OUTLINE), np.uint8)


# ================================================================== noise
def _noise(feature, seed, aniso=(1.0, 1.0)):
    fu, fv = max(2.0, feature * aniso[0]), max(2.0, feature * aniso[1])
    rs = np.random.default_rng(seed)
    mu, mv = int(N / fu) + 6, int(N / fv) + 6
    g = rs.standard_normal((mu, mv)).astype(np.float32)
    up = ndi.zoom(g, (fu, fv), order=3, prefilter=False)
    ou, ov = int(2 * fu), int(2 * fv)
    out = up[ou:ou + N, ov:ov + N]
    return (out - out.mean()) / (out.std() + 1e-6)


def fbm(feature, octaves, seed, aniso=(1.0, 1.0), gain=0.5):
    acc = np.zeros((N, N), np.float32)
    amp = 1.0
    for o in range(octaves):
        acc += amp * _noise(feature / 2 ** o, SEED * 1000 + seed * 31 + o, aniso)
        amp *= gain
    return ((acc - acc.mean()) / acc.std()).astype(np.float32)


def catmull(points, step=0.5):
    P = np.array(points, float)
    P = np.vstack([P[0], P, P[-1]])
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        n = max(2, int(np.linalg.norm(p2 - p1) / step))
        t = np.linspace(0, 1, n, endpoint=False)[:, None]
        out.append(0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t ** 2
                          + (-p0 + 3 * p1 - 3 * p2 + p3) * t ** 3))
    out.append(P[-2][None])
    return np.vstack(out)


def sample(grid, u, v, order=1):
    return ndi.map_coordinates(grid, [u - 0.5, v - 0.5], order=order, mode='nearest')


def airlock_ends():
    """(dome, direction) for every path end that meets a dome."""
    out = []
    for pts in PATHS:
        for end, nxt in ((pts[0], pts[1]), (pts[-1], pts[-2])):
            for d in DOMES.values():
                if math.hypot(end[0] - d['X'], end[1] - d['Y']) < 1:
                    dirv = np.array(nxt, float) - np.array([d['X'], d['Y']])
                    out.append((d, dirv / np.linalg.norm(dirv)))
    return out


def solar_panels():
    """Grid positions (u, v) of the solar panels."""
    su, sv = to_grid(SOLAR['X'], SOLAR['Y'])
    return [(su + (-48 + col * 24) * SOLAR_SCALE, sv + (-24 + row * 24) * SOLAR_SCALE)
            for row in range(3) for col in range(5)]


# ================================================================== world
def build_world():
    t0 = time.time()
    c = np.arange(N, dtype=np.float32) + 0.5
    U, V = np.meshgrid(c, c, indexing='ij')
    Xg, Yg = (U - V) / SQ2, (U + V) / SQ2
    rs = np.random.default_rng(SEED + 7)

    dome_r = {k: np.hypot(Xg - d['X'], Yg - d['Y']) for k, d in DOMES.items()}
    rim_d = np.minimum.reduce([dome_r[k] - d['R'] for k, d in DOMES.items()])
    pad_d = np.hypot(Xg - PAD['X'], Yg - PAD['Y']) - PAD['R']
    su, sv = to_grid(SOLAR['X'], SOLAR['Y'])
    solar_d = np.maximum(np.abs(U - su) - 62 * SOLAR_SCALE, np.abs(V - sv) - 42 * SOLAR_SCALE)

    raster = np.zeros((N, N), bool)
    curves = []
    for pts in PATHS:
        cp = catmull(pts)
        curves.append(cp)
        pu, pv = to_grid(cp[:, 0], cp[:, 1])
        ok = (pu >= 0) & (pu < N) & (pv >= 0) & (pv < N)
        raster[pu[ok].astype(int), pv[ok].astype(int)] = True
    path_d = ndi.distance_transform_edt(~raster).astype(np.float32)

    crater_keep = np.minimum.reduce([np.hypot(Xg - x, Yg - y) - r * 1.35 for x, y, r, *_ in CRATERS])
    struct_d = np.minimum.reduce([rim_d, path_d - PATH_HALF, pad_d, solar_d])
    keep = np.minimum.reduce([rim_d - 80, path_d - 30, pad_d - 40, solar_d - 30, crater_keep])
    free = smoothstep(0, 70, keep)

    def soft(mask, sigma=1.1):
        return smoothstep(0.2, 0.8, ndi.gaussian_filter(mask.astype(np.float32), sigma))

    # --- mesas: a ridge of them along the back and the far edges, a few loners in between
    m = fbm(240, 5, 1) + 1.15 * smoothstep(1750, 2450, Yg) + 0.75 * smoothstep(850, 1200, np.abs(Xg))
    m += 0.22 * fbm(28, 3, 2)
    m -= 4.0 * (1 - free)
    t1, t2 = np.quantile(m, [0.80, 0.935])
    tier1 = ndi.binary_opening(m > t1, iterations=5)
    tier1 = ndi.binary_closing(tier1, iterations=2)
    tier2 = ndi.binary_opening(m > t2, iterations=4) & ndi.binary_erosion(tier1, iterations=7)
    s1, s2 = soft(tier1), soft(tier2)
    mesa = 34.0 * s1 + 26.0 * s2 + 1.2 * fbm(60, 2, 3) * s1
    talus = (7.0 * ndi.gaussian_filter(tier1.astype(np.float32), 8) * (1 - s1)
             + 4.0 * ndi.gaussian_filter(tier2.astype(np.float32), 4) * s1 * (1 - s2))
    del m

    # --- stepped pits, never next to a mesa
    mesa_zone = ndi.binary_dilation(tier1, iterations=30)
    p = fbm(220, 5, 4) + 0.3 * fbm(26, 3, 5) - 4.0 * (1 - free) - 4.0 * mesa_zone
    q1, q2 = np.quantile(p, [0.935, 0.975])
    pit1 = ndi.binary_opening(p > q1, iterations=3)
    pit2 = ndi.binary_opening(p > q2, iterations=2) & ndi.binary_erosion(pit1, iterations=6)
    pits = -22.0 * soft(pit1) - 20.0 * soft(pit2)
    del p

    # --- craters (hand placed + scattered small ones)
    craters = list(CRATERS)
    tries = 0
    while len(craters) < 34 and tries < 4000:
        tries += 1
        X, Y = rs.uniform(-1150, 1150), rs.uniform(150, 2400)
        if abs(X) + abs(Y - HALF) > HALF - 40:
            continue
        u, v = to_grid(X, Y)
        iu, iv = int(u), int(v)
        R = float(rs.choice([7, 9, 11, 14, 18, 24, 30]))
        if free[iu, iv] < 0.97 or tier1[iu, iv] or pit1[iu, iv] or mesa_zone[iu, iv]:
            continue
        if any(math.hypot(X - x, Y - y) < R + r + 20 for x, y, r, *_ in craters):
            continue
        craters.append((X, Y, R, R * 0.36, 'old' if len(craters) % 2 else 'new'))
    crater_h = np.zeros((N, N), np.float32)
    for X, Y, R, depth, style in craters:
        u0, v0 = to_grid(X, Y)
        win = int(R * 1.9) + 2
        a0, a1 = max(0, int(u0) - win), min(N, int(u0) + win)
        b0, b1 = max(0, int(v0) - win), min(N, int(v0) + win)
        r = np.hypot(U[a0:a1, b0:b1] - u0, V[a0:a1, b0:b1] - v0) / R
        if style == 'new':   # rounded bowl: walls stay walkable all the way down
            bowl = np.where(r < 1, -depth * np.cos(np.clip(r, 0, 1) * math.pi / 2) ** 2, 0.0)
            rim = 0.14 * depth * np.exp(-((r - 1) / 0.25) ** 2)
        else:                # old crater: a steep band under a sharp rim, jump down into it
            bowl = np.where(r < 1, depth * (r * r - 1), 0.0)
            rim = 0.24 * depth * np.exp(-((r - 1) / 0.2) ** 2)
        crater_h[a0:a1, b0:b1] += bowl + rim

    # --- spiky mountains: star-shaped cones with concave flanks and gullies
    spike_h = np.zeros((N, N), np.float32)
    spike_rel = np.zeros((N, N), np.float32)
    jag = fbm(18, 2, 14)
    peaks = 0
    for cx_, cy_, count, spread, hmin, hmax in SPIKE_RANGES:
        placed = 0
        for _ in range(count * 30):
            if placed >= count:
                break
            X = cx_ + rs.normal(0, spread * 0.6)
            Y = cy_ + rs.normal(0, spread * 0.6)
            Hs = float(rs.uniform(hmin, hmax))
            Rs = Hs * float(rs.uniform(0.38, 0.55))
            if abs(X) + abs(Y - HALF) > HALF - 20:
                continue
            u0, v0 = to_grid(X, Y)
            iu, iv = int(u0), int(v0)
            if not (0 <= iu < N and 0 <= iv < N) or struct_d[iu, iv] < Rs * 1.1 + 30:
                continue
            win = int(Rs * 1.15) + 2
            a0, a1 = max(0, iu - win), min(N, iu + win)
            b0, b1 = max(0, iv - win), min(N, iv + win)
            du_, dv_ = U[a0:a1, b0:b1] - u0, V[a0:a1, b0:b1] - v0
            th = np.arctan2(dv_, du_)
            sides = int(rs.integers(4, 7))
            sector = 2 * math.pi / sides
            rel = np.mod(th - rs.uniform(0, sector), sector) - sector / 2
            edge = math.cos(sector / 2) / np.cos(rel)            # regular polygon footprint: flat facets
            rr = np.hypot(du_, dv_) / (Rs * edge) * (1 + 0.035 * jag[a0:a1, b0:b1])
            prof = (Hs * np.clip(1 - rr, 0, 1) ** 1.45).astype(np.float32)
            better = prof > spike_h[a0:a1, b0:b1]
            spike_h[a0:a1, b0:b1] = np.where(better, prof, spike_h[a0:a1, b0:b1])
            spike_rel[a0:a1, b0:b1] = np.where(better, prof / Hs, spike_rel[a0:a1, b0:b1])
            placed += 1
            peaks += 1

    # --- base dunes + wind ripples
    dunes = 2.4 * fbm(170, 4, 6) + 0.6 * fbm(36, 2, 7)
    ripples = 0.28 * np.sin((U * 0.83 + V * 0.55) / 2.6 + 2.6 * fbm(90, 2, 8))
    Hf = dunes + ripples + mesa + talus + pits + crater_h + spike_h
    ground_ok = (free > 0.3) & ~ndi.binary_dilation(pit1, iterations=3) & (spike_h < 1) & (path_d > PATH_HALF + 6)
    before = Hf.copy()
    drifts = carve_drifts(Hf, U, V, tier1, tier2, pit1, pit2, ground_ok, rs, jag)
    drifted = Hf > before + 0.5
    del before

    # --- flatten under paths, pads and domes
    w = smoothstep(PATH_HALF - 2, PATH_HALF + 9, path_d)
    Hf = Hf * w + ndi.gaussian_filter(dunes, 6) * 0.35 * (1 - w)
    Hf *= smoothstep(6, 40, pad_d)
    Hf *= smoothstep(0, 30, solar_d)
    for k, d in DOMES.items():
        Hf *= smoothstep(d['R'] + 15, d['R'] + 100, dome_r[k])

    # --- boulders, crowding at cliff feet and crater rims, plus a few big ones
    near_cliff = np.clip(ndi.gaussian_filter((tier1 | pit1).astype(np.float32), 9) * 3.0, 0, 1)
    drift_zone = ndi.binary_dilation(drifted, iterations=6)          # keep the way up clear
    rock = np.zeros((N, N), np.float32)
    placed, tries = 0, 0
    while placed < 1150 and tries < 50000:
        tries += 1
        u, v = rs.uniform(14, N - 14, 2)
        iu, iv = int(u), int(v)
        big = placed < 50
        if free[iu, iv] < 0.9 or drift_zone[iu, iv] or (not big and rs.random() > 0.08 + 0.9 * near_cliff[iu, iv]):
            continue
        r = float(rs.uniform(6, 11)) if big else float(np.clip(1.3 + rs.gamma(1.4, 0.9), 1.3, 5.5))
        win = int(r) + 2
        a0, a1, b0, b1 = iu - win, iu + win + 1, iv - win, iv + win + 1
        d = np.hypot(U[a0:a1, b0:b1] - u, V[a0:a1, b0:b1] - v) / r
        bump = r * (0.7 if big else 0.8) * np.sqrt(np.clip(1 - d * d, 0, 1))
        rock[a0:a1, b0:b1] = np.maximum(rock[a0:a1, b0:b1], bump)
        placed += 1
    Hf = Hf + rock

    for k, d in DOMES.items():                      # dome floors: a low plinth
        Hf[dome_r[k] < d['R']] = 0.6 * DOME_SCALE
    Hf = Hf.astype(np.float32)

    # --- materials
    mat = np.zeros((N, N), np.uint8)                # 0 ground
    mat[mesa > 16] = 1                              # mesa tops
    mat[(pits < -10)] = 2                           # pit floors
    mat[rock > 0.35] = 4
    mat[spike_h > 4] = 6                            # spires
    mat[drifted] = 0                                # sand drifts read as ground
    for k, d in DOMES.items():
        mat[dome_r[k] < d['R']] = 5

    # --- interior walkways: from each airlock straight to the dome centre
    walk_d = np.full((N, N), np.inf, np.float32)
    for d, dirv in airlock_ends():
        k = next(k for k, dd in DOMES.items() if dd is d)
        rel_x, rel_y = Xg - d['X'], Yg - d['Y']
        t = np.clip(rel_x * dirv[0] + rel_y * dirv[1], 0, d['R'])
        dist = np.hypot(rel_x - t * dirv[0], rel_y - t * dirv[1])
        walk_d = np.minimum(walk_d, np.where(dome_r[k] < d['R'], dist, np.inf))

    # --- lamps along the paths
    lamps = []
    for cp in curves:
        seg = np.linalg.norm(np.diff(cp, axis=0), axis=1)
        s = np.concatenate([[0], np.cumsum(seg)])
        side = 1
        for target in np.arange(70, s[-1] - 50, 120):
            i = int(np.searchsorted(s, target))
            p0, p1 = cp[max(0, i - 2)], cp[min(len(cp) - 1, i + 2)]
            tdir = (p1 - p0) / max(np.linalg.norm(p1 - p0), 1e-6)
            nrm = np.array([-tdir[1], tdir[0]])
            X, Y = cp[i] + nrm * (PATH_HALF + 5.5) * side
            side = -side
            if min(math.hypot(X - d['X'], Y - d['Y']) - d['R'] for d in DOMES.values()) < 40:
                continue
            if math.hypot(X - PAD['X'], Y - PAD['Y']) < PAD['R'] + 16:
                continue
            lamps.append((float(X), float(Y)))

    # warm light pools: path lamps + the lit dome interiors
    glow = np.zeros((N, N), np.float32)
    pool = 19.0 * LAMP_SCALE
    for X, Y in lamps:
        u0, v0 = to_grid(X, Y)
        r_ = int(pool) + 2
        a0, a1, b0, b1 = int(u0) - r_, int(u0) + r_ + 1, int(v0) - r_, int(v0) + r_ + 1
        d = np.hypot(U[a0:a1, b0:b1] - u0, V[a0:a1, b0:b1] - v0) / pool
        glow[a0:a1, b0:b1] = np.maximum(glow[a0:a1, b0:b1], np.clip(1 - d, 0, 1) ** 1.6)
    for k, d in DOMES.items():
        inside = dome_r[k] < d['R']
        glow[inside] = np.maximum(glow[inside], 0.55 * np.clip(1 - (dome_r[k][inside] / d['R']) ** 2, 0, 1))
        spill_w = 34 * 1.6
        spill = (dome_r[k] >= d['R']) & (dome_r[k] < d['R'] + spill_w)
        glow[spill] = np.maximum(glow[spill], 0.42 * np.clip(1 - (dome_r[k][spill] - d['R']) / spill_w, 0, 1) ** 1.5)

    # --- normals (camera frame), AO, texture fields
    Hu, Hv = np.gradient(Hf)
    dX, dY = (Hu - Hv) / SQ2, (Hu + Hv) / SQ2
    inv = 1.0 / np.sqrt(dX * dX + dY * dY + 1.0)
    ao = (np.clip((ndi.gaussian_filter(Hf, 4) - Hf) / 5.0, 0, 1) * 0.8
          + np.clip((ndi.gaussian_filter(Hf, 14) - Hf) / 18.0, 0, 1) * 0.6)

    G = dict(H=Hf, nX=(-dX * inv).astype(np.float32), nY=(-dY * inv).astype(np.float32),
             nZ=inv.astype(np.float32), ao=ao.astype(np.float32), mat=mat, path_d=path_d, glow=glow,
             walk_d=np.minimum(walk_d, 99).astype(np.float32), albedo=fbm(380, 3, 13),
             tex=(0.6 * fbm(30, 3, 9) + 0.4 * fbm(8, 2, 10)).astype(np.float32),
             streak=fbm(70, 3, 11, aniso=(2.2, 0.35)), strata=fbm(90, 2, 12),
             spike_rel=spike_rel, lamps=lamps, craters=craters)
    G['shadow'] = shadow_map(Hf)
    print(f'sand drifts: {drifts}')
    print(f'world built in {time.time() - t0:.1f}s ({len(craters)} craters, {peaks} peaks, '
          f'{placed} boulders, {len(lamps)} lamps)')
    return G


def _drift(Hf, U, V, p, n, h_top, h_base, half_top=8.0, jag=None, rs=None):
    """Windblown sand drift from h_top at p, running along n down to h_base: rounded flanks,
    a wavering edge and surface ripples, max-combined so it meets the ground smoothly."""
    length = max((h_top - h_base) / RAMP_SLOPE, 8.0)
    ext = int(length + (h_top - h_base) / DRIFT_SIDE + 12)
    cu, cv = int(p[0] + n[0] * length / 2), int(p[1] + n[1] * length / 2)
    a0, a1 = max(0, cu - ext), min(N, cu + ext)
    b0, b1 = max(0, cv - ext), min(N, cv + ext)
    du, dv = U[a0:a1, b0:b1] - p[0], V[a0:a1, b0:b1] - p[1]
    along = du * n[0] + dv * n[1]
    lat = np.abs(-du * n[1] + dv * n[0])
    ph = rs.uniform(0, 6.28) if rs is not None else 0.0
    half = half_top * (1 + 0.35 * np.sin(along / 11.0 + ph)) + 2.0 * np.sin(along / 4.3 + ph * 2)
    over = lat - half
    flank = (np.sqrt(over * over + 9.0) + over) / 2               # rounded shoulder
    h = h_top - np.clip(along, 0, None) * (h_top - h_base) / length - flank * DRIFT_SIDE
    if jag is not None:
        h = h + 0.35 * jag[a0:a1, b0:b1] * np.clip(along / 10.0, 0, 1)
    ok = along > -8
    Hf[a0:a1, b0:b1] = np.where(ok, np.maximum(Hf[a0:a1, b0:b1], h), Hf[a0:a1, b0:b1])


def carve_drifts(Hf, U, V, tier1, tier2, pit1, pit2, allowed_ground, rs, jag=None):
    """Sand drifts against some cliffs so several plateaus (and the summits on them) can be
    climbed and a few pits walked into. Everything else stays cliff-bound."""
    counts = dict(plateau=0, summit=0, pit=0, deep_pit=0)
    lab1, n1 = ndi.label(tier1)
    reachable_tops = set()

    def try_component(region, room, outward, attempts=320):
        smooth = ndi.gaussian_filter(region.astype(np.float32), 4)
        gu, gv = np.gradient(smooth)
        edge = np.argwhere(region & ~ndi.binary_erosion(region))
        rs.shuffle(edge)
        for iu, iv in edge[:attempts]:
            g = np.array([gu[iu, iv], gv[iu, iv]])
            if np.linalg.norm(g) < 1e-4:
                continue
            n = -g / np.linalg.norm(g) if outward else g / np.linalg.norm(g)
            inside = np.array([iu, iv]) - n * 5         # on the upper side of the edge
            if not (0 <= inside[0] < N and 0 <= inside[1] < N):
                continue
            h_top = float(Hf[int(inside[0]), int(inside[1])])
            probe = np.array([iu, iv]) + n * 42
            if not (0 <= probe[0] < N and 0 <= probe[1] < N):
                continue
            h_base = float(Hf[int(probe[0]), int(probe[1])])
            drop = h_top - h_base
            if drop < 6:
                continue
            length = drop / RAMP_SLOPE
            perp = np.array([-n[1], n[0]])
            fits = True
            for s_ in np.arange(5, length + 6, 3):
                for lt in (-8.0, 0.0, 8.0):
                    q = np.array([iu, iv]) + n * s_ + perp * lt
                    qu, qv = int(q[0]), int(q[1])
                    if not (10 <= qu < N - 10 and 10 <= qv < N - 10) or not room[qu, qv]:
                        fits = False
                        break
                if not fits:
                    break
            if fits:
                _drift(Hf, U, V, np.array([iu + 0.5, iv + 0.5]), n, h_top, h_base, jag=jag, rs=rs)
                return True
        return False

    # plateaus: drifts piled against the outside of the biggest mesas
    sizes = ndi.sum(tier1, lab1, index=np.arange(1, n1 + 1))
    room = allowed_ground & ~ndi.binary_dilation(tier1, iterations=3)
    for comp in np.argsort(sizes)[::-1][:16]:
        if counts['plateau'] >= 9 or sizes[comp] < 600:
            break
        if try_component(lab1 == comp + 1, room, True):
            counts['plateau'] += 1
            reachable_tops.add(comp + 1)
    # summits: only on plateaus you can already get onto
    lab2, n2 = ndi.label(tier2)
    room = ndi.binary_erosion(tier1, iterations=5) & ~ndi.binary_dilation(tier2, iterations=3)
    for comp in range(1, n2 + 1):
        if counts['summit'] >= 5:
            break
        region = lab2 == comp
        parent = np.bincount(lab1[region], minlength=n1 + 1)[1:].argmax() + 1
        if parent in reachable_tops and region.sum() >= 400 and try_component(region, room, True):
            counts['summit'] += 1
    # pits: drifts spilling down into them
    for mask, room, want, label in ((pit1, pit1 & ~ndi.binary_dilation(pit2, iterations=3), 4, 'pit'),
                                    (pit2, ndi.binary_erosion(pit2, iterations=2), 2, 'deep_pit')):
        lab, n = ndi.label(mask)
        sizes = ndi.sum(mask, lab, index=np.arange(1, n + 1)) if n else []
        for comp in np.argsort(sizes)[::-1]:
            if counts[label] >= want or sizes[comp] < 600:
                break
            if try_component(lab == comp + 1, room, False):
                counts[label] += 1
    return counts


def shadow_map(Hf):
    """1 = in shadow. March every cell toward the sun through the heightfield, plus props."""
    du, dv = to_grid(SUN[0], SUN[1])
    iu, iv = np.meshgrid(np.arange(N, dtype=np.float32), np.arange(N, dtype=np.float32), indexing='ij')
    occ = np.zeros((N, N), bool)
    base = Hf + 0.3
    t = 1.0
    while t < 330:
        hs = ndi.map_coordinates(Hf, [iu + du * t, iv + dv * t], order=1, mode='nearest')
        occ |= hs > base + SUN[2] * t
        t += 1.0 if t < 24 else (2.0 if t < 90 else 4.0)
    sh = occ.astype(np.float32)
    lh = math.hypot(du, dv)
    hu, hv = du / lh, dv / lh

    # comms tower: closest approach of each sun ray to the tower axis
    c = DOMES['comms']
    cu, cv = to_grid(c['X'], c['Y'])
    top = (TOWER_TOP + 30) * DOME_SCALE
    reach = int(top / SUN[2] * lh) + 30
    a0, a1 = max(0, int(cu - reach)), min(N, int(cu + reach))
    b0, b1 = max(0, int(cv - reach)), min(N, int(cv + reach))
    pu, pv = iu[a0:a1, b0:b1] + 0.5, iv[a0:a1, b0:b1] + 0.5
    s = (cu - pu) * hu + (cv - pv) * hv
    perp = np.abs((cu - pu) * hv - (cv - pv) * hu)
    z = Hf[a0:a1, b0:b1] + s * SUN[2] / lh
    rad = (7.5 - 4.5 * np.clip(z / (TOWER_TOP * DOME_SCALE), 0, 1)) * DOME_SCALE
    tower = (s > 0) & (perp < rad) & (z > 0) & (z < top)
    sh[a0:a1, b0:b1] = np.maximum(sh[a0:a1, b0:b1], tower)

    # glass domes cast a faint shadow outside their footprint
    Lg = np.array([du, dv, SUN[2]])
    for d in DOMES.values():
        du0, dv0 = to_grid(d['X'], d['Y'])
        R = d['R']
        a0, a1 = max(0, int(du0 - R * 2.4)), min(N, int(du0 + R * 2.4))
        b0, b1 = max(0, int(dv0 - R * 2.4)), min(N, int(dv0 + R * 2.4))
        P = np.stack([iu[a0:a1, b0:b1] + 0.5 - du0, iv[a0:a1, b0:b1] + 0.5 - dv0, Hf[a0:a1, b0:b1]], -1)
        b = P @ Lg
        cc = (P * P).sum(-1) - R * R
        hit = (b * b - cc > 0) & (-b + np.sqrt(np.maximum(b * b - cc, 0)) > 0) & (cc > 0)
        sh[a0:a1, b0:b1] = np.maximum(sh[a0:a1, b0:b1], 0.45 * hit)
    return sh


# ================================================================== terrain render
def bottom_profile(X):
    rs = np.random.default_rng(SEED + 3)
    knots = np.arange(-1600, 1601, 37.0)
    vals = rs.standard_normal(len(knots))
    n1 = np.interp(X, knots, vals)
    knots2 = np.arange(-1600, 1601, 11.0)
    n2 = np.interp(X, knots2, rs.standard_normal(len(knots2)))
    return -74.0 - 10.0 * n1 - 4.0 * np.abs(n2)


def render_terrain(G):
    t0 = time.time()
    Hm = G['H']
    dYs = 0.25
    Ys = (np.arange(0, 2 * HALF, dYs) + dYs / 2).astype(np.float32)
    rows = ((AY - (np.arange(H) + 0.5)) / PX).astype(np.float32)
    hitY = np.full((H, W), np.inf, np.float32)
    hitZ = np.zeros((H, W), np.float32)
    kind = np.zeros((H, W), np.uint8)          # 1 terrain, 2 crust wall
    for i0 in range(0, W, 32):
        i1 = min(W, i0 + 32)
        X = ((np.arange(i0, i1) + 0.5 - AX) * S).astype(np.float32)
        Uc = (X[:, None] + Ys[None, :]) / SQ2
        Vc = (Ys[None, :] - X[:, None]) / SQ2
        inside = (Uc >= 0) & (Uc <= N) & (Vc >= 0) & (Vc <= N)
        h = ndi.map_coordinates(Hm, [Uc.ravel() - 0.5, Vc.ravel() - 0.5], order=1, mode='nearest').reshape(Uc.shape)
        g = np.where(inside, h + KY * Ys[None, :], -np.inf)
        Gm = np.maximum.accumulate(g, axis=1)
        bot = bottom_profile(X)
        for c in range(i1 - i0):
            if not np.isfinite(Gm[c, -1]):
                continue
            k = np.searchsorted(Gm[c], rows, side='left')
            hit = k < len(Ys)
            if not hit.any():
                continue
            j = np.nonzero(hit)[0]
            kk = k[j]
            vv = rows[j]
            prev = np.maximum(kk - 1, 0)
            g0 = g[c, prev]
            first = (kk == 0) | ~np.isfinite(g0)
            g1 = g[c, kk]
            frac = np.where(first, 0.0, (vv - g0) / np.maximum(g1 - np.where(first, 0, g0), 1e-6))
            Yh = np.where(first, abs(X[c]), Ys[prev] + frac * dYs)
            Zh = vv - KY * Yh
            wall = first & (Zh < h[c, kk] - 0.75)
            keep = ~wall | (Zh >= bot[c])
            j, Yh, Zh, wall = j[keep], Yh[keep], Zh[keep], wall[keep]
            hitY[j, i0 + c] = Yh
            hitZ[j, i0 + c] = Zh
            kind[j, i0 + c] = np.where(wall, 2, 1)
    print(f'terrain ray hits in {time.time() - t0:.1f}s')
    return hitY, hitZ, kind


def shade_terrain(G, hitY, hitZ, kind):
    t0 = time.time()
    img = np.zeros((H, W, 3), np.uint8)
    dark = np.zeros((H, W, 3), np.uint8)
    steep_map = np.zeros((H, W), bool)
    level_top = np.zeros((H, W, 3), np.uint8)       # lightest colour of each pixel's ramp (rim light)
    no_lip = np.zeros((H, W), bool)
    for r0 in range(0, H, 320):                     # bands keep memory low
        r1 = min(H, r0 + 320)
        jj, ii = np.nonzero(kind[r0:r1] > 0)
        if jj.size == 0:
            continue
        jj = jj + r0
        rgb, drk, top, steep, spire = _shade_pixels(G, jj, ii, hitY[jj, ii], hitZ[jj, ii], kind[jj, ii] == 2)
        img[jj, ii] = rgb
        dark[jj, ii] = drk
        level_top[jj, ii] = top
        steep_map[jj, ii] = steep
        no_lip[jj, ii] = spire

    # rim light: the lip pixel above a cliff face catches the sun
    below_steep = np.zeros_like(steep_map)
    below_steep[:-1] = steep_map[1:] & (kind[1:] > 0)
    dy = np.full((H, W), np.inf, np.float32)
    dy[:-1] = np.abs(hitY[:-1] - hitY[1:])
    lip = (kind > 0) & ~steep_map & below_steep & (dy < 4.0) & ~no_lip
    img[lip] = level_top[lip]
    print(f'terrain shaded in {time.time() - t0:.1f}s')
    return img, dark


def _shade_pixels(G, jj, ii, Y, Z, wall):
    X = (ii + 0.5 - AX) * S
    u, v = to_grid(X, Y)
    nX, nY, nZ = (sample(G[k], u, v) for k in ('nX', 'nY', 'nZ'))
    nX = np.where(wall, np.where(X < 0, -0.7071, 0.7071), nX)
    nY = np.where(wall, -0.7071, nY)
    nZ = np.where(wall, 0.0, nZ)
    ndl = nX * SUN[0] + nY * SUN[1] + nZ * SUN[2]
    shadow = np.where(wall, 0.0, sample(G['shadow'], u, v))
    ao = np.where(wall, 0.0, sample(G['ao'], u, v))
    mat = sample(G['mat'].astype(np.float32), u, v, order=0).astype(int)
    tex = sample(G['tex'], u, v)
    streak = sample(G['streak'], u, v)
    glow = sample(G['glow'], u, v)
    path_d = sample(G['path_d'], u, v)
    walk_d = sample(G['walk_d'], u, v)
    albedo = sample(G['albedo'], u, v)
    spike_rel = sample(G['spike_rel'], u, v)
    bay = BAYER[jj % 4, ii % 4]

    I = 0.18 + 0.78 * np.maximum(ndl, 0.0)
    I = I * (1.0 - 0.52 * shadow) - 0.34 * ao
    steep = (nZ < 0.55) | wall
    flat = ~steep
    # dust: soft patches, fine grit and bright wind streaks
    grit = (np.sin(np.floor(u * 2) * 12.9898 + np.floor(v * 2) * 78.233) * 43758.5453) % 1.0
    I += np.where(flat, 0.04 * tex + 0.05 * np.clip(streak - 0.6, 0, 2) + 0.05 * albedo + 0.05 * (grit - 0.5)
                  - 0.07 * np.clip(-albedo - 0.9, 0, 1.5), 0.0)
    I -= np.where(wall, 0.3 * np.clip(-Z / 90.0, 0, 1), 0.0)

    rgb = np.zeros((len(jj), 3), np.uint8)
    drk = np.zeros((len(jj), 3), np.uint8)
    top = np.zeros((len(jj), 3), np.uint8)

    # flat materials
    is_path = flat & (path_d < PATH_HALF + bay * 3.0) & (mat != 5)
    tracks = is_path & (np.abs(path_d - 4.2) < 0.7)
    floor = flat & (mat == 5)
    walk_w = 5.5 * DOME_SCALE
    walkway = floor & (walk_d < walk_w)
    sel_mat = np.where(is_path, 3, np.where(walkway, 7, np.where(floor, 9, mat)))
    # 0 ground 1 mesa 2 pit 3 path 4 rock 6 spire 7 walkway 9 floor
    sel_mat = np.where(steep, -1, sel_mat)
    sel_mat = np.where((mat == 4) & ~is_path, 4, sel_mat)    # boulders keep rock colours even when steep
    spire = (mat == 6) & (sel_mat == -1)
    frost = (mat == 6) & (spike_rel > 0.8 + bay * 0.06)
    sel_mat = np.where(spire, -2, sel_mat)
    sel_mat = np.where(frost, -3, sel_mat)
    sel_mat = np.where((mat == 6) & (sel_mat == 6), 1, sel_mat)   # gentle spire feet read as mesa rock
    names = {0: 'ground', 1: 'mesa', 2: 'pit', 3: 'path', 4: 'rock', 9: 'floor', 7: 'walk'}
    # floor: tiled panels with a lit centre
    if floor.any():
        tile = 9.0 * DOME_SCALE
        fu, fv = u[floor], v[floor]
        seam = (np.mod(fu, tile) < 0.7) | (np.mod(fv, tile) < 0.7)
        small = (np.mod(fu, tile / 2) < 0.6) | (np.mod(fv, tile / 2) < 0.6)
        wk = walk_d[floor] < walk_w
        I[floor] = 0.6 + 0.24 * glow[floor] - np.where(wk, 0.13 * small, 0.15 * seam) + 0.025 * tex[floor]
    I = np.where(tracks, I - 0.1, I)
    for m, name in names.items():
        sel = sel_mat == m
        if not sel.any():
            continue
        ramp = T_RAMPS[name]
        n = len(ramp)
        dith = 0.55 if name in ('pit', 'rock') else 0.38
        lv = np.clip(np.round(I[sel] * (n - 1) + bay[sel] * dith), 0, n - 1).astype(int)
        rgb[sel] = ramp[lv]
        drk[sel] = ramp[1]
        top[sel] = ramp[min(n - 1, 6)]

    # cliff faces, crust walls and spires: strata bands
    table = band_table()
    for code, ramps in ((-1, STRATA), (-2, SPIKE_STRATA)):
        cl = sel_mat == code
        if not cl.any():
            continue
        zb = Z[cl] + 2.2 * sample(G['strata'], u[cl], v[cl]) + 160
        if code == -2:
            zb = zb / 2.5 + 100
        band = table[np.clip(zb.astype(int), 0, len(table) - 1)] % len(ramps)
        Ic = I[cl]
        idx_all = np.nonzero(cl)[0]
        for b, ramp in enumerate(ramps):
            sb = band == b
            lv = np.clip(np.round(Ic[sb] * (len(ramp) - 1) + bay[cl][sb] * 0.5), 0, len(ramp) - 1).astype(int)
            idx = idx_all[sb]
            rgb[idx] = ramp[lv]
            drk[idx] = ramp[0]
            top[idx] = ramp[-1]
    fr = sel_mat == -3
    if fr.any():
        lv = np.clip(np.round((I[fr] + 0.12) * (len(FROST) - 1) + bay[fr] * 0.5), 0, len(FROST) - 1).astype(int)
        rgb[fr] = FROST[lv]
        drk[fr] = FROST[0]
        top[fr] = FROST[-1]

    # cool bounce light on faces turned away from the sun (sky + ringed planet fill)
    cool = (sel_mat <= -1) & (nX > 0.35)
    coolc = np.array(A.hex2rgb('#6b6aa6'), np.float32)
    cq = np.where(bay[cool] > -0.1, 0.16, 0.08)
    rgb[cool] = (rgb[cool] * (1 - cq[:, None]) + coolc * cq[:, None]).astype(np.uint8)

    # warm lamp light pooling on the ground
    gl = np.clip(glow, 0, 1)
    gq = np.floor(gl * 3 + bay * 0.9 + 0.5) / 3.0
    warm = np.array([255, 196, 130], np.float32)
    rgb = (rgb * (1 - 0.32 * gq[:, None]) + warm * 0.32 * gq[:, None]).astype(np.uint8)
    return rgb, drk, top, steep, mat == 6


_BAND = None


def band_table():
    global _BAND
    if _BAND is None:
        rs = np.random.default_rng(SEED + 5)
        t = []
        last = -1
        while len(t) < 600:
            b = int(rs.integers(len(STRATA)))
            if b == last:
                continue
            t += [b] * int(rs.integers(2, 9))
            last = b
        _BAND = np.array(t[:600])
    return _BAND


# ================================================================== props (SDF)
class Plane:
    """Invisible ground plane that stops rays early."""

    def __init__(self, z):
        self.z = z

    def local(self, P):
        return P

    def __call__(self, P):
        return P[:, 2] - self.z


class Scaled:
    """Uniformly scales any SDF about a point; decals still see design-size local coords."""

    def __init__(self, inner, C, s):
        self.inner, self.C, self.s = inner, np.asarray(C, float), float(s)

    def _in(self, P):
        return self.C + (P - self.C) / self.s

    def local(self, P):
        return self.inner.local(self._in(P))

    def __call__(self, P):
        return self.inner(self._in(P)) * self.s

    def __getattr__(self, k):
        return getattr(self.inner, k)


def scaled(parts, C, s, tag):
    """Scale a whole design-size model about C; tag keeps its groups unique."""
    return [A.Part(p.name, Scaled(p.sdf, C, s), p.ramp, f'{tag}:{p.group}', decal=p.decal) for p in parts]


def scale_pt(p, C, s):
    return np.asarray(C, float) + (np.asarray(p, float) - np.asarray(C, float)) * s


UPAX = A.ry(-math.pi / 2)        # turns a Disc's axis (local x) vertical


def cam(X, Y, z=0.0):
    return np.array([X, Y, z], float)


def grid_dir(angle):
    """Unit vector in camera X/Y for an angle measured in grid space (0 = +u)."""
    du, dv = math.cos(angle), math.sin(angle)
    X, Y = to_cam(du, dv)
    return np.array([X, Y, 0.0])


def yaw_to(dirv):
    return A.rz(math.atan2(dirv[1], dirv[0]))


def frame_z(z):
    """Rotation whose local z axis points along z."""
    z = A.nz(z)
    x = A.nz(np.cross([0.0, 0.0, 1.0], z) if abs(z[2]) < 0.99 else [1.0, 0.0, 0.0])
    return np.stack([x, np.cross(z, x), z], axis=1)


def P_(name, sdf, ramp, group, decal=None):
    return A.Part(name, sdf, ramp, group, decal=decal)


def decal_hub(part, P):
    q = part.sdf.local(P)
    h, ang = q[:, 0], np.arctan2(q[:, 2], q[:, 1])
    out = np.full(len(P), OID['metal'])
    out[(h > -8.5) & (h < -6.6)] = OID['coral']
    win = (h > 0.0) & (h < 4.6) & (np.mod(ang, 2 * math.pi / 16) > 0.07)
    out[win] = OID['window']
    return out


def decal_module(part, P):
    q = part.sdf.local(P)
    hx, hy, hz = part.sdf.half
    out = np.full(len(P), OID['metal'])
    side = np.abs(q[:, 1]) > hy - 1.2
    win = side & (q[:, 2] > -0.5) & (q[:, 2] < 3.2) & (np.abs(q[:, 0]) < hx - 3) & (np.mod(q[:, 0], 6.0) < 3.6)
    out[win] = OID['window']
    out[(q[:, 2] < -hz + 1.6)] = OID['pack']
    out[q[:, 2] > hz - 1.0] = OID['pack']
    return out


def decal_tunnel(part, P):
    s = part.sdf.local(P)
    out = np.full(len(P), OID['pack'])
    out[(np.abs(s - 0.12) < 0.05) | (np.abs(s - 0.88) < 0.05)] = OID['coral']
    return out


def decal_planter(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['wood'])
    out[q[:, 2] > part.sdf.half[2] - 0.7] = OID['soil']
    return out


def decal_tower(part, P):
    s = part.sdf.local(P) * math.sqrt(part.sdf.l2)
    out = np.full(len(P), OID['red'])
    out[np.mod(s, 22.0) < 2.6] = OID['metal']
    return out


def decal_panel(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['dark'])
    topf = q[:, 2] > 0.1
    out[topf] = OID['panel']
    grid = topf & ((np.mod(q[:, 0] + 0.3, 3.4) < 0.55) | (np.mod(q[:, 1] + 0.3, 3.0) < 0.55))
    out[grid] = OID['pline']
    return out


def decal_pad(part, P):
    q = part.sdf.local(P)
    r = np.hypot(q[:, 1], q[:, 2])
    out = np.full(len(P), OID['concrete'])
    topf = q[:, 0] > part.sdf.half - 0.6
    out[topf & (r > 30) & (r < 33.2)] = OID['coral']
    out[topf & (r > 12.5) & (r < 14.5)] = OID['mustard']
    cross = topf & (r < 9) & ((np.abs(q[:, 1]) < 1.2) | (np.abs(q[:, 2]) < 1.2))
    out[cross] = OID['mustard']
    return out


def decal_ring(part, P):
    q = part.sdf.local(P)
    ang = np.arctan2(q[:, 1], q[:, 0])
    out = np.full(len(P), OID['dark'])
    lights = (q[:, 2] > 1.0) & (np.mod(ang, 2 * math.pi / 40) < 0.02)
    out[lights] = OID['screen']
    return out


def decal_console(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['dark'])
    out[(q[:, 1] < -part.sdf.half[1] + 0.8) & (q[:, 2] > -0.5)] = OID['screen']
    out[q[:, 2] > part.sdf.half[2] - 0.6] = OID['pack']
    return out


def decal_rack(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['dark'])
    front = np.abs(q[:, 1]) > part.sdf.half[1] - 0.6
    dots = front & (np.mod(q[:, 2], 2.4) < 0.9) & (np.abs(q[:, 0]) < 2.6)
    out[dots & (np.mod(np.floor(q[:, 2] / 2.4), 2) == 0)] = OID['screen']
    out[dots & (np.mod(np.floor(q[:, 2] / 2.4), 2) == 1)] = OID['coral']
    return out


def decal_lander(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['metal'])
    out[np.abs(q[:, 2] + 0.5) < 1.2] = OID['coral']
    out[(q[:, 1] < -3.5) & (q[:, 2] > 1.5)] = OID['teal']
    return out


# --- models, all built at design size around their anchor -----------------------
def airlock(d, dirv):
    C = cam(d['X'], d['Y'])
    dirv = np.array([dirv[0], dirv[1], 0.0])
    a = C + dirv * (d['R0'] - 8) + np.array([0, 0, 6.0])
    b = C + dirv * (d['R0'] + 13) + np.array([0, 0, 6.0])
    Ry = yaw_to(dirv)
    return [P_('tunnel', A.RoundCone(a, b, 6.6, 6.2), 'pack', 'airlock', decal_tunnel),
            P_('door', A.RoundBox(b + dirv * 1.2, (1.6, 7.0, 7.2), 1.2, Ry), 'coral', 'door'),
            P_('doorwin', A.RoundBox(b + dirv * 2.4 + np.array([0, 0, 2.5]), (0.6, 2.4, 1.6), 0.5, Ry),
               'window', 'door')]


def dome_ring(d):
    C = cam(d['X'], d['Y'], 1.4)
    return [P_('ring', A.Torus(C, d['R0'], 2.6), 'dark', 'ring', decal_ring)]


def lamp(X, Y, z):
    base = cam(X, Y, z)
    return [P_('post', A.RoundCone(base, base + np.array([0, 0, 13.0]), 0.8, 0.6), 'dark', 'lamp'),
            P_('head', A.Sphere(base + np.array([0, 0, 14.4]), 1.7), 'glow', 'lamp')], base + np.array([0, 0, 14.4])


def base_interior(d):
    C = cam(d['X'], d['Y'], 0.6)
    parts = []
    hub_c = C + np.array([0, 0, 11.0])
    parts.append(P_('hub', A.Disc(hub_c, 30.0, 11.0, 3.0, UPAX), 'metal', 'hub', decal_hub))
    parts.append(P_('roof', A.Ellipsoid(C + np.array([0, 0, 21.0]), (27.0, 27.0, 9.0)), 'pack', 'hub'))
    parts.append(P_('vent', A.Disc(C + np.array([0, 0, 31.0]), 5.0, 2.2, 1.0, UPAX), 'coral', 'hub'))
    parts.append(P_('mast', A.RoundCone(C + np.array([6, 4, 28.0]), C + np.array([6, 4, 40.0]), 0.7, 0.5), 'dark', 'hubmast'))
    parts.append(P_('mastlight', A.Sphere(C + np.array([6, 4, 41.0]), 1.4), 'glow', 'hubmast'))
    for k, ang in enumerate((math.radians(150), math.radians(260), math.radians(20))):
        dv = grid_dir(ang)
        mc = C + dv * 70 + np.array([0, 0, 8.6])
        Ry = yaw_to(dv)
        parts.append(P_('module', A.RoundBox(mc, (17.0, 11.0, 8.6), 4.5, Ry), 'metal', f'mod{k}', decal_module))
        parts.append(P_('tunnel', A.RoundCone(C + dv * 28 + np.array([0, 0, 6.5]), mc - dv * 15 + np.array([0, 0, -2.0]),
                                              5.0, 5.0), 'pack', f'tun{k}', decal_tunnel))
    for k, (du, dv_, z, ramp) in enumerate(((-46, 18, 3.0, 'mustard'), (-41, 25, 3.0, 'coral'), (-44, 21, 8.6, 'mustard'))):
        X, Y = to_cam(du, dv_)
        parts.append(P_('crate', A.RoundBox(C + np.array([X, Y, z]), (3.2, 3.2, 2.8), 0.8, A.rz(math.pi / 4)), ramp, f'crate{k}'))
    for k in range(6):
        ang = k * 1.05 + 0.4
        X, Y = to_cam(38 + 5 * math.cos(ang), -48 + 5 * math.sin(ang))
        parts.append(P_('bush', A.Sphere(C + np.array([X, Y, 2.6]), 3.2 if k % 2 else 2.6), 'leaf' if k % 2 else 'leaf2', 'garden'))
    for k, (du, dv_) in enumerate(((52, 40), (-30, -70), (-75, 30))):
        X, Y = to_cam(du, dv_)
        b = C + np.array([X, Y, 0.0])
        parts += [P_('pot', A.Disc(b + np.array([0, 0, 1.8]), 4.6, 1.8, 0.8, UPAX), 'wood', f'tree{k}'),
                  P_('trunk', A.RoundCone(b + np.array([0, 0, 3.0]), b + np.array([0, 0, 10.0]), 1.1, 0.8), 'wood', f'tree{k}'),
                  P_('crown', A.Sphere(b + np.array([0, 0, 12.5]), 4.8), 'leaf', f'tree{k}'),
                  P_('crown', A.Sphere(b + np.array([1.8, -1.6, 10.6]), 3.2), 'leaf2', f'tree{k}')]
    rv = C + np.array([*to_cam(-58, -10), 0.0])
    Rr = A.rz(math.pi / 4 + 0.35)
    parts += [P_('rover', A.RoundBox(rv + np.array([0, 0, 4.4]), (7.0, 4.2, 2.0), 1.0, Rr), 'mustard', 'rover'),
              P_('cab', A.RoundBox(rv + Rr @ np.array([-1.8, 0, 7.6]), (3.0, 3.4, 1.8), 1.0, Rr), 'metal', 'rover'),
              P_('glass', A.RoundBox(rv + Rr @ np.array([1.0, 0, 7.8]), (0.6, 3.0, 1.3), 0.4, Rr), 'teal', 'rover')]
    for sx in (-4.6, 4.6):
        for sy in (-4.0, 4.0):
            parts.append(P_('wheel', A.Disc(rv + Rr @ np.array([sx, sy, 2.4]), 2.4, 1.0, 0.5, Rr @ A.rz(math.pi / 2)),
                            'tire', 'rover'))
    lights = []
    for k, (du, dv_) in enumerate(((20, 55), (-55, -40), (60, -20))):
        X, Y = to_cam(du, dv_)
        lp, head = lamp(C[0] + X, C[1] + Y, 0.6)
        parts += [P_(p.name, p.sdf, p.ramp, f'lamp{k}') for p in lp]
        lights.append(head)
    return parts, lights


def nursery_interior(d):
    C = cam(d['X'], d['Y'], 0.6)
    parts = [
        P_('trunk', A.RoundCone(C, C + np.array([0, 0, 20.0]), 3.0, 1.8), 'wood', 'tree'),
        P_('canopy', A.Sphere(C + np.array([0, 0, 26.0]), 11.5), 'leaf', 'tree'),
        P_('canopy', A.Sphere(C + np.array([6.5, -3.0, 22.5]), 7.5), 'leaf2', 'tree'),
        P_('canopy', A.Sphere(C + np.array([-6.0, -4.5, 23.5]), 7.0), 'leaf2', 'tree'),
        P_('canopy', A.Sphere(C + np.array([1.0, 5.0, 33.0]), 6.5), 'leaf2', 'tree'),
    ]
    rs = np.random.default_rng(4)
    for k in range(9):
        th = rs.uniform(0, 2 * math.pi)
        ph = rs.uniform(0.0, 1.2)
        p = C + np.array([0, 0, 26.0]) + 11.6 * np.array([math.cos(th) * math.cos(ph), math.sin(th) * math.cos(ph), math.sin(ph)])
        parts.append(P_('blossom', A.Sphere(p, 1.3), 'blossom', 'tree'))
    for k in range(8):
        ang = k * math.pi / 4 + math.pi / 8
        dv = grid_dir(ang)
        tang = grid_dir(ang + math.pi / 2)
        pc = C + dv * 46 + np.array([0, 0, 2.6])
        parts.append(P_('planter', A.RoundBox(pc, (13.0, 4.6, 2.6), 1.2, yaw_to(tang)), 'wood', f'bed{k}', decal_planter))
        for j in range(-2, 3):
            leaf = 'leaf' if (j + k) % 2 else 'leaf2'
            r = 2.3 + 0.5 * ((j * 7 + k) % 3)
            parts.append(P_('plant', A.Sphere(pc + tang * (j * 5.0) + np.array([0, 0, 3.4]), r), leaf, f'bed{k}'))
    tank = C + grid_dir(math.radians(200)) * 64 + np.array([0, 0, 8.0])
    parts.append(P_('tank', A.Disc(tank, 6.5, 8.0, 2.0, UPAX), 'teal', 'tank'))
    lights = []
    for k in range(4):
        X, Y = (C + grid_dir(k * math.pi / 2) * 30)[:2]
        lp, head = lamp(X, Y, 0.6)
        parts += [P_(p.name, p.sdf, p.ramp, f'lamp{k}') for p in lp]
        lights.append(head)
    return parts, lights


def comms_interior(d):
    C = cam(d['X'], d['Y'], 0.6)
    parts = [P_('cable', A.Torus(C + np.array([0, 0, 0.8]), 13.0, 1.2), 'coral', 'cables')]
    for k in range(4):
        ang = k * math.pi / 2 + math.pi / 4
        dv = grid_dir(ang)
        pc = C + dv * 32 + np.array([0, 0, 3.6])
        parts.append(P_('console', A.RoundBox(pc, (6.5, 3.2, 3.6), 1.0, yaw_to(grid_dir(ang - math.pi / 2))),
                        'dark', f'con{k}', decal_console))
    for k, ang in enumerate((math.radians(110), math.radians(125), math.radians(140))):
        dv = grid_dir(ang)
        parts.append(P_('rack', A.RoundBox(C + dv * 62 + np.array([0, 0, 8.0]), (3.2, 3.2, 8.0), 0.8, yaw_to(dv)),
                        'dark', f'rack{k}', decal_rack))
    holo = C + grid_dir(math.radians(-40)) * 50
    parts += [P_('holo', A.Disc(holo + np.array([0, 0, 3.0]), 7.0, 3.0, 1.0, UPAX), 'dark', 'holo'),
              P_('holotop', A.Disc(holo + np.array([0, 0, 6.2]), 6.0, 0.4, 0.3, UPAX), 'screen', 'holo'),
              P_('holo', A.Sphere(holo + np.array([0, 0, 11.0]), 2.6), 'screen', 'holo')]
    lights = [holo + np.array([0, 0, 11.0])]
    for k in range(3):
        X, Y = (C + grid_dir(math.radians(170 + k * 70)) * 52)[:2]
        lp, head = lamp(X, Y, 0.6)
        parts += [P_(p.name, p.sdf, p.ramp, f'lamp{k}') for p in lp]
        lights.append(head)
    return parts, lights


def comms_tower(d, with_dish=False):
    C = cam(d['X'], d['Y'], 0.0)
    parts = [P_('tower', A.RoundCone(C, C + np.array([0, 0, TOWER_TOP]), 7.5, 3.0), 'red', 'tower', decal_tower)]
    parts.append(P_('collar', A.Torus(C + np.array([0, 0, d['R0'] - 0.6]), 8.6, 1.8), 'dark', 'collar'))
    parts.append(P_('deck', A.Disc(C + np.array([0, 0, 112.0]), 11.0, 1.3, 0.6, UPAX), 'metal', 'deck'))
    out = grid_dir(math.radians(-60))
    dish_dir = A.nz(out + np.array([0, 0, 0.9]))
    dish_c = C + np.array([0, 0, 122.0]) + out * 7
    if with_dish:
        parts += tower_dish_parts(C, math.radians(-60))
    parts.append(P_('mast', A.RoundCone(C + np.array([0, 0, TOWER_TOP - 2]), C + np.array([0, 0, TOWER_TOP + 26]), 1.1, 0.6),
                    'dark', 'mast'))
    parts.append(P_('beacon', A.Sphere(C + np.array([0, 0, TOWER_TOP + 28]), 2.4), 'beacon', 'beacon'))
    return parts, C + np.array([0, 0, TOWER_TOP + 28])


def tower_dish_parts(C, theta):
    """The comms dish on its swing arm, orbiting the tower axis."""
    out = grid_dir(theta)
    dish_dir = A.nz(out + np.array([0, 0, 0.9]))
    dish_c = C + np.array([0, 0, 122.0]) + out * 7
    return [P_('arm', A.RoundCone(C + np.array([0, 0, 118.0]), dish_c - dish_dir * 1.2, 1.0, 0.8), 'dark', 'dish'),
            P_('dish', A.Ellipsoid(dish_c, (9.5, 9.5, 2.0), frame_z(dish_dir)), 'metal', 'dish'),
            P_('feed', A.RoundCone(dish_c, dish_c + dish_dir * 8.0, 0.8, 0.6), 'dark', 'dish')]


def tower_dish_frame(d, theta):
    """Dish + the tower section and deck around it, so the tower hides the dish behind it."""
    C = cam(d['X'], d['Y'], 0.0)
    return ([P_('tower', A.RoundCone(C, C + np.array([0, 0, TOWER_TOP]), 7.5, 3.0), 'red', 'tower', decal_tower),
             P_('deck', A.Disc(C + np.array([0, 0, 112.0]), 11.0, 1.3, 0.6, UPAX), 'metal', 'deck')]
            + tower_dish_parts(C, theta))


def apex_radar(d, theta):
    """Radar on a short mast at the top of a dome."""
    C = cam(d['X'], d['Y'], 0.0)
    top = C + np.array([0, 0, d['R0']])
    pivot = top + np.array([0, 0, 9.0])
    face = grid_dir(theta)
    dish_dir = A.nz(face + np.array([0, 0, 0.45]))
    return [P_('collar', A.Torus(top + np.array([0, 0, -0.3]), 3.6, 1.2), 'dark', 'mast'),
            P_('mast', A.RoundCone(top - np.array([0, 0, 1.0]), pivot, 1.4, 1.0), 'pack', 'mast'),
            P_('dish', A.Ellipsoid(pivot + face * 1.2, (6.2, 6.2, 1.3), frame_z(dish_dir)), 'metal', 'radar'),
            P_('feed', A.RoundCone(pivot + face * 1.2, pivot + face * 1.2 + dish_dir * 4.5, 0.5, 0.4), 'dark', 'radar'),
            P_('weight', A.RoundBox(pivot - face * 2.4, (1.4, 1.4, 1.1), 0.5, yaw_to(face)), 'coral', 'radar')]


def apex_anemometer(d, theta):
    """Three-cup wind gauge spinning on top of a dome."""
    C = cam(d['X'], d['Y'], 0.0)
    top = C + np.array([0, 0, d['R0']])
    hub = top + np.array([0, 0, 8.0])
    parts = [P_('collar', A.Torus(top + np.array([0, 0, -0.3]), 3.2, 1.1), 'dark', 'mast'),
             P_('mast', A.RoundCone(top - np.array([0, 0, 1.0]), hub, 1.2, 0.8), 'pack', 'mast'),
             P_('hub', A.Sphere(hub + np.array([0, 0, 0.6]), 1.3), 'coral', 'rotor')]
    for k in range(3):
        a = grid_dir(theta + k * 2 * math.pi / 3)
        cup = hub + np.array([0, 0, 0.6]) + a * 5.0
        parts += [P_('arm', A.RoundCone(hub + np.array([0, 0, 0.6]), cup, 0.4, 0.35), 'dark', 'rotor'),
                  P_('cup', A.Sphere(cup, 1.4), 'teal' if k == 0 else 'metal', 'rotor')]
    return parts


def landing_pad():
    C = cam(PAD['X'], PAD['Y'], 1.1)
    R0 = PAD['R0']
    parts = [P_('pad', A.Disc(C, R0, 1.1, 0.6, UPAX), 'concrete', 'pad', decal_pad)]
    lights = []
    for k in range(10):
        p = C + grid_dir(k * 2 * math.pi / 10) * (R0 - 3) + np.array([0, 0, 1.6])
        parts.append(P_('padlight', A.Sphere(p, 1.2), 'screen', f'pl{k}'))
        lights.append(p)
    L0 = C + np.array([*grid_dir(math.radians(-30))[:2], 0]) * 8 + np.array([0, 0, 9.0])
    parts.append(P_('lander', A.Ellipsoid(L0, (8.0, 8.0, 6.6), A.rz(math.pi / 4)), 'metal', 'lander', decal_lander))
    parts.append(P_('nozzle', A.RoundCone(L0 - np.array([0, 0, 5.0]), L0 - np.array([0, 0, 8.2]), 2.0, 3.2), 'dark', 'lander'))
    for k in range(3):
        dv = grid_dir(k * 2 * math.pi / 3 + 0.3)
        parts.append(P_('leg', A.RoundCone(L0 + dv * 5 - np.array([0, 0, 2.0]), L0 + dv * 11 - np.array([0, 0, 8.0]), 0.8, 0.7),
                        'dark', 'lander'))
        parts.append(P_('foot', A.Sphere(L0 + dv * 11 - np.array([0, 0, 8.0]), 1.4), 'coral', 'lander'))
    parts.append(P_('antenna', A.RoundCone(L0 + np.array([0, 0, 6.0]), L0 + np.array([2, 1, 12.0]), 0.5, 0.45), 'dark', 'lander'))
    parts.append(P_('tip', A.Sphere(L0 + np.array([2, 1, 12.6]), 1.1), 'glow', 'lander'))
    return parts, lights, L0 + np.array([2, 1, 12.6]), L0


def solar_field():
    parts = []
    face = A.nz([SUN[0], SUN[1], 0.0])
    Rp = yaw_to(np.array([-face[1], face[0], 0.0])) @ A.rx(math.radians(32))
    for k, (u, v) in enumerate(solar_panels()):
        X, Y = to_cam(u, v)
        base = cam(X, Y, 0.0)
        top = base + np.array([0, 0, 7.0])
        model = [P_('post', A.RoundCone(base, top, 0.9, 0.7), 'dark', 'sp'),
                 P_('panel', A.RoundBox(top + np.array([0, 0, 1.0]), (9.0, 6.0, 0.55), 0.35, Rp), 'panel', 'sp', decal_panel)]
        parts += scaled(model, base, SOLAR_SCALE, f'solar{k}')
    return parts


# --- ray-marched compositing --------------------------------------------------------
def part_bound(sdf):
    if isinstance(sdf, Scaled):
        c, r = part_bound(sdf.inner)
        return sdf.C + (c - sdf.C) * sdf.s, r * sdf.s
    if isinstance(sdf, A.Sphere):
        return sdf.c, sdf.r
    if isinstance(sdf, A.Ellipsoid):
        return sdf.c, float(sdf.rad.max())
    if isinstance(sdf, A.RoundBox):
        return sdf.c, float(np.linalg.norm(sdf.half))
    if isinstance(sdf, A.RoundCone):
        return (sdf.a + sdf.b) / 2, math.sqrt(sdf.l2) / 2 + max(sdf.r1, sdf.r2)
    if isinstance(sdf, A.Torus):
        return sdf.c, sdf.major + sdf.minor
    if isinstance(sdf, A.Disc):
        return sdf.c, math.hypot(sdf.half, sdf.radius)
    raise TypeError(type(sdf))


def render_groups(parts, img, D, kind, gid, gid_base, ox=0, oy=0):
    """Ray-march each model group on its own, inside its own tight bounding sphere."""
    groups = {}
    for p in parts:
        groups.setdefault(p.group, []).append(p)
    for ps in groups.values():
        bounds = [part_bound(p.sdf) for p in ps]
        lo = np.min([c - r for c, r in bounds], axis=0)
        hi = np.max([c + r for c, r in bounds], axis=0)
        center = (lo + hi) / 2
        radius = max(np.linalg.norm(c - center) + r for c, r in bounds) + 0.5
        gid_base = render_props(ps, center, radius, img, D, kind, gid, gid_base, ox, oy)
    return gid_base


def render_props(parts, center, radius, img, D, kind, gid, gid_base, ox=0, oy=0):
    center = np.asarray(center, float)
    cx, cy = project(*center)
    rp = radius / S + 3
    x0, x1 = int(max(ox, cx - rp)), int(min(ox + img.shape[1], cx + rp + 1))
    y0, y1 = int(max(oy, cy - rp)), int(min(oy + img.shape[0], cy + rp + 1))
    if x1 <= x0 or y1 <= y0:
        return gid_base + 1
    jj, ii = np.mgrid[y0:y1, x0:x1]
    sx = ((ii + 0.5 - AX) * S).ravel()
    sy = ((AY - (jj + 0.5)) * S).ravel()
    O = sx[:, None] * CR + sy[:, None] * CU - F * 6000.0
    oc = O - center
    b = oc @ F
    cc = np.einsum('ij,ij->i', oc, oc) - radius * radius
    disc = b * b - cc
    sq = np.sqrt(np.maximum(disc, 0))
    t0 = np.where(disc > 0, -b - sq, 0.0)
    t1 = np.where(disc > 0, -b + sq, -1.0)
    parts = parts + [P_('void', Plane(-1.5), 'void', 'void')]
    scene = A.Scene(parts)
    hit, t = A.march(scene, O, F, t0, t1, eps=0.02, steps=220)
    Hh = np.nonzero(hit)[0]
    if Hh.size == 0:
        return gid_base + len(scene.group_names)
    P = O[Hh] + t[Hh, None] * F
    Dall = scene.dist_all(P)
    mat = np.argmin(Dall, axis=0)
    names = np.array([p.name for p in parts])
    keep = names[mat] != 'void'
    Hh, P, mat, Dall = Hh[keep], P[keep], mat[keep], Dall[:, keep]
    if Hh.size == 0:
        return gid_base + len(scene.group_names)
    e = 0.04
    n = np.zeros_like(P)
    for k in range(3):
        dv = np.zeros(3)
        dv[k] = e
        n[:, k] = scene(P + dv) - scene(P - dv)
    n /= np.maximum(np.linalg.norm(n, axis=1), 1e-9)[:, None]
    ramp = np.array([OID[parts[m].ramp] for m in mat])
    for i, p in enumerate(parts):
        if p.decal is not None:
            sel = mat == i
            if sel.any():
                ramp[sel] = p.decal(p, P[sel])
    ndl = n @ SUN
    wrap = (ndl + 0.3) / 1.3
    level = (wrap > 0.24).astype(int) + (wrap > 0.55) + (wrap > 0.86)
    other = Dall.copy()
    same = scene.group_of[:, None] == scene.group_of[mat][None, :]
    other[same] = np.inf
    other[names == 'void'] = np.inf
    level = np.where(other.min(axis=0) < 0.6, level - 1, level)
    level = np.clip(level, 0, 3)
    emis = np.isin(ramp, list(EMISSIVE))
    level = np.where(emis, np.where(ndl > 0.2, 3, 2), level)
    col = np.zeros((len(P), 3), np.uint8)
    for ri in np.unique(ramp):
        sel = ramp == ri
        col[sel] = O_RGB[ri][level[sel]]
    yy, xx = jj.ravel()[Hh] - oy, ii.ravel()[Hh] - ox
    depth = P[:, 1]
    front = depth < D[yy, xx]
    yy, xx = yy[front], xx[front]
    img[yy, xx] = col[front]
    D[yy, xx] = depth[front]
    kind[yy, xx] = 3
    gid[yy, xx] = gid_base + scene.group_of[mat][front]
    return gid_base + len(scene.group_names)


# ================================================================== glass
GLASS = np.array(A.hex2rgb('#cfeff0'), np.float32)
SHINE = np.array([255, 251, 240], np.float32)
RIB = hexa(*A.RAMPS['suit'])
PARALLELS = (0.26, 0.52, 0.78, 1.04, 1.26)


def glass_dome(img, D, kind, gid, d, gid_val, hole=0.0):
    C = cam(d['X'], d['Y'], 0.0)
    R = d['R']
    cx, cy = project(*C)
    rp = R / S + 2
    x0, x1 = int(cx - rp), int(cx + rp + 1)
    y0, y1 = int(cy - rp), int(cy + rp + 1)
    jj, ii = np.mgrid[y0:y1, x0:x1]
    sx = ((ii + 0.5 - AX) * S).ravel()
    sy = ((AY - (jj + 0.5)) * S).ravel()
    O = sx[:, None] * CR + sy[:, None] * CU - F * 6000.0
    oc = O - C
    b = oc @ F
    cc = np.einsum('ij,ij->i', oc, oc) - R * R
    disc = b * b - cc
    ok = disc > 0
    sq = np.sqrt(np.maximum(disc, 0))
    P1 = O + (-b - sq)[:, None] * F
    P2 = O + (-b + sq)[:, None] * F
    sub = (slice(y0, y1), slice(x0, x1))
    Dv = D[sub].reshape(-1).copy()
    col = img[sub].reshape(-1, 3).astype(np.float32)
    bay = BAYER[jj.ravel() % 4, ii.ravel() % 4]
    rib_w = 0.6

    def ribs(P, n):
        nu, nv = to_grid(n[:, 0], n[:, 1])
        el = np.arcsin(np.clip(n[:, 2], -1, 1))
        az = np.arctan2(nv, nu)
        per = 2 * math.pi / d['ribs']
        fr = np.mod(az / per, 1.0)
        dm = np.minimum(fr, 1 - fr) * per * R * np.maximum(np.cos(el), 0.05)
        mer = (dm < rib_w) & (el < PARALLELS[-1])
        par = np.zeros(len(P), bool)
        for ek in PARALLELS:
            par |= np.abs(el - ek) * R < rib_w
        return mer | par

    holed = lambda P: np.hypot(P[:, 0] - C[0], P[:, 1] - C[1]) > hole  # noqa: E731

    # back shell (seen through the front)
    mb = ok & (P2[:, 2] >= 0) & (P2[:, 1] < Dv) & holed(P2)
    n2 = (P2 - C) / R
    col[mb] = col[mb] * 0.9 + GLASS * 0.1
    rb = mb & ribs(P2, n2)
    col[rb] = col[rb] * 0.55 + RIB[1] * 0.45

    # front shell
    mf = ok & (P1[:, 2] >= 0) & (P1[:, 1] < Dv) & holed(P1)
    n1 = (P1 - C) / R
    fres = 1 - np.abs(n1 @ F)
    a = 0.14 + 0.16 * (fres + bay * 0.08 > 0.55) + 0.2 * (fres + bay * 0.08 > 0.82)
    col[mf] = col[mf] * (1 - a[mf, None]) + GLASS * a[mf, None]
    nsx, nsy = n1 @ CR, n1 @ CU
    ang = np.degrees(np.arctan2(nsy, nsx))
    rad = np.hypot(nsx, nsy)
    arc = mf & (ang > 104) & (ang < 166) & (rad > 0.76) & (rad < 0.86)
    arc2 = mf & (ang > 116) & (ang < 152) & (rad > 0.6) & (rad < 0.645)
    col[arc] = col[arc] * 0.45 + SHINE * 0.55
    col[arc2] = col[arc2] * 0.65 + SHINE * 0.35
    rf = mf & ribs(P1, n1)
    lit = n1 @ SUN
    lv = np.clip(1 + (lit > 0.15) + (lit > 0.55), 0, 3)
    col[rf] = col[rf] * 0.3 + RIB[lv[rf]] * 0.7

    img[sub] = col.reshape(y1 - y0, x1 - x0, 3).astype(np.uint8)
    Dv[mf] = P1[mf, 1]
    D[sub] = Dv.reshape(y1 - y0, x1 - x0)
    kv = kind[sub].reshape(-1)
    kv[mf] = 4
    kind[sub] = kv.reshape(y1 - y0, x1 - x0)
    gv = gid[sub].reshape(-1)
    gv[mf] = gid_val
    gid[sub] = gv.reshape(y1 - y0, x1 - x0)


# ================================================================== lines, glows, space
def shift(a, dy, dx, fill):
    out = np.full_like(a, fill)
    Hh, Ww = a.shape[:2]
    out[max(dy, 0):Hh + min(dy, 0), max(dx, 0):Ww + min(dx, 0)] = a[max(-dy, 0):Hh + min(-dy, 0), max(-dx, 0):Ww + min(-dx, 0)]
    return out


def depth_lines(img, dark, D, kind, gid, only_kind=None):
    line = np.zeros(D.shape, bool)
    obj_line = np.zeros(D.shape, bool)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nD = shift(D, dy, dx, np.inf)
        nk = shift(kind, dy, dx, 0)
        ng = shift(gid, dy, dx, -1)
        objy = (nk >= 3) | (kind >= 3)
        thr = np.where(objy, 2.5, 8.0)
        cond = (kind > 0) & (nk > 0) & (nD < D - thr) & (~objy | (ng != gid))
        del nD
        if only_kind is not None:
            cond &= nk == only_kind
        line |= cond
        obj_line |= cond & objy
    terr = line & ~obj_line
    img[terr] = dark[terr]
    img[obj_line] = OUTLINE


def add_glow(img, sx, sy, radius, color, strength):
    x0, x1 = int(max(0, sx - radius - 1)), int(min(W, sx + radius + 2))
    y0, y1 = int(max(0, sy - radius - 1)), int(min(H, sy + radius + 2))
    if x1 <= x0 or y1 <= y0:
        return
    jj, ii = np.mgrid[y0:y1, x0:x1]
    d = np.hypot(ii + 0.5 - sx, (jj + 0.5 - sy) * 1.15) / radius
    a = strength * np.clip(1 - d, 0, 1) ** 1.8
    step = strength / 3.0
    a = np.floor(a / step + BAYER[jj % 4, ii % 4] + 0.5) * step
    a = np.clip(a, 0, strength)[..., None]
    reg = img[y0:y1, x0:x1].astype(np.float32)
    img[y0:y1, x0:x1] = (reg * (1 - a) + np.asarray(color, np.float32) * a).astype(np.uint8)


def _smooth_noise_img(feat, seed, h, w):
    r2 = np.random.default_rng(seed)
    gh, gw = h // feat + 4, w // feat + 4
    z = ndi.zoom(r2.standard_normal((gh, gw)).astype(np.float32), feat, order=3, prefilter=False)
    z = z[feat:feat + h, feat:feat + w]
    return (z - z.mean()) / z.std()


def space_backdrop():
    rs = np.random.default_rng(SEED + 21)
    # smooth fields at quarter resolution, dithered at full resolution band by band
    q = 4
    hq_, wq = H // q + 1, W // q + 1
    nb = (0.65 * _smooth_noise_img(int(220 * PX / q), 1, hq_, wq)
          + 0.35 * _smooth_noise_img(int(70 * PX / q), 2, hq_, wq))
    hue = _smooth_noise_img(int(300 * PX / q), 3, hq_, wq)
    img = np.zeros((H, W, 3), np.uint8)
    top, bot = np.array(A.hex2rgb('#0a0814'), np.float32), np.array(A.hex2rgb('#171127'), np.float32)
    purple = np.array(A.hex2rgb('#2b1d4a'), np.float32)
    teal = np.array(A.hex2rgb('#14334a'), np.float32)
    sunc = np.array(A.hex2rgb('#5a2f45'), np.float32)
    xs = np.arange(W, dtype=np.float32)
    for r0 in range(0, H, 256):
        r1 = min(H, r0 + 256)
        yy = np.arange(r0, r1, dtype=np.float32)[:, None]
        bay = BAYER[np.arange(r0, r1)[:, None] % 4, np.arange(W)[None, :] % 4]
        g = (yy / H)[..., None]
        band = top * (1 - g) + bot * g
        band = np.broadcast_to(band, (r1 - r0, W, 3)).copy()
        neb = np.repeat(np.repeat(nb[r0 // q:(r1 - 1) // q + 1], q, 0), q, 1)
        neb = neb[(r0 % q):(r0 % q) + (r1 - r0), :W]
        band_d = np.abs(yy - (1500 - xs / W * 1250) * PX) / (260.0 * PX)
        neb = neb + 0.9 * np.exp(-band_d ** 2)
        lv = (np.clip(np.floor((neb - 0.55) * 2.4 + bay + 0.5), 0, 3) / 3.0)[..., None]
        hh = np.repeat(np.repeat(hue[r0 // q:(r1 - 1) // q + 1], q, 0), q, 1)[(r0 % q):(r0 % q) + (r1 - r0), :W]
        ncol = np.where((hh > 0)[..., None], purple, teal)
        band = band * (1 - 0.55 * lv) + ncol * 0.55 * lv
        sd = np.hypot(xs + 260 * PX, (yy - 560 * PX) * 1.4) / (1150.0 * PX)
        sg = np.floor(np.clip(1 - sd, 0, 1) ** 2 * 4 + bay + 0.5)[..., None] / 4.0
        band = band * (1 - 0.22 * sg) + sunc * 0.22 * sg
        img[r0:r1] = band.astype(np.uint8)

    star_cols = [hexa('#6f6688')[0], hexa('#a99bc4')[0], hexa('#e8e2f4')[0], hexa('#ffe9c4')[0], hexa('#bfe6ee')[0]]

    def put_star(x, y, bright):
        if bright < 0.72:
            img[y, x] = star_cols[0]
        elif bright < 0.93:
            img[y, x] = star_cols[1]
        else:
            img[y, x] = star_cols[2 + rs.integers(0, 3)]

    area = (W * H) / (3100 * 1880)
    for _ in range(int(3800 * area)):
        put_star(rs.integers(0, W), rs.integers(0, H), rs.random())
    for _ in range(int(5200 * area)):
        t = rs.uniform(-0.1, 1.1)
        x = int(t * W)
        y = int((1500 - t * 1250) * PX + rs.normal(0, 150 * PX))
        if 0 <= x < W and 0 <= y < H:
            put_star(x, y, rs.random() * 0.97)
    for _ in range(int(80 * area)):
        x, y = rs.integers(3, W - 3), rs.integers(3, H - 3)
        img[y, x] = star_cols[2 + rs.integers(0, 3)]
        for ddx, ddy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            img[y + ddy, x + ddx] = star_cols[1]
        if rs.random() < 0.35:
            for ddx, ddy in ((2, 0), (-2, 0), (0, 2), (0, -2)):
                img[y + ddy, x + ddx] = star_cols[0]

    draw_planet(img, int(W - 150 * PX), int(170 * PX), int(190 * PX), rings=True)
    draw_moon(img, int(190 * PX), int(250 * PX), int(30 * PX))
    draw_moon(img, int(300 * PX), int(150 * PX), int(11 * PX))
    return img


def draw_planet(img, cx, cy, r, rings=False):
    """Banded gas giant with a ring, lit from the left like the map. Bands follow real latitude."""
    roll, tip = math.radians(-16), math.radians(19)
    axis = np.array([-math.sin(roll) * math.cos(tip), math.cos(roll) * math.cos(tip), math.sin(tip)])
    Lp = A.nz([-0.86, 0.22, 0.46])
    pad = int(r * 2.1)
    y0, y1 = max(0, cy - pad), min(H, cy + pad)
    x0, x1 = max(0, cx - pad), min(W, cx + pad)
    jj, ii = np.mgrid[y0:y1, x0:x1]
    dx = (ii + 0.5 - cx) / r
    dy = -(jj + 0.5 - cy) / r
    d2 = dx * dx + dy * dy
    bay = BAYER[jj % 4, ii % 4]
    reg = img[y0:y1, x0:x1].astype(np.float32)
    inside = d2 <= 1.0
    nz_ = np.sqrt(np.clip(1 - d2, 0, 1))
    bands = [hexa('#121128', '#24244a', '#3f4274', '#6c73a2', '#a7afd0'),
             hexa('#151326', '#2e2742', '#4f4262', '#7c6c8c', '#b3a3bb'),
             hexa('#0f1726', '#1d3144', '#334f62', '#5f828c', '#9fc0bf')]
    pattern = np.array([0, 1, 0, 2, 0, 1, 2, 0, 1, 0, 2, 1, 0, 1, 0, 2])
    ring_cols = hexa('#1e1a31', '#3f3858', '#6e6585', '#a59bb4')
    rz_ = -(dx * axis[0] + dy * axis[1]) / axis[2]
    rr = np.sqrt(dx * dx + dy * dy + rz_ * rz_)
    on_ring = (rr > 1.38) & (rr < 2.05) & ~((rr > 1.66) & (rr < 1.71))
    ring_lv = np.where(rr < 1.66, 2, 1) + (np.mod(rr * 26, 1) > 0.62) - (np.mod(rr * 11, 1) > 0.8)
    rp = np.stack([dx, dy, rz_], -1)
    along = rp @ Lp
    in_shadow = (along < 0) & (np.linalg.norm(rp - along[..., None] * Lp, axis=-1) < 1.0)
    ring_lv = np.where(in_shadow, 0, ring_lv)
    if rings:
        back = on_ring & (rz_ < 0) & ~inside
        reg[back] = ring_cols[np.clip(ring_lv[back], 0, 3)]
    n = np.stack([dx, dy, nz_], -1)
    lam = n @ Lp
    lat = np.arcsin(np.clip(n @ axis, -1, 1))
    lon = np.arctan2(n @ np.cross(axis, [0, 0, 1.0]), nz_)
    wob = 0.035 * np.sin(lon * 5 + lat * 9) + 0.02 * np.sin(lon * 11 - lat * 4)
    bi = pattern[(np.floor((lat + wob) * 7.5).astype(int)) % len(pattern)]
    lv = np.clip(np.floor(lam * 3.4 + 1.55 + bay * 0.8), 0, 4).astype(int)
    if rings:
        t = -(n @ axis) / (Lp @ axis)
        qv = n + t[..., None] * Lp
        qr = np.linalg.norm(qv, axis=-1)
        lv = np.where(inside & (t > 0) & (qr > 1.38) & (qr < 2.05), np.maximum(lv - 2, 0), lv)
    for b, ramp in enumerate(bands):
        m = inside & (bi == b)
        reg[m] = ramp[lv[m]]
    limb = inside & (d2 > 0.88) & (lam > 0.1)
    reg[limb] = reg[limb] * 0.55 + np.array(A.hex2rgb('#dfe9f0'), np.float32) * 0.45
    if rings:
        front = on_ring & (rz_ >= 0)
        reg[front] = ring_cols[np.clip(ring_lv[front], 0, 3)]
    img[y0:y1, x0:x1] = reg.astype(np.uint8)


def draw_moon(img, cx, cy, r):
    y0, y1, x0, x1 = cy - r - 2, cy + r + 2, cx - r - 2, cx + r + 2
    jj, ii = np.mgrid[y0:y1, x0:x1]
    dx, dy = (ii + 0.5 - cx) / r, (jj + 0.5 - cy) / r
    d2 = dx * dx + dy * dy
    inside = d2 <= 1
    nz_ = np.sqrt(np.clip(1 - d2, 0, 1))
    lam = dx * -0.8 + -dy * 0.25 + nz_ * 0.55
    ramp = hexa('#15121f', '#3a3248', '#6c6178', '#a398a8', '#d8cfd2')
    bay = BAYER[jj % 4, ii % 4]
    lv = np.clip(np.floor(lam * 3.4 + 1.5 + bay * 0.9), 0, 4).astype(int)
    rs = np.random.default_rng(r)
    for _ in range(6):
        ccx, ccy, cr = rs.uniform(-0.6, 0.6), rs.uniform(-0.6, 0.6), rs.uniform(0.1, 0.25)
        cm = np.hypot(dx - ccx, dy - ccy) < cr
        lv = np.where(cm & (lv > 0), lv - 1, lv)
    reg = img[y0:y1, x0:x1]
    reg[inside] = ramp[lv[inside]]


HAZE = np.array(A.hex2rgb('#d39a8e'), np.float32)


def apply_haze(rgb, y0, x0):
    """Thin dusty air: the far side of the map softens toward a rose haze."""
    h, w = rgb.shape[:2]
    yy = np.arange(y0, y0 + h, dtype=np.float32)[:, None]
    far = np.clip((AY - 260 * PX - yy) / (1300 * PX), 0, 1)
    bay = BAYER[np.arange(y0, y0 + h)[:, None] % 4, np.arange(x0, x0 + w)[None, :] % 4]
    hq = (np.floor(far * 3 + bay * 0.9 + 0.5) / 3.0 * 0.12)[..., None]
    return (rgb * (1 - hq) + HAZE * hq).astype(np.uint8)


# ================================================================== moving parts
def export_animated(D):
    """Sprite sheets for the parts that move on the domes, plus the light positions the
    game animates (rim chase lights, airlock blinkers, comms beacon)."""
    adir = os.path.join(OUT, 'anim')
    os.makedirs(adir, exist_ok=True)
    out = dict(sprites=[], ring_lights=[], door_lights=[], beacon=None)

    def sheet(name, builder, d, frames, fps, z_center, radius, turn=2 * math.pi):
        C = cam(d['X'], d['Y'], 0.0)
        cx, cy = project(*scale_pt(C + np.array([0, 0, z_center]), C, DOME_SCALE))
        rp = radius * DOME_SCALE / S + 3
        x0, y0 = int(cx - rp), int(cy - rp)
        w = h = int(2 * rp) + 1
        strip = np.zeros((h, w * frames, 4), np.uint8)
        for f in range(frames):
            img = np.zeros((h, w, 3), np.uint8)
            Dc = np.full((h, w), np.inf, np.float32)
            kind = np.zeros((h, w), np.uint8)
            gid = np.zeros((h, w), np.int32)
            parts = scaled(builder(d, turn * f / frames), C, DOME_SCALE, name)
            render_groups(parts, img, Dc, kind, gid, 1, x0, y0)
            depth_lines(img, img, Dc, kind, gid)
            filled = kind > 0
            pad = np.pad(filled, 1)
            ring = (pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]) & ~filled
            img = apply_haze(img, y0, x0)
            img[ring] = OUTLINE
            alpha = np.where(filled | ring, 255, 0).astype(np.uint8)
            strip[:, f * w:(f + 1) * w, :3] = img
            strip[:, f * w:(f + 1) * w, 3] = alpha
        Image.fromarray(strip).save(os.path.join(adir, f'{name}.png'))
        out['sprites'].append(dict(name=name, file=f'anim/{name}.png', frames=frames, fps=fps,
                                   position=[x0, y0], frame_size=[w, h]))

    sheet('base_radar', apex_radar, DOMES['base'], 24, 8, DOMES['base']['R0'] + 5, 12.0)
    sheet('nursery_anemometer', apex_anemometer, DOMES['nursery'], 8, 14, DOMES['nursery']['R0'] + 4, 9.5,
          turn=2 * math.pi / 3)
    sheet('comms_dish', tower_dish_frame, DOMES['comms'], 24, 6, 121.0, 21.0)

    def visible(P):
        px, py = project(*P)
        ix, iy = int(px), int(py)
        return 0 <= ix < W and 0 <= iy < H and D[iy, ix] >= P[1] - 6, [ix, iy]

    for name, d in DOMES.items():                         # rim lights, as decal_ring places them
        C = cam(d['X'], d['Y'], 0.0)
        n = 40
        for k in range(n):
            a = k * 2 * math.pi / n + 0.01
            P = scale_pt(C + np.array([d['R0'] * math.cos(a), d['R0'] * math.sin(a), 1.4 + 2.5]), C, DOME_SCALE)
            ok, px = visible(P)
            if ok:
                out['ring_lights'].append(px + [round(k / n, 4), name])
    for k, (d, dirv) in enumerate(airlock_ends()):        # a warning light over every airlock door
        C = cam(d['X'], d['Y'], 0.0)
        dv = np.array([dirv[0], dirv[1], 0.0])
        P = scale_pt(C + dv * (d['R0'] + 15.6) + np.array([0, 0, 14.6]), C, DOME_SCALE)
        ok, px = visible(P)
        if ok:
            out['door_lights'].append(px + [round(k * 0.37 % 1.0, 3)])
    cm = DOMES['comms']
    C = cam(cm['X'], cm['Y'], 0.0)
    bx, by = project(*scale_pt(C + np.array([0, 0, TOWER_TOP + 28]), C, DOME_SCALE))
    out['beacon'] = [int(bx), int(by)]
    print(f"animated: {len(out['sprites'])} sprites, {len(out['ring_lights'])} rim lights, "
          f"{len(out['door_lights'])} door lights")
    return out


# ================================================================== map screen
FONT = {  # tiny pixel font for labels baked into the map-screen image
    'A': ['.#.', '#.#', '###', '#.#', '#.#'], 'B': ['##.', '#.#', '##.', '#.#', '##.'],
    'C': ['.##', '#..', '#..', '#..', '.##'], 'D': ['##.', '#.#', '#.#', '#.#', '##.'],
    'E': ['###', '#..', '##.', '#..', '###'], 'L': ['#..', '#..', '#..', '#..', '###'],
    'M': ['#...#', '##.##', '#.#.#', '#...#', '#...#'], 'N': ['#..#', '##.#', '#.##', '#..#', '#..#'],
    'O': ['.#.', '#.#', '#.#', '#.#', '.#.'], 'P': ['##.', '#.#', '##.', '#..', '#..'],
    'R': ['##.', '#.#', '##.', '#.#', '#.#'], 'S': ['.##', '#..', '.#.', '..#', '##.'],
    'T': ['###', '.#.', '.#.', '.#.', '.#.'], 'U': ['#.#', '#.#', '#.#', '#.#', '###'],
    'Y': ['#.#', '#.#', '.#.', '.#.', '.#.'], ' ': ['..', '..', '..', '..', '..'],
}


def text_width(text):
    return sum(len(FONT[ch][0]) + 1 for ch in text) - 1


def draw_text(img, x, y, text, color, shadow=(34, 24, 44)):
    mask = np.zeros((7, text_width(text) + 2), bool)
    cx = 1
    for ch in text:
        g = FONT[ch]
        for r, row in enumerate(g):
            for c, bit in enumerate(row):
                if bit == '#':
                    mask[r + 1, cx + c] = True
        cx += len(g[0]) + 1
    halo = ndi.binary_dilation(mask, structure=np.ones((3, 3), bool)) & ~mask
    h, w = mask.shape
    reg = img[y - 1:y - 1 + h, x - 1:x - 1 + w]
    reg[halo[:reg.shape[0], :reg.shape[1]]] = shadow
    reg[mask[:reg.shape[0], :reg.shape[1]]] = color


def export_minimap(final, filled, fit=(352, 192)):
    """A small whole-map image for the in-game map screen (M)."""
    ys, xs = np.nonzero(filled)
    x0, x1, y0, y1 = xs.min() - 60, xs.max() + 60, ys.min() - 60, ys.max() + 60
    scale = min(fit[0] / (x1 - x0), fit[1] / (y1 - y0))
    w, h = int((x1 - x0) * scale), int((y1 - y0) * scale)
    mm = Image.fromarray(final[y0:y1, x0:x1]).resize((w, h), Image.BOX)
    mm = np.array(mm).astype(np.float32)
    mm = np.clip((mm - 128) * 1.12 + 128, 0, 255).astype(np.uint8)       # keep it crisp after averaging

    def to_mm(X, Y, z=0.0):
        px, py = project(X, Y, z)
        return (px - x0) * scale, (py - y0) * scale

    path_col = np.array(A.hex2rgb('#f3cf9e'), np.uint8)
    for pts in PATHS:
        cp = catmull(pts, step=2.0)
        for X, Y in cp:
            if min(math.hypot(X - d['X'], Y - d['Y']) - d['R'] for d in DOMES.values()) < 0:
                continue
            mx, my = to_mm(X, Y)
            mm[int(my), int(mx)] = path_col
    ring_col = np.array(A.hex2rgb('#a8ece2'), np.uint8)
    for name, d in DOMES.items():
        for a in np.linspace(0, 2 * math.pi, 720, endpoint=False):
            mx, my = to_mm(d['X'] + d['R'] * math.cos(a), d['Y'] + d['R'] * math.sin(a))
            mm[int(my), int(mx)] = ring_col
    cream = A.hex2rgb('#f6ecdc')
    for name, d in DOMES.items():
        label = name.upper()
        mx, top = to_mm(d['X'], d['Y'], d['R'] * (1.0 if name != 'comms' else 0.0) + 20)
        if name == 'comms':
            top = to_mm(d['X'], d['Y'], (TOWER_TOP + 34) * DOME_SCALE)[1]
        draw_text(mm, int(mx - text_width(label) / 2), int(top - 9), label, cream)
    draw_text(mm, 4, 4, 'RED PLANET', A.hex2rgb('#ec7a5a'))
    draw_text(mm, w - text_width('M CLOSE') - 4, h - 9, 'M CLOSE', A.hex2rgb('#a99bb4'))
    Image.fromarray(mm).save(os.path.join(OUT, 'red_planet_minimap.png'))
    return dict(file='red_planet_minimap.png', origin=[int(x0), int(y0)], scale=scale, size=[w, h])


# ================================================================== game data
DEPTH_SCALE = 25.0                          # depth png stores camera-depth Y * 25 in 16 bits
HEIGHT_OFFSET, HEIGHT_SCALE = 100.0, 150.0  # walk png stores (z + 100) * 150 in 16 bits


def export_game_data(G, D, kind):
    """Data the game needs on top of the picture: a screen-space depth map (so the
    player can be hidden by cliffs, props and glass) and a walk/height grid."""
    depth = np.zeros((H, W, 4), np.uint8)
    for r0 in range(0, H, 512):
        r1 = min(H, r0 + 512)
        dq = np.where(kind[r0:r1] > 0, np.clip(D[r0:r1] * DEPTH_SCALE, 0, 65534), 65535).astype(np.uint32)
        depth[r0:r1, :, 0], depth[r0:r1, :, 1] = dq >> 8, dq & 255
        depth[r0:r1, :, 2] = np.where(kind[r0:r1] == 4, 255, 0)
    depth[..., 3] = 255
    Image.fromarray(depth).save(os.path.join(OUT, 'red_planet_depth.png'))
    del depth

    Hf = G['H'].copy()
    c = np.arange(N, dtype=np.float32) + 0.5
    U, V = np.meshgrid(c, c, indexing='ij')
    Xg, Yg = (U - V) / SQ2, (U + V) / SQ2
    Hu, Hv = np.gradient(ndi.gaussian_filter(Hf, 0.75))
    walk = np.hypot(Hu, Hv) < WALK_SLOPE
    steep = ~walk                                                    # isolated specks are surface noise
    lab, n_steep = ndi.label(steep)
    if n_steep:
        sizes = ndi.sum(steep, lab, np.arange(1, n_steep + 1))
        walk |= np.isin(lab, np.nonzero(sizes < 8)[0] + 1)
    walk &= ~ndi.binary_dilation(G['mat'] == 4, iterations=1)       # boulders: jump over them
    solid = np.zeros((N, N), bool)                                   # buildings and props always block
    for d in DOMES.values():
        solid |= np.hypot(Xg - d['X'], Yg - d['Y']) < d['R'] + 3

    def block_segment(a, b, r):
        nonlocal solid
        ab = b - a
        t = np.clip(((Xg - a[0]) * ab[0] + (Yg - a[1]) * ab[1]) / (ab @ ab), 0, 1)
        solid |= np.hypot(Xg - a[0] - t * ab[0], Yg - a[1] - t * ab[1]) < r

    for d, dirv in airlock_ends():                                    # airlock tunnels
        C = np.array([d['X'], d['Y']])
        block_segment(C + dirv * (d['R0'] - 8) * DOME_SCALE, C + dirv * (d['R0'] + 16) * DOME_SCALE, 8.0 * DOME_SCALE)
    pad_r = np.hypot(Xg - PAD['X'], Yg - PAD['Y'])
    Hf[pad_r < PAD['R']] = 2.2 * PAD_SCALE                           # stand on top of the pad
    lander = np.array([PAD['X'], PAD['Y']]) + grid_dir(math.radians(-30))[:2] * 8 * PAD_SCALE
    solid |= np.hypot(Xg - lander[0], Yg - lander[1]) < 12 * PAD_SCALE
    for u, v in solar_panels():
        solid |= np.hypot(U - u, V - v) < 9.5 * SOLAR_SCALE
    for X, Y in G['lamps']:
        solid |= np.hypot(Xg - X, Yg - Y) < 2.5 * LAMP_SCALE
    solid |= (U <= 6) | (U >= N - 6) | (V <= 6) | (V >= N - 6)
    walk &= ~solid

    base = DOMES['base']
    dirv = np.array(PATHS[1][1], float) - np.array([base['X'], base['Y']])
    dirv /= np.linalg.norm(dirv)
    lamps = np.array(G['lamps'])
    for dist in range(40, 300, 2):                                   # first open spot on the path, clear of lamps
        spawn = np.array([base['X'], base['Y']]) + dirv * (base['R'] + dist)
        su_, sv_ = to_grid(*spawn)
        if (walk[int(su_) - 3:int(su_) + 4, int(sv_) - 3:int(sv_) + 4].all()
                and np.min(np.hypot(lamps[:, 0] - spawn[0], lamps[:, 1] - spawn[1])) > 30):
            break
    if not walk[int(su_), int(sv_)]:
        raise RuntimeError('spawn point is not walkable')

    hq = np.clip((Hf + HEIGHT_OFFSET) * HEIGHT_SCALE, 0, 65535).astype(np.uint32)
    grid = np.zeros((N, N, 4), np.uint8)
    grid[..., 0], grid[..., 1] = hq >> 8, hq & 255
    grid[..., 2] = np.where(solid, 0, np.where(walk, 255, 128))
    grid[..., 3] = 255
    Image.fromarray(grid.transpose(1, 0, 2).copy()).save(os.path.join(OUT, 'red_planet_walk.png'))
    print(f'game data: {walk.mean() * 100:.1f}% walkable, {(~walk & ~solid).mean() * 100:.1f}% too steep '
          f'(jump only), {solid.mean() * 100:.1f}% solid')
    return dict(
        depth_png='red_planet_depth.png', walk_png='red_planet_walk.png',
        depth_scale=DEPTH_SCALE, height_offset=HEIGHT_OFFSET, height_scale=HEIGHT_SCALE,
        world_units_per_px=S, depth_to_px=KY, px_per_unit=PX, character_scale=1.0 / PX,
        grid_size=N, spawn_world=[round(float(spawn[0]), 2), round(float(spawn[1]), 2)],
        notes='World X/Y: X right, Y away from the camera. Screen = (origin_x + X / world_units_per_px, '
              'origin_y - (depth_to_px * Y + z) * px_per_unit). Walk grid pixel (u, v) with u = (X + Y) / sqrt2, '
              'v = (Y - X) / sqrt2. Channels: R,G = 16-bit value (hi, lo); depth B = 255 for glass; walk B = 255 '
              'walkable, 128 too steep to walk (can be jumped over, onto or down), 0 solid. character_scale converts sprite units (1 sprite px of height) to world units.')


# ================================================================== build
def build():
    os.makedirs(OUT, exist_ok=True)
    t_start = time.time()
    G = build_world()
    set_frame(G)
    hitY, hitZ, kind = render_terrain(G)
    img, dark = shade_terrain(G, hitY, hitZ, kind)
    del hitZ
    D = hitY
    gid = np.zeros((H, W), np.int32)
    lights = []
    gp = PX                                              # glow radii are given in world units

    # --- props
    t0 = time.time()
    gb = 1
    comms = DOMES['comms']
    cC = cam(comms['X'], comms['Y'])
    tower_parts, beacon = comms_tower(comms)
    gb = render_groups(scaled(tower_parts, cC, DOME_SCALE, 'tower'), img, D, kind, gid, gb)
    interiors = {'base': base_interior, 'nursery': nursery_interior, 'comms': comms_interior}
    for name, d in DOMES.items():
        C = cam(d['X'], d['Y'])
        gb = render_groups(scaled(dome_ring(d), C, DOME_SCALE, f'{name}ring'), img, D, kind, gid, gb)
        parts, ilights = interiors[name](d)
        gb = render_groups(scaled(parts, C, DOME_SCALE, name), img, D, kind, gid, gb)
        for k, hp in enumerate(ilights):
            col = A.hex2rgb('#7fe6cf') if name == 'comms' and k == 0 else A.hex2rgb('#ffcf87')
            lights.append((scale_pt(hp, C, DOME_SCALE), 8 * DOME_SCALE * gp * 0.6, col, 0.38))
    for k, (d, dirv) in enumerate(airlock_ends()):
        C = cam(d['X'], d['Y'])
        gb = render_groups(scaled(airlock(d, dirv), C, DOME_SCALE, f'airlock{k}'), img, D, kind, gid, gb)
    pad_parts, pad_lights, lander_tip, _ = landing_pad()
    pC = cam(PAD['X'], PAD['Y'])
    gb = render_groups(scaled(pad_parts, pC, PAD_SCALE, 'pad'), img, D, kind, gid, gb)
    for p in pad_lights:
        lights.append((scale_pt(p, pC, PAD_SCALE), 5 * PAD_SCALE * gp * 0.7, A.hex2rgb('#7fe6cf'), 0.35))
    lights.append((scale_pt(lander_tip, pC, PAD_SCALE), 6 * PAD_SCALE * gp * 0.7, A.hex2rgb('#ffd27a'), 0.4))
    gb = render_groups(solar_field(), img, D, kind, gid, gb)
    for k, (X, Y) in enumerate(G['lamps']):
        u, v = to_grid(X, Y)
        z = float(G['H'][int(u), int(v)])
        parts, head = lamp(X, Y, z)
        base = cam(X, Y, z)
        gb = render_groups(scaled(parts, base, LAMP_SCALE, f'pathlamp{k}'), img, D, kind, gid, gb)
        lights.append((scale_pt(head, base, LAMP_SCALE), 9 * LAMP_SCALE * gp, A.hex2rgb('#ffcf87'), 0.42))
    bC = cam(DOMES['base']['X'], DOMES['base']['Y'])
    lights.append((scale_pt(bC + np.array([6, 4, 41.6]), bC, DOME_SCALE), 6 * DOME_SCALE * gp * 0.6,
                   A.hex2rgb('#ffd27a'), 0.4))
    print(f'props in {time.time() - t0:.1f}s')

    depth_lines(img, dark, D, kind, gid)
    del dark

    # --- glass
    for name, d in DOMES.items():
        gb += 1
        glass_dome(img, D, kind, gid, d, gb, hole=9.0 * DOME_SCALE if name == 'comms' else 0.0)
    depth_lines(img, img, D, kind, gid, only_kind=4)
    del gid

    # --- space + silhouette outline, haze, then glows (halos may spill into space)
    filled = kind > 0
    pad = np.pad(filled, 1)
    ring = (pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]) & ~filled
    del pad
    final = space_backdrop()
    final[filled] = img[filled]
    del img
    final[ring] = OUTLINE
    for r0 in range(0, H, 256):                          # thin dusty air softens the far side
        r1 = min(H, r0 + 256)
        hazed = apply_haze(final[r0:r1], r0, 0)
        final[r0:r1] = np.where(filled[r0:r1, :, None], hazed, final[r0:r1])
    for p, rad, colr, s in lights:
        sx, sy = project(*p)
        add_glow(final, sx, sy, rad, colr, s)
    Image.fromarray(final).save(os.path.join(OUT, 'red_planet_map.png'))

    # --- metadata + visibility check
    meta = dict(name='red_planet', image='red_planet_map.png', size=[W, H],
                origin_px=[AX, AY], world_unit_px={'vertical': PX, 'horizontal': round(1 / S, 4)},
                grid_size_world=N, viewport_assumed=list(VIEWPORT), domes={}, landing_pad={}, lamps=len(G['lamps']))
    boxes = {}
    for name, d in DOMES.items():
        cx, cy = project(d['X'], d['Y'], 0.0)
        top = max(d['R'] / S, (TOWER_TOP + 31) * DOME_SCALE * PX if name == 'comms' else 0)
        box = [cx - d['R'] / S, cy - top, cx + d['R'] / S, cy + d['R'] * KY * PX]
        boxes[name] = box
        meta['domes'][name] = dict(center_px=[round(cx, 1), round(cy, 1)], radius_world=d['R'],
                                   bbox_px=[round(b, 1) for b in box])
    px, py = project(PAD['X'], PAD['Y'], 0)
    meta['landing_pad'] = dict(center_px=[round(px, 1), round(py, 1)], radius_world=PAD['R'])
    names = list(boxes)
    checks = []
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            a, b = boxes[names[i]], boxes[names[j]]
            gx = max(b[0] - a[2], a[0] - b[2])
            gy = max(b[1] - a[3], a[1] - b[3])
            ok = gx > VIEWPORT[0] or gy > VIEWPORT[1]
            checks.append(dict(pair=[names[i], names[j]], gap_x_px=round(gx, 1), gap_y_px=round(gy, 1), never_together=ok))
            print(f'  {names[i]:8s} / {names[j]:8s}  gap x {gx:7.1f}px  y {gy:7.1f}px  -> {"OK" if ok else "VISIBLE TOGETHER"}')
    meta['visibility_checks'] = checks
    meta['game'] = export_game_data(G, D, kind)
    meta['minimap'] = export_minimap(final, filled)
    meta['animated'] = export_animated(D)
    margin = 24
    frames = {}
    for name, b in DOMES.items():
        bx, by = project(b['X'], b['Y'], 0.0)
        xs, ys = [bx - b['R'] / S, bx + b['R'] / S], [by - b['R'] / S, by + b['R'] * KY * PX]
        for d, dirv in airlock_ends():
            if d is b:
                for z in (0.0, 30.0 * DOME_SCALE):
                    px_, py_ = project(*(np.array([b['X'], b['Y'], z]) + np.array([*dirv, 0]) * (b['R0'] + 17) * DOME_SCALE))
                    xs.append(px_)
                    ys.append(py_)
        for sp in meta['animated']['sprites']:
            if sp['name'].startswith(name):
                ys.append(sp['position'][1])
        frames[name] = [round(min(xs) - margin), round(min(ys) - margin),
                        round(max(xs) - min(xs) + 2 * margin), round(max(ys) - min(ys) + 2 * margin)]
    meta['zoom'] = dict(max_view_px=frames['base'][2:], frames=frames,
                        note='The furthest zoom-out shows max_view_px of map: the whole main base, no more. '
                             'frames are [x, y, w, h] boxes the camera frames at that zoom.')
    print(f"zoom: furthest view {meta['zoom']['max_view_px']} map px")
    with open(os.path.join(OUT, 'red_planet_map.json'), 'w') as fh:
        json.dump(meta, fh, indent=2)

    # close-ups of each dome for quick review
    prev = os.path.join(OUT, 'preview')
    os.makedirs(prev, exist_ok=True)
    im = Image.fromarray(final)
    for name, box in boxes.items():
        im.crop((int(box[0] - 120), int(box[1] - 60), int(box[2] + 120), int(box[3] + 80))).save(
            os.path.join(prev, f'{name}_closeup.png'))
    im.resize((W // 4, H // 4), Image.LANCZOS).save(os.path.join(prev, 'overview_quarter.png'))

    # interactive viewer (template + metadata inlined so it opens straight from disk)
    sprite_dir = os.path.join(ROOT, 'assets', 'characters', 'astronaut')
    with open(os.path.join(sprite_dir, 'astronaut.json')) as fh:
        sm = json.load(fh)
    idle = sm['animations']['idle']
    rel = os.path.relpath(sprite_dir, OUT).replace(os.sep, '/')
    viewer = dict(meta, sprite=dict(idle=f'{rel}/{idle["file"]}', shadow=f'{rel}/{sm["shadow"]}',
                                    frame=sm['frame_size'][0], anchor=sm['anchor'], frames=idle['frames'],
                                    fps=idle['fps'], row=idle['directions'].index('S')))
    with open(os.path.join(HERE, 'map_viewer.html'), encoding='utf-8') as fh:
        page = fh.read().replace('__MAP__', json.dumps(viewer))
    with open(os.path.join(OUT, 'viewer.html'), 'w', encoding='utf-8') as fh:
        fh.write('<!doctype html>\n' + page)
    print(f'done in {time.time() - t_start:.1f}s -> {OUT}')


if __name__ == '__main__':
    np.seterr(all='ignore')
    build()
