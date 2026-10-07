#!/usr/bin/env python3
"""
Base interior generator
=======================

The inside of the main base, as a cutaway diorama: three round rooms - storage in the middle
(the airlock door is in its back wall), the power room to the right and the oxygen room to the
left - joined by short corridors. Same iso camera, outlines and data formats as the overworld
(tools/mars_map_gen.py), so the astronaut and the game's map code work unchanged.

    python tools/interior_gen.py

Look
  Walls: glossy white panels with a sheen, a dark kick plate with an emergency light line,
  a coral accent strip and a band of hexagonal windows high up (two smashed in storage, the
  same shapes as outside). Floors: glossy diamond tiles that mirror the walls, a dark ring
  with a light line round each room, an emblem in the middle. The power is out: daylight
  through the windows, sun shafts through the holes, faint emergency lights.

Writes assets/maps/base_interior/: base_interior.png, _depth.png, _walk.png, .json, anim/.
--repair-metadata-only refreshes machine interaction anchors without rendering the art.
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
import mars_map_gen as M  # noqa: E402
import astronaut_sprite_gen as A  # noqa: E402

OUT = os.path.join(M.ROOT, 'assets', 'maps', 'base_interior')
P_ = M.P_
S, KY, PX = M.S, M.KY, M.PX
TAU = 2 * math.pi

# ================================================================== layout (world units)
OY = 520.0                        # the interior lives here in its own little world
N = 760                           # walk grid size
ROOMS = {
    'storage': dict(X=0.0, Y=OY, R=94.0, label='STORAGE'),
    'power':   dict(X=236.0, Y=OY + 10.0, R=76.0, label='POWER ROOM'),
    'oxygen':  dict(X=-236.0, Y=OY + 10.0, R=76.0, label='OXYGEN ROOM'),
}
CORRIDORS = [('storage', 'power'), ('storage', 'oxygen')]
CORR_HALF = 15.0                  # corridor half width
WALL_T = 5.0                      # wall thickness
WALL_H = 56.0                     # back walls
WALL_LOW = 4.5                    # the cut-away front walls
CORR_H = 44.0
DOOR_K = 2.3                      # the airlock door: design units -> world (as tall as outside)
# wall bands (height above the floor)
KICK = 3.4                        # dark kick plate
EMERG = (2.0, 2.7)                # emergency light line in it
CORAL = (31.0, 33.0)              # coral accent strip
WIN = (37.0, 49.0)                # the window band
LIGHT_IN = A.nz([0.62, -0.42, -0.66])   # sunlight through the holes: across to the right, forward, down
SUN_IN = A.nz([-0.42, -0.62, 0.66])     # key light on the furniture (from the front left, above)
HOLES = [('burst', 66.0), ('crescent', 114.0)]   # storage window band (angle round the room, degrees)

# ================================================================== palette
WHITE = M.hexa('#3c3954', '#5f5c79', '#8c8aa5', '#b8b7cb', '#dad9e6', '#f0f0f6', '#ffffff').astype(np.float32)
FLOOR = M.hexa('#2e2c42', '#47455e', '#65637d', '#87859e', '#a8a7bd', '#c6c5d6', '#dddce9', '#efeff6').astype(np.float32)
DARK = M.hexa('#141220', '#1c1a2c', '#26233a', '#322e4a', '#423d5e').astype(np.float32)
CYAN = np.array(A.hex2rgb('#58e0d4'), np.float32)
AMBER = np.array(A.hex2rgb('#ffb24a'), np.float32)
CORAL_R = M.hexa(*M.O_RAMPS['coral']).astype(np.float32)
SKYWIN = M.hexa('#5aa8b4', '#86cfd2', '#b6ece6', '#e6fff8').astype(np.float32)
SUNLIGHT = np.array(A.hex2rgb('#ffe2a8'), np.float32)
SAND = np.array(A.hex2rgb('#b46a4c'), np.float32)
VOID_TOP, VOID_BOT = np.array(A.hex2rgb('#07060d'), np.float32), np.array(A.hex2rgb('#120f1d'), np.float32)
HAZ = M.hexa('#1a1726', '#f0c640').astype(np.float32)

M.O_RAMPS.update({
    'steel':   ['#24233a', '#3d3c58', '#62627f', '#9496b4'],
    'cable':   ['#131120', '#211e31', '#332f47', '#4b4663'],
    'liquid':  ['#0c3f48', '#16767a', '#3fc0b4', '#b4fff0'],
    'redcore': ['#2a0c14', '#4f1420', '#82222a', '#c2402e'],
    'ledred':  ['#7a1f2e', '#d8443e', '#ff7a5a', '#ffd6bf'],
    'ledcyan': ['#1b4f5e', '#3fb3a6', '#7fe6cf', '#d8fff2'],
    'sack':    ['#4a3a34', '#7a6250', '#a88a6c', '#d2b48e'],
    'pcb':     ['#0a2418', '#124a2c', '#1f7a44', '#4fbf72'],
    'trace':   ['#6a4a12', '#b98a1e', '#f0c640', '#fff0a0'],
    'chip':    ['#0e0c16', '#1a1726', '#2a2638', '#3e3a52'],
})
M.O_NAMES[:] = list(M.O_RAMPS)
M.OID.clear()
M.OID.update({n: i for i, n in enumerate(M.O_NAMES)})
M.O_RGB[:] = [M.hexa(*M.O_RAMPS[n]) for n in M.O_NAMES]
M.EMISSIVE.clear()
M.EMISSIVE.update({M.OID[n] for n in ('glow', 'window', 'screen', 'beacon', 'ledred', 'ledcyan', 'liquid')})
OID = M.OID


def cam(X, Y, z=0.0):
    return np.array([X, Y, z], float)


def room_pt(name, ang_deg, r, z=0.0):
    rm = ROOMS[name]
    a = math.radians(ang_deg)
    return cam(rm['X'] + r * math.cos(a), rm['Y'] + r * math.sin(a), z)


def r_in(name):
    return ROOMS[name]['R'] - WALL_T / 2


# ================================================================== frame
def set_frame():
    xmax = max(abs(rm['X']) + rm['R'] for rm in ROOMS.values()) + WALL_T + 14
    ymax = max(rm['Y'] + rm['R'] for rm in ROOMS.values()) + WALL_T
    ymin = min(rm['Y'] - rm['R'] for rm in ROOMS.values()) - WALL_T - 10
    M.W = int(2 * xmax / S) + 40
    M.AX = M.W / 2.0
    M.AY = float(int((KY * ymax + WALL_H) * PX) + 34)
    M.H = int(M.AY - KY * ymin * PX + 30)
    print(f'interior frame {M.W}x{M.H}')


def view_rays(jj, ii):
    sx = (ii + 0.5 - M.AX) * S
    sy = (M.AY - (jj + 0.5)) * S
    return sx[:, None] * M.CR + sy[:, None] * M.CU - M.F * 6000.0


# ================================================================== where the floor is
def corridor_rect(a, b):
    ra, rb = ROOMS[a], ROOMS[b]
    x0, x1 = sorted((ra['X'], rb['X']))
    y = (ra['Y'] + rb['Y']) / 2
    return x0, x1, y


def floor_region(X, Y):
    """Which part of the floor each point is on: 0 none, 1.. rooms (in ROOMS order), 10 corridor."""
    out = np.zeros(X.shape, np.uint8)
    for a, b in CORRIDORS:
        x0, x1, y = corridor_rect(a, b)
        out[(X > x0) & (X < x1) & (np.abs(Y - y) < CORR_HALF)] = 10
    for i, (name, rm) in enumerate(ROOMS.items()):
        out[np.hypot(X - rm['X'], Y - rm['Y']) < rm['R'] + 0.5] = i + 1
    return out


# ================================================================== walls (SDF shells; shaded afterwards)
class RoomWall:
    """A round wall: tall at the back, cut low at the front, with openings."""

    def __init__(self, name, cuts):
        rm = ROOMS[name]
        self.c = np.array([rm['X'], rm['Y']])
        self.R = rm['R']
        self.cuts = cuts            # boxes (cx, cy, hx, hy, top) cut through the wall

    def local(self, P):
        return P

    def height(self, th):
        return WALL_LOW + (WALL_H - WALL_LOW) * M.smoothstep(-0.36, 0.04, np.sin(th))

    def __call__(self, P):
        dx, dy = P[:, 0] - self.c[0], P[:, 1] - self.c[1]
        r = np.hypot(dx, dy)
        th = np.arctan2(dy, dx)
        d = np.maximum.reduce([np.abs(r - self.R) - WALL_T / 2, P[:, 2] - self.height(th), -P[:, 2]])
        for cx, cy, hx, hy, top in self.cuts:
            q = np.maximum.reduce([np.abs(P[:, 0] - cx) - hx, np.abs(P[:, 1] - cy) - hy, P[:, 2] - top])
            d = np.maximum(d, -q)
        return d


class BoxWall:
    def __init__(self, c, half):
        self.c, self.half = np.asarray(c, float), np.asarray(half, float)

    def local(self, P):
        return P - self.c

    def __call__(self, P):
        q = np.abs(P - self.c) - self.half
        return np.linalg.norm(np.maximum(q, 0), axis=1) + np.minimum(q.max(axis=1), 0)


def wall_parts():
    parts = []
    door_f = door_frame_pt()
    for name, rm in ROOMS.items():
        cuts = []
        for a, b in CORRIDORS:
            if name in (a, b):
                x0, x1, y = corridor_rect(a, b)
                other = b if name == a else a
                sgn = 1 if ROOMS[other]['X'] > rm['X'] else -1
                cuts.append((rm['X'] + sgn * rm['R'], y, WALL_T * 1.6, CORR_HALF, 999.0))
        if name == 'storage':
            cuts.append((door_f[0], door_f[1], 7.5 * DOOR_K, WALL_T * 1.6, 8.6 * DOOR_K))
        parts.append(P_('wall', RoomWall(name, cuts), 'white', f'wall_{name}'))
    for a, b in CORRIDORS:
        x0, x1, y = corridor_rect(a, b)
        left, right = sorted((a, b), key=lambda n: ROOMS[n]['X'])
        xa, xb = x0 + ROOMS[left]['R'] - 3, x1 - ROOMS[right]['R'] + 3
        cx, hx = (xa + xb) / 2, (xb - xa) / 2
        parts.append(P_('cwall', BoxWall((cx, y + CORR_HALF + WALL_T / 2, CORR_H / 2), (hx, WALL_T / 2, CORR_H / 2)), 'white',
                        f'cwall_{b}'))
        parts.append(P_('cwall', BoxWall((cx, y - CORR_HALF - WALL_T / 2, WALL_LOW / 2), (hx, WALL_T / 2, WALL_LOW / 2)), 'white',
                        f'cfront_{b}'))
    return parts


class Cut:
    """One SDF with another carved out of it (a smashed hole, a blown-off panel)."""

    def __init__(self, a, b):
        self.a, self.b = a, b

    def local(self, P):
        return self.a.local(P)

    def __call__(self, P):
        return np.maximum(self.a(P), -self.b(P))

    def __getattr__(self, k):
        if k in ('a', 'b'):
            raise AttributeError(k)
        return getattr(self.a, k)


class Either:
    """Two carving shapes at once."""

    def __init__(self, a, b):
        self.a, self.b = a, b

    def __call__(self, P):
        return np.minimum(self.a(P), self.b(P))


def part_bound(sdf):
    if isinstance(sdf, Cut):
        return part_bound(sdf.a)
    if isinstance(sdf, RoomWall):
        return np.array([sdf.c[0], sdf.c[1], WALL_H / 2]), sdf.R + WALL_T + WALL_H / 2
    if isinstance(sdf, BoxWall):
        return sdf.c, float(np.linalg.norm(sdf.half)) + 1
    return _orig_part_bound(sdf)


_orig_part_bound = M.part_bound
M.part_bound = part_bound


STEP_OVER = ('shard', 'cable', 'cableend', 'wire', 'scrap', 'o2panel', 'blade')   # low things you walk over
BODY_H = 9.0                      # anything in the way below this blocks you


# ================================================================== the airlock door (in storage's back wall)
def door_frame_pt():
    return room_pt('storage', 90.0, r_in('storage') + 0.6)


def door_parts(open_=0.0):
    """Portal frame and a door of two halves that telescope into side pockets (open_ 0..1)."""
    k = DOOR_K
    f = door_frame_pt() + np.array([0, 0, 6.9 * k])
    out = np.array([0.0, -1.0, 0.0])                     # the door faces into the room
    side = np.array([1.0, 0.0, 0.0])
    up = np.array([0.0, 0.0, 1.0])
    Ry = M.yaw_to(out)
    e = open_ * open_ * (3 - 2 * open_)
    parts = [P_('portal', A.RoundBox(f + out * 0.5 * k + up * 7.9 * k, np.array([1.3, 8.4, 1.1]) * k, 0.5 * k, Ry), 'white', 'portal'),
             P_('portal', A.RoundBox(f + out * 0.5 * k - up * 6.9 * k, np.array([1.3, 8.4, 0.25]) * k, 0.2 * k, Ry), 'dark', 'portal'),
             P_('lamp', A.Sphere(f + out * 1.4 * k + up * 7.9 * k, 0.9 * k), 'deadbulb', 'portal'),
             P_('chamber', A.RoundBox(f - out * 0.6 * k, np.array([0.4, 6.4, 6.9]) * k, 0.3 * k, Ry), 'darkwin', 'chamber'),
             P_('chamberlight', A.RoundBox(f - out * 0.4 * k + up * 5.7 * k, np.array([0.3, 5.4, 0.75]) * k, 0.3 * k, Ry),
                'window', 'chamber')]
    for sgn in (1, -1):
        parts.append(P_('portal', A.RoundBox(f + out * 0.5 * k + side * sgn * 7.45 * k, np.array([1.3, 1.0, 7.9]) * k, 0.5 * k, Ry),
                        'white', 'portal'))
        hw = 3.2 * (1 - 0.9 * e)
        parts.append(P_('half', A.RoundBox(f - out * 0.35 * e * k + side * sgn * (6.4 - hw) * k, np.array([0.75, hw, 6.9]) * k,
                                           0.35 * k, Ry), 'coral', f'half{sgn}', M.decal_door_half))
    return parts


# ================================================================== furniture
def decal_crate(part, P):
    q = part.sdf.local(P)
    h = part.sdf.half
    out = np.full(len(P), OID['white'])
    out[np.abs(q[:, 2]) < h[2] * 0.16] = OID['coral']
    out[(np.abs(q[:, 1]) > h[1] - 0.55) & (np.abs(q[:, 0]) < h[0] * 0.3) & (q[:, 2] > h[2] * 0.3)] = OID['darkwin']
    out[(q[:, 2] > h[2] - 0.45) & (np.abs(q[:, 1]) < 0.4)] = OID['dark']
    return out


def decal_container(part, P):
    q = part.sdf.local(P)
    h = part.sdf.half
    out = np.full(len(P), OID['steel'])
    out[np.mod(q[:, 0] + 0.5, 2.6) < 0.7] = OID['cable']                 # ribs
    out[np.abs(q[:, 2] - h[2] * 0.45) < 0.8] = OID['coral']
    return out


def decal_barrel(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID[part.ramp])
    out[np.abs(np.abs(q[:, 0]) - part.sdf.half * 0.55) < 0.35] = OID['dark']
    return out


def decal_cabinet(part, P):
    q = part.sdf.local(P)
    h = part.sdf.half
    out = np.full(len(P), OID['white'])
    front = q[:, 1] > h[1] - 0.5
    panel = front & (np.abs(q[:, 0]) < h[0] - 0.7) & (q[:, 2] > -h[2] + 1.0) & (q[:, 2] < h[2] - 1.2)
    out[panel] = OID['steel']
    cells = panel & (np.mod(q[:, 2], 1.6) < 0.7) & (np.mod(q[:, 0] + 0.3, 1.5) < 0.7)
    out[cells] = OID['darkwin']
    return out


def decal_tank(part, P):
    q = part.sdf.local(P)                                 # 0 at the bottom, 1 at the top
    out = np.full(len(P), OID['white'])
    out[(np.abs(q - 0.3) < 0.04) | (np.abs(q - 0.72) < 0.04)] = OID['teal']
    return out


def decal_reactor(part, P):
    c = part.sdf.c
    z = P[:, 2]
    out = np.full(len(P), OID['white'])
    out[np.mod(z, 6.0) < 0.5] = OID['steel']
    return out


def decal_torn(fallback):
    """Where a part has been carved open: bare torn metal round the edge, scorched black inside."""
    def decal(part, P):
        out = fallback(part, P)
        if isinstance(part.sdf, Cut):
            inside = np.abs(part.sdf.b(P)) < 0.45          # on the carved surface
            out[inside] = OID['char']
            out[inside & (part.sdf.a(P) > -0.6)] = OID['steel']
        return out
    return decal


def decal_glass(part, P):
    out = np.full(len(P), OID['tglass'])
    if isinstance(part.sdf, Cut):
        out[np.abs(part.sdf.b(P)) < 0.5] = OID['shard']        # bright broken edges
    return out


def decal_o2(part, P):
    q = part.sdf.local(P)
    h = part.sdf.half
    out = np.full(len(P), OID['white'])
    out[np.abs(q[:, 2] - h[2] * 0.5) < 0.7] = OID['teal']
    front = q[:, 1] < -h[1] + 0.5
    grille = front & (q[:, 2] < h[2] * 0.15) & (q[:, 2] > -h[2] + 1.6) & (q[:, 0] > 1.5) & (q[:, 0] < h[0] - 1.4)
    out[grille & (np.mod(q[:, 2], 1.3) < 0.55)] = OID['dark']
    out[q[:, 2] < -h[2] + 0.9] = OID['steel']
    return out


def decal_hazard(part, P):
    """A plinth with a band of hazard stripes round its top edge."""
    q = part.sdf.local(P)
    h = part.sdf.half
    out = np.full(len(P), OID['steel'])
    band = (q[:, 2] > h[2] - 0.6) & ((np.abs(q[:, 0]) > h[0] - 1.8) | (np.abs(q[:, 1]) > h[1] - 1.8))
    out[band] = OID['dark']
    out[band & (np.mod(q[:, 0] + q[:, 1], 2.4) < 1.2)] = OID['mustard']
    return out


def decal_pcb(part, P):
    """A green board: gold traces, chips on silver legs, capacitors, a burnt-out patch, and an empty
    socket where the chip that blew used to sit."""
    q = part.sdf.local(P)
    x, z = q[:, 0], q[:, 2]
    out = np.full(len(P), OID['pcb'])

    def box(cx, cz, hx, hz):
        return (np.abs(x - cx) < hx) & (np.abs(z - cz) < hz)

    tr = np.zeros(len(P), bool)
    for z0, x0, x1 in ((5.6, -5.0, 4.6), (4.0, -0.2, 5.2), (-1.4, -5.2, 0.6), (-3.0, 1.0, 5.2), (-5.8, -4.6, 3.6), (0.6, -0.4, 1.0)):
        tr |= (np.abs(z - z0) < 0.28) & (x > x0) & (x < x1)
    for x0, z0, z1 in ((-4.6, -5.8, 5.6), (-0.4, -1.4, 4.0), (4.6, -3.0, 4.0), (1.2, -5.8, -3.0), (-2.2, -5.8, -1.4)):
        tr |= (np.abs(x - x0) < 0.3) & (z > z0) & (z < z1)
    out[tr] = OID['trace']
    for cx, cz, hx, hz in ((-2.4, 2.4, 1.9, 1.9), (3.0, 5.4, 1.5, 0.9), (-2.8, -3.6, 1.3, 1.5), (3.0, -4.8, 1.6, 1.0)):
        out[box(cx, cz, hx + 0.5, hz - 0.3) & (np.mod(z - cz + 0.15, 0.7) < 0.35)] = OID['steel']   # legs
        out[box(cx, cz, hx - 0.3, hz + 0.5) & (np.mod(x - cx + 0.15, 0.7) < 0.35)] = OID['steel']
        out[box(cx, cz, hx, hz)] = OID['chip']
        out[box(cx - hx + 0.6, cz + hz - 0.6, 0.25, 0.25)] = OID['steel']                              # pin-1 dot
    for k, (cx, cz) in enumerate(((0.6, 6.2), (1.5, 6.2), (5.2, 1.8), (-5.4, 0.4), (-0.6, -5.0), (5.2, -1.6))):
        out[np.hypot(x - cx, z - cz) < 0.5] = OID['teal' if k % 2 else 'coral']
    for sx in (-1, 1):
        for sz in (-1, 1):
            out[np.hypot(x - sx * 5.3, z - sz * 6.8) < 0.45] = OID['steel']                            # mounting holes
    sock = box(2.6, 0.8, 1.7, 1.7)
    out[sock] = OID['chip']
    out[sock & ~box(2.6, 0.8, 1.25, 1.25)] = OID['white']
    out[box(2.6, 0.8, 0.95, 0.95) & (np.mod(x - 2.6 + 0.2, 0.7) < 0.3) & (np.mod(z - 0.8 + 0.2, 0.7) < 0.3)] = OID['trace']
    ang = np.arctan2(z + 2.0, x - 0.2)
    out[np.hypot(x - 0.2, z + 2.0) < 1.25 + 0.4 * np.sin(ang * 5) + 0.2 * np.sin(ang * 11)] = OID['char']
    return out


def wire(start, ctrl, end, rs, ramp, group, r=0.45, n=14, curl=4):
    """A loose wire: out of where it broke, over in a sagging arc, and curled up on the floor."""
    start, ctrl, end = (np.asarray(v, float) for v in (start, ctrl, end))
    pts = []
    for i, t in enumerate(np.linspace(0, 1, n + 1)):
        q = (1 - t) ** 2 * start + 2 * (1 - t) * t * ctrl + t * t * end
        if 0 < i:
            q = q + rs.normal(0, 0.35, 3) * min(1.0, i / 3)
        pts.append(q)
    d = A.nz(np.array([*(end - ctrl)[:2], 0.0]))
    turn = rs.choice([-1, 1]) * rs.uniform(0.5, 0.9)
    for i in range(curl):
        d = A.rz(turn) @ d
        pts.append(pts[-1] + d * rs.uniform(1.4, 2.2))
    for q in pts:
        q[2] = max(q[2], r)
    return [P_('wire', A.RoundCone(pts[i], pts[i + 1], r, r), ramp, group) for i in range(len(pts) - 1)]


def scraps(C, rs, n, r0, r1, group, avoid=()):
    """Bits of metal lying round a broken machine: bent plates, rods, bolts."""
    parts = []
    k = 0
    while len(parts) < n and k < n * 20:
        k += 1
        a = rs.uniform(0, TAU)
        rr = rs.uniform(r0, r1)
        p = C + np.array([math.cos(a) * rr, math.sin(a) * rr, 0.0])
        if any(np.hypot(p[0] - x, p[1] - y) < r for x, y, r in avoid):
            continue
        ramp = ['steel', 'white', 'teal', 'coral', 'steel', 'white'][int(rs.integers(6))]
        R = A.rz(rs.uniform(0, TAU))
        kind_ = len(parts) % 3
        if kind_ == 0:                                   # a bent plate, one edge up
            parts.append(P_('scrap', A.RoundBox(p + np.array([0, 0, 0.8]), (rs.uniform(2.2, 4.0), rs.uniform(1.4, 2.6), 0.32), 0.15,
                                                R @ A.ry(rs.uniform(0.15, 0.35))), ramp, f'{group}{k}'))
        elif kind_ == 1:                                 # a rod
            d = R @ np.array([1.0, 0, 0])
            L = rs.uniform(3.6, 7.0)
            parts.append(P_('scrap', A.RoundCone(p - d * L / 2 + np.array([0, 0, 0.55]), p + d * L / 2 + np.array([0, 0, 0.55]),
                                                 0.55, 0.45), ramp, f'{group}{k}'))
        else:                                            # a bolt / nut
            parts.append(P_('scrap', A.Disc(p + np.array([0, 0, 0.5]), 1.1, 0.5, 0.2, M.UPAX), 'steel', f'{group}{k}'))
    return parts


def crate(c, k=1.0, yaw=0.0, tilt=0.0, group='crate'):
    R = A.rz(yaw) @ A.rx(tilt)
    body = c + R @ np.array([0, 0, 4.2 * k]) if tilt else c + np.array([0, 0, 4.2 * k])
    return [P_('crate', A.RoundBox(body, np.array([5.4, 4.4, 4.2]) * k, 0.9 * k, R), 'white', group, decal_crate)]


def rack(name, ang, rs, group):
    """Shelving against the wall, loaded with boxes."""
    c = room_pt(name, ang, r_in(name) - 5.2)
    yaw = math.radians(ang + 90)
    R = A.rz(yaw)
    w, dp, h = 10.0, 3.6, 23.0
    parts = []
    for sx in (-1, 1):
        parts.append(P_('post', A.RoundBox(c + R @ np.array([sx * w, 0, h / 2]), (0.7, dp, h / 2), 0.3, R), 'white', group))
    for z in (0.8, 8.0, 15.2, 22.4):
        parts.append(P_('shelf', A.RoundBox(c + R @ np.array([0, 0, z]), (w, dp, 0.45), 0.2, R), 'steel', group))
    ramps = ['white', 'coral', 'mustard', 'teal', 'white', 'sack']
    for z in (1.25, 8.45, 15.65):
        x = -w + 1.4
        while x < w - 2.0:
            sw = rs.uniform(1.2, 2.6)
            hh = rs.uniform(1.4, 3.0)
            if x + sw * 2 > w - 0.6:
                break
            if rs.random() < 0.85:
                parts.append(P_('box', A.RoundBox(c + R @ np.array([x + sw, rs.uniform(-0.6, 0.6), z + hh]),
                                                  (sw, rs.uniform(1.8, 2.8), hh), 0.35, R @ A.rz(rs.uniform(-0.1, 0.1))),
                                ramps[int(rs.integers(len(ramps)))], group))
            x += sw * 2 + rs.uniform(0.3, 0.9)
    return parts


def storage_props(rs):
    st = ROOMS['storage']
    C = cam(st['X'], st['Y'])
    parts = []
    parts += rack('storage', 34.0, rs, 'rackA')
    parts += rack('storage', 146.0, rs, 'rackB')
    # crate stacks
    for k, (dx, dy, z, kk, yaw) in enumerate([(-50, 22, 0, 1.0, 0.2), (-50, 22, 8.4, 0.85, 0.5), (-38, 30, 0, 0.9, -0.2),
                                              (-58, 6, 0, 0.8, 0.9)]):
        parts += crate(C + np.array([dx, dy, z]), kk, yaw, group=f'stackA{k}')
    for k, (dx, dy, kk, yaw) in enumerate([(48, -32, 0.9, 0.3), (60, -22, 0.75, -0.4)]):
        parts += crate(C + np.array([dx, dy, 0]), kk, yaw, group=f'stackB{k}')
    parts += crate(C + np.array([18, -50, 0.5]), 0.8, 0.6, tilt=1.15, group='tipped')            # knocked over
    # a cargo container
    R = A.rz(-0.25)
    parts.append(P_('container', A.RoundBox(C + np.array([52, 34, 7.2]), (11.5, 7.0, 7.2), 0.8, R), 'steel', 'container',
                    decal_container))
    # barrels
    for k, (dx, dy, ramp) in enumerate([(-30, -40, 'teal'), (-24, -46, 'mustard'), (-36, -48, 'teal')]):
        b = C + np.array([dx, dy, 4.0])
        parts.append(P_('barrel', A.Disc(b, 2.7, 4.0, 0.6, M.UPAX), ramp, f'barrel{k}', decal_barrel))
    # a pallet of sacks
    p0 = C + np.array([-6, -30, 0.0])
    parts.append(P_('pallet', A.RoundBox(p0 + np.array([0, 0, 0.6]), (6.0, 5.0, 0.6), 0.2, A.rz(0.3)), 'wood', 'pallet'))
    for k in range(4):
        off = A.rz(0.3) @ np.array([(-2.6 if k % 2 else 2.6), (-2.2 if k < 2 else 2.2), 2.4])
        parts.append(P_('sack', A.Ellipsoid(p0 + off, (2.8, 2.2, 1.5), A.rz(0.3 + k)), 'sack', 'pallet'))
    parts.append(P_('sack', A.Ellipsoid(p0 + np.array([0, 0, 4.6]), (2.8, 2.2, 1.5), A.rz(1.1)), 'sack', 'pallet'))
    # glass on the floor under the holes
    for k in range(26):
        X = C[0] + rs.uniform(-34, 34)
        Y = C[1] + rs.uniform(10, 44)
        sz = rs.uniform(0.6, 1.6)
        parts.append(P_('shard', A.RoundBox(cam(X, Y, 0.25), (sz, sz * 0.6, 0.18), 0.1, A.rz(rs.uniform(0, TAU))),
                        'tglass' if k % 3 else 'shard', f'gshard{k}'))
    return parts


def power_props(rs):
    """The power room: the reactor smashed open - a gash in its housing showing the dead core, the
    middle coil fallen to the floor, the cap knocked askew, wires spilling out - battery banks
    along the wall (one cable torn away), the console, and an open service cabinet with the
    circuit board that will have to be fixed."""
    pw = ROOMS['power']
    C = cam(pw['X'], pw['Y'] + 6)
    fx = dict(sparks=[], leds=[])
    gash = A.Ellipsoid(C + np.array([-3.0, -8.0, 15.5]), (4.8, 5.2, 5.4), A.rz(0.25))
    top = A.Disc(C + np.array([0, 0, 30.0]), 6.6, 6.5, 0.5, M.UPAX)
    parts = [P_('plinth', A.Disc(C + np.array([0, 0, 1.2]), 15.0, 1.2, 0.5, M.UPAX), 'steel', 'reactor'),
             P_('housing', Cut(A.Disc(C + np.array([0, 0, 15.0]), 9.5, 13.0, 2.0, M.UPAX), Either(gash, top)), 'white', 'reactor',
                decal_torn(decal_reactor)),
             P_('core', A.Disc(C + np.array([0, 0, 14.0]), 5.2, 10.0, 1.0, M.UPAX), 'redcore', 'reactor'),
             P_('coil', A.Torus(C + np.array([0, 0, 7.0]), 10.6, 1.3), 'mustard', 'coil7'),
             P_('coil', A.Torus(C + np.array([0, 0, 24.0]), 10.6, 1.3), 'mustard', 'coil24')]
    # the middle coil came down: it lies tipped against the plinth
    parts.append(P_('coil', A.Torus(C + np.array([14.0, -9.0, 3.0]), 10.6, 1.3, M.frame_z(A.nz([0.4, -0.25, 1.0]))),
                    'mustard', 'coilfallen'))
    # the cap, knocked askew
    cap_c = C + np.array([3.6, 4.4, 29.6])
    tilt = M.frame_z(A.nz([0.42, 0.34, 1.0]))
    parts += [P_('cap', A.Ellipsoid(cap_c, (9.6, 9.6, 3.0), tilt), 'white', 'cap'),
              P_('capring', A.Torus(cap_c - tilt[:, 2] * 0.4, 9.4, 0.8, tilt), 'coral', 'cap')]
    # wires spilling out of the gash and out of the open top, down to the floor
    ramps = ['coral', 'mustard', 'teal', 'cable', 'coral', 'cable', 'mustard']
    g0 = C + np.array([-3.0, -6.5, 15.5])
    for k in range(6):
        st = g0 + np.array([rs.uniform(-2.0, 2.0), 0, rs.uniform(-3.5, 3.5)])
        sx = rs.uniform(-0.9, 0.5)
        ctrl = st + np.array([sx * 2.5, -4.5, 1.0])
        end_ = cam(st[0] + sx * rs.uniform(5, 9), st[1] - rs.uniform(8, 12), 0.25)
        parts += wire(st, ctrl, end_, rs, ramps[k], f'wireg{k}', r=0.25, curl=2)
    for k, a in enumerate(np.radians([200, 228, 255, 290, 322])):
        u = np.array([math.cos(a), math.sin(a), 0.0])
        st = C + u * rs.uniform(2.0, 4.0) + np.array([0, 0, 27.0])
        parts += wire(st, C + u * 10.5 + np.array([0, 0, 31.0]), C + u * rs.uniform(11.8, 12.6) + np.array([0, 0, rs.uniform(15, 21)]),
                      rs, ramps[(k + 2) % 7], f'wiret{k}', r=0.27, n=8, curl=0)      # dangling over the rim
    fx['sparks'] += [g0 + np.array([0, -2.0, 2.0]), C + np.array([-2.0, -3.0, 28.5])]
    fx['core'] = C + np.array([-3.0, -8.0, 15.5])
    # battery banks along the back wall
    for k, ang in enumerate(np.linspace(52, 128, 5)):
        c = room_pt('power', ang, r_in('power') - 4.6, 10.5)
        R = A.rz(math.radians(ang + 90))
        parts.append(P_('cabinet', A.RoundBox(c, (5.0, 3.2, 10.5), 0.7, R), 'white', f'cab{k}', decal_cabinet))
        led = c + R @ np.array([0, 3.3, 8.4])
        parts.append(P_('cablight', A.Sphere(led, 0.6), 'ledred' if k == 2 else 'darkwin', f'cab{k}'))
        if k == 2:
            fx['leds'].append((led, 'slow'))
        a = C + A.nz(c - C) * 14.0
        a[2] = 0.9
        b = c.copy()
        b[2] = 0.9
        mid = (a + b) / 2 + np.array([rs.uniform(-4, 4), rs.uniform(-3, 3), 0.0])
        if k == 3:                                       # this one was torn out of its cabinet
            end_ = mid + A.nz(b - mid) * 9.0 + np.array([0, 0, 0.3])
            dirc = A.nz(end_ - mid)
            parts += [P_('cable', A.RoundCone(a, mid, 1.05, 1.05), 'cable', f'cable{k}'),
                      P_('cable', A.RoundCone(mid, end_, 1.05, 1.0), 'cable', f'cable{k}'),
                      P_('cableend', A.Disc(end_ + dirc * 0.8, 1.35, 0.8, 0.3, M.yaw_to(dirc)), 'steel', f'cable{k}')]
            tip = end_ + dirc * 1.4
            for j, ramp in enumerate(('coral', 'mustard', 'teal')):
                parts += wire(tip, tip + A.rz(0.5 * (j - 1)) @ dirc * 2.0 + np.array([0, 0, 1.2]),
                              tip + A.rz(0.7 * (j - 1)) @ dirc * 4.0, rs, ramp, f'cable{k}w{j}', r=0.3, n=6, curl=1)
            fx['sparks'].append(tip + dirc * 0.6 + np.array([0, 0, 0.6]))
            continue
        parts += [P_('cable', A.RoundCone(a, mid, 1.05, 1.05), 'cable', f'cable{k}'),
                  P_('cable', A.RoundCone(mid, b, 1.05, 1.05), 'cable', f'cable{k}')]
    # the control console
    cc = C + np.array([-34, -28, 0.0])
    R = A.rz(math.radians(-25))
    led = cc + R @ np.array([4.6, -1.0, 8.6])
    parts += [P_('console', A.RoundBox(cc + np.array([0, 0, 3.6]), (6.5, 3.0, 3.6), 0.6, R), 'white', 'console'),
              P_('desk', A.RoundBox(cc + R @ np.array([0, 0.4, 7.6]), (6.3, 3.0, 0.5), 0.3, R @ A.rx(-0.45)), 'steel', 'console'),
              P_('screen', A.RoundBox(cc + R @ np.array([0, 2.4, 10.4]), (5.0, 0.4, 2.6), 0.3, R @ A.rx(0.25)), 'darkwin', 'console'),
              P_('led', A.Sphere(led, 0.6), 'ledred', 'console')]
    fx['leds'].append((led, 'fault'))
    # the service cabinet, its door swung open on the circuit board
    sc = C + np.array([31.0, -26.0, 0.0])
    R = A.rz(math.radians(-14))
    parts += [P_('svc', A.RoundBox(sc + np.array([0, 0, 10.2]), (7.6, 3.4, 9.4), 0.7, R), 'white', 'svc'),
              P_('svcbase', A.RoundBox(sc + np.array([0, 0, 0.6]), (8.0, 3.8, 0.6), 0.3, R), 'steel', 'svc'),
              P_('svcstripe', A.RoundBox(sc + R @ np.array([0, 0, 18.1]), (7.7, 3.5, 0.55), 0.2, R), 'coral', 'svc'),
              P_('svcrecess', A.RoundBox(sc + R @ np.array([0, -3.3, 9.6]), (6.7, 0.3, 7.9), 0.2, R), 'chip', 'svc')]
    board_c = sc + R @ np.array([0.0, -3.55, 9.6])
    parts.append(P_('pcb', A.RoundBox(board_c, (6.0, 0.28, 7.4), 0.12, R), 'pcb', 'pcb', decal_pcb))
    hinge = sc + R @ np.array([-7.6, -3.5, 10.2])
    Rd = R @ A.rz(math.radians(-122))
    parts += [P_('svcdoor', A.RoundBox(hinge + Rd @ np.array([7.4, 0.3, 0.0]), (7.4, 0.32, 9.0), 0.3, Rd), 'white', 'svcdoor'),
              P_('svcdoorline', A.RoundBox(hinge + Rd @ np.array([7.4, 0.0, 6.4]), (7.0, 0.36, 0.45), 0.15, Rd), 'coral', 'svcdoor')]
    for j, ramp in enumerate(('coral', 'teal')):                  # two leads pulled off the board
        st = board_c + R @ np.array([4.6 - j * 1.4, -0.4, -6.0])
        fl = st + R @ np.array([2.0 + j, -7.0 - j * 2, 0])
        parts += wire(st, st + R @ np.array([1.5, -4.0, -2.0]), cam(fl[0], fl[1], 0.3), rs, ramp, f'pcbw{j}', r=0.3, n=8, curl=2)
    fx['pcb'] = dict(center=board_c, socket=board_c + R @ np.array([2.6, -0.4, 0.8]), half=(6.0, 7.4), R=R)
    fx['sparks'].append(board_c + R @ np.array([0.2, -0.6, -2.0]))
    # a big status screen on the back wall: dead, but for its warning
    sw = room_pt('power', 90.0, r_in('power') - 0.6, 27.0)
    parts.append(P_('wallscreen', A.RoundBox(sw, (13.0, 0.5, 3.4), 0.4, A.rz(0.0)), 'darkwin', 'wallscreen'))
    parts += scraps(C, rs, 20, 18, 44, 'pscrap', avoid=[(cc[0], cc[1], 9), (sc[0], sc[1], 13), (C[0] + 14, C[1] - 9, 13)])
    return parts, C, fx


def oxygen_props(rs):
    """The oxygen room: the two big O2 bottles, and between them the oxygen generator, broken down -
    its glass turbine chamber smashed open on a bent fan, the cap knocked askew, a side panel blown
    off with wires spilling out, a coolant cylinder fallen to the floor, the pipe to one bottle
    snapped and leaking, scrap metal everywhere. Planters along the front, pipes and a vent on the
    wall."""
    ox = ROOMS['oxygen']
    C = cam(ox['X'], ox['Y'] + 4)
    parts = []
    fx = dict(sparks=[], leds=[], vapor=[])
    tanks = []
    for k, ang in enumerate((60.0, 120.0)):
        t = room_pt('oxygen', ang, r_in('oxygen') - 12.5)
        tanks.append(t)
        parts += [P_('tankbase', A.Disc(t + np.array([0, 0, 1.4]), 9.2, 1.4, 0.5, M.UPAX), 'steel', f'tank{k}'),
                  P_('tank', A.RoundCone(t + np.array([0, 0, 10.0]), t + np.array([0, 0, 30.0]), 8.2, 8.2), 'white', f'tank{k}',
                     decal_tank),
                  P_('gauge', A.Disc(t + A.nz(C - t) * 8.0 + np.array([0, 0, 17.0]), 2.0, 0.5, 0.3, M.yaw_to(A.nz(C - t))),
                     'darkwin', f'tank{k}'),
                  P_('valve', A.Torus(t + np.array([0, 0, 38.6]), 2.4, 0.7), 'teal', f'tank{k}')]
    # the generator: a housing on a plinth, a side panel blown out of it
    panel_hole = A.RoundBox(C + np.array([-6.0, -8.8, 8.6]), (4.4, 2.2, 4.2), 0.6)
    parts += [P_('o2plinth', A.RoundBox(C + np.array([0, 0, 1.0]), (17.5, 12.0, 1.0), 0.5), 'steel', 'gen', decal_hazard),
              P_('o2housing', Cut(A.RoundBox(C + np.array([0, 0, 8.6]), (12.5, 8.4, 7.2), 1.6), panel_hole), 'white', 'gen',
                 decal_torn(decal_o2)),
              P_('o2coil', A.Disc(C + np.array([-6.5, -5.4, 8.6]), 2.8, 2.6, 0.6, M.UPAX), 'mustard', 'gen'),
              P_('o2panel', A.RoundBox(C + np.array([-18.0, -20.0, 0.75]), (4.4, 4.2, 0.32), 0.25, A.rz(0.7) @ A.rx(0.12)),
                 'white', 'genpanel')]
    for k, ramp in enumerate(('coral', 'mustard', 'teal', 'cable')):
        st = C + np.array([-6.5 + rs.uniform(-2.5, 2.5), -7.4, 8.6 + rs.uniform(-2.5, 2.5)])
        sx = rs.uniform(-1.0, 0.2)
        parts += wire(st, st + np.array([sx * 3, -4.5, 1.0]), cam(st[0] + sx * rs.uniform(6, 10), st[1] - rs.uniform(8, 13), 0.45),
                      rs, ramp, f'o2wire{k}')
    fx['sparks'].append(C + np.array([-6.5, -9.5, 10.0]))
    # cooling fins down its right side, two of them buckled
    for j, y in enumerate(np.arange(-6.6, 6.7, 1.65)):
        R = A.rz(0.0) if j not in (2, 3) else A.rx(0.35 if j == 2 else -0.3) @ A.rz(0.12)
        parts.append(P_('fin', A.RoundBox(C + np.array([14.0, y, 8.2]), (1.7, 0.22, 5.2), 0.12, R), 'steel', 'fins'))
    parts.append(P_('finbar', A.RoundBox(C + np.array([14.2, 0.0, 13.6]), (1.9, 7.4, 0.5), 0.2), 'teal', 'fins'))
    # two electrolysis cells on top, behind the chamber: one still holding its fluid, one cracked and drained
    for k, dx in enumerate((-10.2, 10.2)):
        cc_ = C + np.array([dx, -2.6, 0.0])
        parts += [P_('cellbase', A.Disc(cc_ + np.array([0, 0, 16.6]), 3.4, 0.9, 0.3, M.UPAX), 'white', f'cell{k}'),
                  P_('cellcap', A.Disc(cc_ + np.array([0, 0, 28.4]), 3.4, 0.9, 0.3, M.UPAX), 'white', f'cell{k}'),
                  P_('cellrod', A.RoundCone(cc_ + np.array([0, 0, 29.2]), cc_ + np.array([0, 0, 31.5]), 0.7, 0.5), 'steel', f'cell{k}')]
        if k == 0:
            parts += [P_('liquid', A.Disc(cc_ + np.array([0, 0, 20.4]), 2.7, 3.0, 0.3, M.UPAX), 'liquid', f'cell{k}'),
                      P_('cellglass', A.Disc(cc_ + np.array([0, 0, 25.5]), 2.7, 2.2, 0.3, M.UPAX), 'tglass', f'cell{k}')]
        else:
            crack = A.Ellipsoid(cc_ + np.array([-0.8, -2.6, 23.0]), (1.8, 1.6, 2.6))
            parts.append(P_('cellglass', Cut(A.Disc(cc_ + np.array([0, 0, 22.5]), 2.7, 5.2, 0.3, M.UPAX), crack), 'tglass', f'cell{k}',
                            decal_glass))
    # the turbine chamber: a tube of tinted glass, smashed open at the front on a bent fan
    tube = Cut(A.Disc(C + np.array([0, 0, 22.5]), 8.0, 7.0, 1.0, M.UPAX), A.Disc(C + np.array([0, 0, 22.5]), 7.0, 8.0, 0.5, M.UPAX))
    smash = A.Ellipsoid(C + np.array([1.5, -8.0, 22.5]), (5.4, 3.8, 4.6), A.rz(0.3))
    parts += [P_('chamber', Cut(tube, smash), 'tglass', 'chamber', decal_glass),
              P_('chring', A.Torus(C + np.array([0, 0, 15.8]), 8.0, 0.9), 'white', 'chamber'),
              P_('chring', A.Torus(C + np.array([0, 0, 29.2]), 8.0, 0.9), 'white', 'chamber'),
              P_('hub', A.Disc(C + np.array([0, 0, 22.5]), 1.5, 6.0, 0.4, M.UPAX), 'steel', 'fan')]
    for j in range(6):
        a = j / 6 * TAU + 0.3
        bent = j in (1, 4)
        if j == 2:                                       # this blade snapped off and fell in
            parts.append(P_('blade', A.RoundBox(C + np.array([3.0, 2.0, 16.9]), (2.6, 0.3, 1.5), 0.2, A.rz(0.9) @ A.rx(1.35)),
                            'steel', 'fan'))
            continue
        R = A.rz(a) @ A.rx(0.45 + (0.65 if bent else 0.0)) @ A.ry(0.35 if bent else 0.0)
        parts.append(P_('blade', A.RoundBox(C + np.array([math.cos(a) * 3.7, math.sin(a) * 3.7, 22.5]),
                                            (2.7 if not bent else 2.2, 0.32, 4.2), 0.2, R), 'steel', 'fan'))
    # the cap, knocked askew
    tilt = M.frame_z(A.nz([-0.32, 0.18, 1.0]))
    parts += [P_('o2cap', A.Ellipsoid(C + np.array([-1.8, 1.2, 31.6]), (8.8, 8.8, 2.4), tilt), 'white', 'o2cap'),
              P_('o2capring', A.Torus(C + np.array([-1.8, 1.2, 31.2]), 8.6, 0.7, tilt), 'teal', 'o2cap'),
              P_('o2vent', A.Disc(C + np.array([-2.4, 1.5, 33.7]), 3.0, 0.6, 0.3, tilt @ A.ry(-math.pi / 2)), 'steel', 'o2cap')]
    # coolant cylinders: one still clamped on, one fallen to the floor
    parts += [P_('coolant', A.RoundCone(C + np.array([-14.4, -4.0, 6.0]), C + np.array([-14.4, 6.5, 6.0]), 3.2, 3.2), 'teal', 'cool0'),
              P_('coolband', A.Torus(C + np.array([-14.4, 1.2, 6.0]), 3.35, 0.5, A.rx(math.pi / 2)), 'white', 'cool0'),
              P_('coolant', A.RoundCone(C + np.array([16.0, -16.5, 3.2]), C + np.array([25.0, -8.0, 3.2]), 3.2, 3.2), 'teal', 'cool1'),
              P_('coolband', A.Torus(C + np.array([20.5, -12.25, 3.2]), 3.35, 0.5, M.frame_z(A.nz([9.0, 8.5, 0.0]))), 'white',
                 'cool1')]
    # the control panel on its front, a fault light blinking
    pc = C + np.array([6.5, -9.4, 10.6])
    parts += [P_('o2ctl', A.RoundBox(pc, (3.6, 1.2, 2.8), 0.4, A.rx(0.25)), 'steel', 'o2ctl'),
              P_('o2screen', A.RoundBox(pc + np.array([-0.7, -1.1, 0.2]), (2.3, 0.2, 1.7), 0.2, A.rx(0.25)), 'darkwin', 'o2ctl'),
              P_('o2led', A.Sphere(pc + np.array([2.5, -1.3, 1.2]), 0.55), 'ledred', 'o2ctl')]
    fx['leds'].append((pc + np.array([2.5, -1.3, 1.2]), 'fault'))
    # pipes to the bottles: one intact, one snapped and leaking
    for k, t in enumerate(tanks):
        a = C + np.array([0, 0, 26.0]) + A.nz(t - C) * 8.4
        b = t + np.array([0, 0, 24.0]) + A.nz(C - t) * 7.8
        if k == 1:
            mid = a + (b - a) * 0.42 + np.array([0, 0, -3.0])
            parts += [P_('pipe', A.RoundCone(a, mid, 1.1, 1.1), 'teal', f'pipe{k}'),
                      P_('pipe', A.Torus(mid, 1.15, 0.45, M.frame_z(mid - a)), 'steel', f'pipe{k}'),
                      P_('pipe', A.RoundCone(b, b + (a - b) * 0.3, 1.1, 1.1), 'teal', f'pipe{k}b')]
            fx['vapor'].append((mid, A.nz(mid - a)))
        else:
            parts.append(P_('pipe', A.RoundCone(a, b, 1.1, 1.1), 'teal', f'pipe{k}'))
    # hydroponic planters along the front
    for k, (dx, dy, yaw) in enumerate([(-40, -38, 0.35), (38, -40, -0.35)]):
        c = C + np.array([dx, dy, 0.0])
        R = A.rz(yaw)
        parts += [P_('planter', A.RoundBox(c + np.array([0, 0, 2.8]), (11.0, 3.6, 2.8), 0.6, R), 'white', f'plant{k}'),
                  P_('soil', A.RoundBox(c + np.array([0, 0, 5.3]), (10.1, 2.9, 0.5), 0.2, R), 'soil', f'plant{k}'),
                  P_('lightbar', A.RoundBox(c + np.array([0, 0, 15.5]), (10.5, 0.8, 0.5), 0.2, R), 'darkwin', f'plant{k}')]
        for sx in (-1, 1):
            parts.append(P_('lightpost', A.RoundCone(c + R @ np.array([sx * 10.0, 0, 5.5]), c + R @ np.array([sx * 10.0, 0, 15.3]),
                                                     0.45, 0.4), 'steel', f'plant{k}'))
        for j in range(6):
            x = -8.5 + j * 3.4
            r = rs.uniform(1.8, 2.8)
            parts.append(P_('leafy', A.Sphere(c + R @ np.array([x, rs.uniform(-1, 1), 6.2 + r * 0.7]), r),
                            'leaf' if j % 2 else 'leaf2', f'plant{k}'))
    # a pipe run along the back wall, a vent fan
    for k, (a0, a1) in enumerate([(28, 58), (62, 118), (122, 152)]):
        pa = room_pt('oxygen', a0, r_in('oxygen') - 2.0, 13.0)
        pb = room_pt('oxygen', a1, r_in('oxygen') - 2.0, 13.0)
        parts.append(P_('wpipe', A.RoundCone(pa, pb, 1.0, 1.0), 'teal', f'wpipe{k}'))
    v = room_pt('oxygen', 158.0, r_in('oxygen') - 0.4, 22.0)
    Rv = M.yaw_to(A.nz(C - v))
    parts += [P_('vent', A.Disc(v, 6.0, 0.6, 0.4, Rv), 'steel', 'vent'),
              P_('ventring', A.Torus(v + A.nz(C - v) * 0.4, 5.6, 0.7, Rv @ A.ry(math.pi / 2)), 'white', 'vent')]
    for j in range(5):
        a = j / 5 * TAU
        d = Rv @ np.array([0, math.cos(a), math.sin(a)])
        parts.append(P_('vblade', A.RoundCone(v + A.nz(C - v) * 0.7, v + A.nz(C - v) * 0.7 + d * 4.8, 0.9, 0.5), 'cable', 'vent'))
    parts += scraps(C, rs, 22, 20, 44, 'oscrap', avoid=[(C[0] - 40, C[1] - 38, 14), (C[0] + 38, C[1] - 40, 14),
                                                       (C[0] + 20.5, C[1] - 12, 8), (C[0] - 18, C[1] - 20, 7)])
    return parts, C, tanks, fx


# ================================================================== shading
def wall_layers(P):
    """For wall points: which room (or corridor), its own normal, face kind (0 inner, 1 outer, 2 top),
    angle round the room and arc position."""
    n = len(P)
    room = np.full(n, -1, np.int16)
    best = np.full(n, np.inf)
    th = np.zeros(n)
    for i, rm in enumerate(ROOMS.values()):
        dx, dy = P[:, 0] - rm['X'], P[:, 1] - rm['Y']
        r = np.hypot(dx, dy)
        dd = np.abs(r - rm['R'])
        sel = dd < np.minimum(best, WALL_T * 1.2)
        room[sel] = i
        best[sel] = dd[sel]
        th[sel] = np.arctan2(dy, dx)[sel]
    return room, th


def shade_walls(img, D, gid, wall_gids, bay_img):
    t0 = time.time()
    ys, xs = np.nonzero(np.isin(gid, wall_gids))
    O = view_rays(ys, xs)
    t = (D[ys, xs] - O[:, 1]) / M.F[1]
    P = O + t[:, None] * M.F
    z = P[:, 2]
    bay = bay_img[ys, xs]
    room, th = wall_layers(P)
    names = list(ROOMS)
    col = np.zeros((len(P), 3), np.float32)
    # face and normal
    nrm = np.zeros_like(P)
    face = np.zeros(len(P), np.int8)
    rr = np.zeros(len(P))
    for i, name in enumerate(names):
        sel = room == i
        if not sel.any():
            continue
        rm = ROOMS[name]
        dx, dy = P[sel, 0] - rm['X'], P[sel, 1] - rm['Y']
        r = np.hypot(dx, dy)
        rr[sel] = r
        h = RoomWall(name, []).height(th[sel])
        inner = r < rm['R']
        f = np.where(z[sel] > h - 0.8, 2, np.where(inner, 0, 1))
        face[sel] = f
        nrm[sel] = np.stack([dx / r, dy / r, np.zeros_like(r)], -1) * np.where(inner, -1, 1)[:, None]
    cor = room < 0                                        # corridor walls
    face[cor & (z > CORR_H - 0.8)] = 2
    face[cor & (z > WALL_LOW - 0.8) & (P[:, 1] < OY)] = 2
    nrm[cor] = (0.0, -1.0, 0.0)
    # height bands on the inner faces
    inner = face == 0
    outer = face == 1
    top = face == 2
    view = -M.F / np.linalg.norm(M.F)
    facing = np.clip(nrm @ np.array([view[0], view[1], 0.0]) / max(np.hypot(view[0], view[1]), 1e-6), 0, 1)
    sheen = 0.08 * facing ** 3 + 0.12 * (facing > 0.985) + 0.06 * (facing > 0.95)
    I = 0.8 + 0.12 * np.clip((z - KICK) / 24.0, 0, 1) - 0.08 * np.clip((z - 40) / 16.0, 0, 1) + sheen
    arc = th * rr
    seam = (np.abs(np.mod(np.degrees(th) + 5, 10.0) - 5.0) < np.degrees(0.35 / np.maximum(rr, 1)))
    seam = np.where(cor, np.mod(P[:, 0] + 3.0, 14.0) < 0.35, seam)
    seam |= (np.abs(z - 17.0) < 0.3) | (np.abs(z - 26.5) < 0.3)
    I = I - 0.07 * seam
    lv = np.clip(np.floor(I * 6.2 + bay * 0.7), 0, 6).astype(int)
    col[:] = WHITE[lv]
    kick = inner & (z < KICK)
    col[kick] = DARK[np.clip(np.floor(1.5 + z[kick] / KICK * 2 + bay[kick] * 0.6), 0, 4).astype(int)]
    em = inner & (z > EMERG[0]) & (z < EMERG[1])
    col[em] = CYAN * 0.75 + DARK[1] * 0.25
    cs = inner & (z > CORAL[0]) & (z < CORAL[1])
    col[cs] = CORAL_R[np.clip(np.floor(1.6 + 1.4 * facing[cs] + bay[cs] * 0.6), 0, 3).astype(int)]
    # windows: two rows of hexagons glowing with daylight; the corridors get a light strip instead
    win = inner & (z > WIN[0]) & (z < WIN[1])
    arc = np.where(cor, P[:, 0], arc)
    glow_mask = np.zeros(len(P), np.float32)
    hole_mask = np.zeros(len(P), bool)
    if win.any():
        a = (WIN[1] - WIN[0]) / 2.5
        x = arc[win]
        y = z[win] - WIN[0]
        qi, ri, px, py, edge = M.hex_cell(x, y - a / 2, a)
        frame = (edge < 0.32) | (y < 0.45) | (y > WIN[1] - WIN[0] - 0.45)
        k = np.clip(np.floor((y / (WIN[1] - WIN[0])) * 3.2 + bay[win] * 0.8 + 0.4 * M._h(qi, ri, 3)), 0, 3).astype(int)
        cw = SKYWIN[k].copy()
        cw[frame] = WHITE[4]
        sw = np.mod(xs[win] * 1.0 + ys[win] * 1.5, 70.0) < 3.5
        cw[sw & ~frame] = cw[sw & ~frame] * 0.6 + 255 * 0.4
        col[win] = cw
        glow_mask[np.nonzero(win)[0][~frame]] = 0.55
        # storage: the two smashed panes, bright with sun
        si = names.index('storage')
        for kind_, ang in HOLES:
            rs = np.random.default_rng(int(ang))
            poly, cracks = M.hole_shape(kind_, a * 1.15, rs)
            st = (room[win] == si)
            lx = x - math.radians(ang) * rr[win]
            ly = y - (WIN[1] - WIN[0]) / 2
            near = st & (np.abs(lx) < 4 * a) & (np.abs(ly) < 4 * a)
            if not near.any():
                continue
            ix = np.nonzero(near)[0]
            inside = M._poly_inside(lx[ix], ly[ix], poly)
            pdist = M._poly_dist(lx[ix], ly[ix], poly)
            cdist = M._crack_dist(lx[ix], ly[ix], cracks, w0=0.3, w1=0.14)
            wi = np.nonzero(win)[0]
            col[wi[ix[inside]]] = SUNLIGHT * 0.5 + 255 * 0.5
            col[wi[ix[~inside & (pdist < 0.6)]]] = 255
            col[wi[ix[~inside & (cdist < 0)]]] = col[wi[ix[~inside & (cdist < 0)]]] * 0.3 + 255 * 0.7
            glow_mask[wi[ix[inside]]] = 1.0
            hole_mask[wi[ix[inside]]] = True
    strip = inner & cor & (np.abs(z - 22.0) < 0.6) & False
    col[strip] = CYAN * 0.6 + WHITE[3] * 0.4
    # outer faces of the cut-away front walls: white, a coral line
    oc = outer & (z > 1.8) & (z < 2.8)
    col[oc] = CORAL_R[2]
    col[outer & (z < 1.0)] = WHITE[2]
    # the tops of the walls: bright caps
    col[top] = WHITE[np.clip(np.floor(5.0 + bay[top] * 0.6), 0, 6).astype(int)]
    img[ys, xs] = np.clip(col, 0, 255).astype(np.uint8)
    glow = np.zeros(D.shape, np.float32)
    glow[ys, xs] = glow_mask
    glow[ys[em], xs[em]] = 0.6
    print(f'walls shaded in {time.time() - t0:.1f}s')
    return glow, (ys[hole_mask], xs[hole_mask]), (P[hole_mask])


def shade_floor(img, D, kind, region, Xf, Yf, ys, xs, bay, prop_ao, shafts_floor):
    """Glossy diamond tiles; a dark ring with a light line round each room; an emblem in each;
    the walls mirrored in the gloss; sunlit patches with sand and glass under storage's holes."""
    t0 = time.time()
    n = len(ys)
    names = list(ROOMS)
    col = np.zeros((n, 3), np.float32)
    u, v = (Xf + Yf) / M.SQ2, (Yf - Xf) / M.SQ2
    tile = 12.0
    tu, tv = np.floor(u / tile), np.floor(v / tile)
    seam = (np.mod(u, tile) < 0.45) | (np.mod(v, tile) < 0.45)
    check = np.mod(tu + tv, 2) == 0
    I = 0.74 + 0.04 * check - 0.16 * seam
    I += 0.03 * M._h(tu, tv, 2)
    glow = np.zeros(n, np.float32)
    ring_dark = np.zeros(n, bool)
    for i, name in enumerate(names):
        rm = ROOMS[name]
        sel = region == i + 1
        if not sel.any():
            continue
        r = np.hypot(Xf[sel] - rm['X'], Yf[sel] - rm['Y'])
        Ri = r_in(name)
        I[sel] -= 0.22 * np.clip((r - (Ri - 4)) / 4, 0, 1)                    # dim where floor meets wall
        band = (r > Ri - 13) & (r < Ri - 6)
        idx = np.nonzero(sel)[0]
        ring_dark[idx[band]] = True
        line = (np.abs(r - (Ri - 9.5)) < 0.6)
        glow[idx[line]] = 0.8
        # emblem
        cx, cy = rm['X'], rm['Y'] + (6 if name != 'storage' else 0)
        rc = np.hypot(Xf[sel] - cx, Yf[sel] - cy)
        ac = np.arctan2(Yf[sel] - cy, Xf[sel] - cx)
        if name == 'storage':                            # a cargo lift hatch
            em = rc < 15
            I[idx[em]] = 0.62 + 0.05 * (np.mod(np.floor(ac[em] / (TAU / 8)), 2))
            I[idx[(np.abs(rc - 15) < 0.7) | (np.abs(rc - 6.5) < 0.5)]] -= 0.25
            col_coral = (np.abs(rc - 13.2) < 0.8)
            glow[idx[col_coral]] = -1.0                  # marker: coral ring
        elif name == 'power':                            # hazard ring round the reactor
            hz = (rc > 16.5) & (rc < 20.0)
            stripes = np.mod(np.floor((ac + rc * 0.02) / (TAU / 32)), 2) == 0
            glow[idx[hz & stripes]] = -2.0
            glow[idx[hz & ~stripes]] = -3.0
        else:                                            # a teal ring round the column
            glow[idx[np.abs(rc - 11.5) < 0.9]] = 0.7
    cor = region == 10
    if cor.any():
        yc = OY + 5.0
        I[cor & (np.abs(np.abs(Yf - yc) - CORR_HALF) < 2.5)] -= 0.15
        chev = cor & (np.abs(np.mod(np.abs(Xf) - np.abs(Yf - yc) * 0.8, 14.0) - 7.0) < 1.1) & (np.abs(Yf - yc) < 7.0)
        glow[chev] = -4.0
    pw = ROOMS['power']
    grate = (region == 2) & (np.hypot(Xf - pw['X'], Yf - pw['Y'] - 6) > 20.0) & (np.hypot(Xf - pw['X'], Yf - pw['Y'] - 6) < 30.0)
    I[grate & ((np.mod(u, 2.2) < 0.6) | (np.mod(v, 2.2) < 0.6))] -= 0.22
    # gloss: the walls mirrored in the floor
    refl = np.zeros(n, np.float32)
    rcol = np.zeros((n, 3), np.float32)
    Rd = np.array([M.F[0], M.F[1], -M.F[2]])
    for i, name in enumerate(names):
        sel = np.nonzero(region == i + 1)[0]
        if sel.size == 0:
            continue
        rm = ROOMS[name]
        px, py = Xf[sel] - rm['X'], Yf[sel] - rm['Y']
        a = Rd[0] ** 2 + Rd[1] ** 2
        b = 2 * (px * Rd[0] + py * Rd[1])
        c = px * px + py * py - r_in(name) ** 2
        tt = (-b + np.sqrt(np.maximum(b * b - 4 * a * c, 0))) / (2 * a)
        zz = tt * Rd[2] + bay[sel] * 1.2
        w = (zz > WIN[0]) & (zz < WIN[1])
        refl[sel[w]] = 0.22
        rcol[sel[w]] = SKYWIN[2]
        c2 = (zz > CORAL[0]) & (zz < CORAL[1])
        refl[sel[c2]] = 0.16
        rcol[sel[c2]] = CORAL_R[2]
        e2 = (zz > EMERG[0]) & (zz < EMERG[1] + 0.6)
        refl[sel[e2]] = 0.3
        rcol[sel[e2]] = CYAN
        wh = ~w & ~c2 & ~e2 & (zz < WALL_H) & (zz > KICK)
        refl[sel[wh]] = 0.07
        rcol[sel[wh]] = WHITE[6]
    I -= 0.3 * prop_ao
    lv = np.clip(np.floor(I * 7.4 + bay * 0.7), 0, 7).astype(int)
    col[:] = FLOOR[lv]
    col[ring_dark] = DARK[np.clip(np.floor(2.4 + bay[ring_dark] * 0.7), 0, 4).astype(int)]
    col = col * (1 - refl[:, None]) + rcol * refl[:, None]
    gl = glow > 0
    col[gl] = col[gl] * (1 - glow[gl, None] * 0.8) + CYAN * glow[gl, None] * 0.8
    col[glow == -1.0] = CORAL_R[2]
    col[glow == -2.0] = HAZ[1]
    col[glow == -3.0] = HAZ[0]
    col[glow == -4.0] = col[glow == -4.0] * 0.35 + AMBER * 0.65
    # sunlit patches under the holes, sand blown in through them
    if shafts_floor:
        lit = np.zeros(n, np.float32)
        for poly in shafts_floor:
            pin = M._poly_inside(Xf, Yf, poly)
            pd = M._poly_dist(Xf, Yf, poly)
            lit = np.maximum(lit, np.where(pin, 1.0, np.clip(1 - pd / 4.0, 0, 1) * 0.5))
        st = region == 1
        cx_, cy_ = ROOMS['storage']['X'] + 6, OY + 36
        wob = 5 * np.sin(Xf * 0.17 + 1.3) + 4 * np.sin(Yf * 0.23 + Xf * 0.05) + 2.5 * np.sin(Xf * 0.5 - Yf * 0.4)
        dd = np.hypot((Xf - cx_) * 0.75, (Yf - cy_) * 1.3) + wob
        depth_ = np.clip((30 - dd) / 14, 0, 1)                           # thick in the middle, thinning out
        ripple = np.sin((Xf * 0.6 + Yf * 0.9) * 0.9 + wob * 0.3) > 0.55
        lv_s = np.floor(depth_ * 3 + bay * 0.9 + 0.1)
        sand = st & (lv_s >= 1)
        mix = np.clip(lv_s / 3, 0, 1) * 0.85
        tone = np.where(ripple & (lv_s >= 2), 1.12, 1.0)
        col[sand] = col[sand] * (1 - mix[sand, None]) + SAND * tone[sand, None] * mix[sand, None]
        q = np.floor(lit * 3 + bay * 0.9) / 3
        col = col * (1 - 0.5 * q[:, None]) + SUNLIGHT * 0.5 * q[:, None] + 20 * q[:, None]
    img[ys, xs] = np.clip(col, 0, 255).astype(np.uint8)
    g = np.zeros(D.shape, np.float32)
    g[ys, xs] = np.clip(glow, 0, 1)
    print(f'floor shaded in {time.time() - t0:.1f}s')
    return g


# ================================================================== the light through the holes
def hole_world_polys():
    """Each smashed pane in storage's back wall as a polygon in the world."""
    a = (WIN[1] - WIN[0]) / 2.5
    Ri = r_in('storage')
    st = ROOMS['storage']
    out = []
    for kind_, ang in HOLES:
        rs = np.random.default_rng(int(ang))
        poly, _ = M.hole_shape(kind_, a * 1.15, rs)
        pts = []
        for lx, ly in poly:
            th = math.radians(ang) + lx / Ri
            z = WIN[0] + (WIN[1] - WIN[0]) / 2 + ly
            pts.append(cam(st['X'] + Ri * math.cos(th), st['Y'] + Ri * math.sin(th), z))
        out.append(np.array(pts))
    return out


def shaft_geometry():
    """Light shafts: the hole polygons, where their light lands on the floor, and the screen polygon
    each shaft covers (for the haze and the dust)."""
    out = []
    for poly in hole_world_polys():
        t = poly[:, 2] / -LIGHT_IN[2]
        land = poly + t[:, None] * LIGHT_IN
        scr = np.array([M.project(*p) for p in np.vstack([poly, land])])
        from scipy.spatial import ConvexHull
        hull = scr[ConvexHull(scr).vertices]
        out.append(dict(hole=poly, floor=land[:, :2], hull=hull))
    return out


def fill_poly_mask(poly, h, w):
    """Pixels inside a screen-space polygon."""
    jj, ii = np.mgrid[0:h, 0:w]
    x0, y0 = poly.min(axis=0).astype(int)
    x1, y1 = poly.max(axis=0).astype(int) + 1
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
    m = np.zeros((h, w), bool)
    if x1 <= x0 or y1 <= y0:
        return m
    yy, xx = np.mgrid[y0:y1, x0:x1]
    m[y0:y1, x0:x1] = M._poly_inside(xx + 0.5, yy + 0.5, poly)
    return m


# ================================================================== build
def build():
    t_start = time.time()
    os.makedirs(os.path.join(OUT, 'anim'), exist_ok=True)
    set_frame()
    W, H = M.W, M.H
    M.SUN = SUN_IN
    img = np.zeros((H, W, 3), np.uint8)
    D = np.full((H, W), np.inf, np.float32)
    kind = np.zeros((H, W), np.uint8)
    gid = np.zeros((H, W), np.int32)
    jj, ii = np.mgrid[0:H, 0:W]
    bay_img = M.BAYER[jj % 4, ii % 4]
    rs = np.random.default_rng(77)

    # --- the floor (plane z = 0)
    O = view_rays(jj.ravel(), ii.ravel())
    t = -O[:, 2] / M.F[2]
    P = O + t[:, None] * M.F
    region = floor_region(P[:, 0], P[:, 1]).reshape(H, W)
    fl = region > 0
    D[fl] = P[:, 1].reshape(H, W)[fl]
    kind[fl] = 1
    Xf, Yf = P[:, 0].reshape(H, W), P[:, 1].reshape(H, W)
    del O, t, P

    # --- walls
    t0 = time.time()
    gb = 1
    wparts = wall_parts()
    gw0 = gb
    gb = M.render_groups(wparts, img, D, kind, gid, gb)
    wall_gids = np.arange(gw0, gb)
    print(f'walls in {time.time() - t0:.1f}s')

    # --- furniture
    t0 = time.time()
    s_parts = storage_props(rs)
    p_parts, reactor_c, pfx = power_props(rs)
    o_parts, gen_c, tanks, ofx = oxygen_props(rs)
    gb = M.render_groups(s_parts + p_parts + o_parts, img, D, kind, gid, gb)
    gb = M.render_groups(door_parts(0.0), img, D, kind, gid, gb)
    print(f'furniture in {time.time() - t0:.1f}s')

    # footprints for soft contact shadows on the floor and for the walk grid
    foot = np.zeros((N, N), bool)
    c = np.arange(N, dtype=np.float32) + 0.5
    U, V = np.meshgrid(c, c, indexing='ij')
    Xg, Yg = (U - V) / M.SQ2, (U + V) / M.SQ2
    for p in s_parts + p_parts + o_parts:
        if p.name in STEP_OVER:
            continue
        cc, r = part_bound(p.sdf)
        if cc[2] - r > BODY_H:                           # things up on the wall or overhead
            continue
        u0, v0 = M.to_grid(cc[0], cc[1])
        w_ = int(r) + 2
        a0, a1, b0, b1 = max(0, int(u0) - w_), min(N, int(u0) + w_ + 1), max(0, int(v0) - w_), min(N, int(v0) + w_ + 1)
        if a1 <= a0 or b1 <= b0:
            continue
        X, Y = Xg[a0:a1, b0:b1].ravel(), Yg[a0:a1, b0:b1].ravel()
        hit = np.zeros(X.size, bool)
        for z in np.linspace(0.6, BODY_H, 5):            # does it fill any of the space you'd walk through?
            hit |= p.sdf(np.stack([X, Y, np.full_like(X, z)], axis=1)) < 0.3
        foot[a0:a1, b0:b1] |= hit.reshape(a1 - a0, b1 - b0)
    foot = ndi.binary_fill_holes(foot)
    ao_grid = ndi.gaussian_filter(foot.astype(np.float32), 3.0)

    # --- shading
    sh = shaft_geometry()
    ys, xs = np.nonzero(fl & (gid == 0))
    pu, pv = M.to_grid(Xf[ys, xs], Yf[ys, xs])
    prop_ao = np.clip(M.sample(ao_grid, pu, pv) * 1.3, 0, 1)
    fglow = shade_floor(img, D, kind, region[ys, xs], Xf[ys, xs], Yf[ys, xs], ys, xs, bay_img[ys, xs], prop_ao,
                        [s['floor'] for s in sh])
    wglow, _, _ = shade_walls(img, D, gid, wall_gids, bay_img)

    # --- outlines
    dark = (img.astype(np.float32) * 0.62).astype(np.uint8)
    M.depth_lines(img, dark, D, kind, gid)

    # --- the light: shafts of sun, a soft bloom on everything that glows
    out = img.astype(np.float32)
    for s in sh:
        m = fill_poly_mask(s['hull'], H, W)
        top, bot = s['hull'][:, 1].min(), s['hull'][:, 1].max()
        fade = 1 - 0.55 * np.clip((jj - top) / max(bot - top, 1), 0, 1)          # brightest at the hole
        lvl = np.floor(np.clip(0.7 * fade, 0, 1) * 3 + bay_img * 0.9 + 0.2) / 3
        a = 0.34 * lvl
        out[m] = out[m] * (1 - a[m, None]) + np.array([255, 200, 120], np.float32) * a[m, None] + 18 * lvl[m, None]
    glow = np.maximum(fglow, wglow)
    for sigma, k in ((2.0, 0.24), (7.0, 0.16)):
        g = ndi.gaussian_filter(glow, sigma)
        out += g[..., None] * k * np.array([140, 220, 210], np.float32)
    # emissive props (leds, the column, the lock's light) bloom too
    em = np.zeros((H, W), np.float32)
    for name in ('ledred', 'ledcyan', 'liquid', 'window'):
        cols = M.O_RGB[OID[name]][2:]
        for cc in cols:
            em = np.maximum(em, np.all(img == cc, axis=-1).astype(np.float32))
    out += ndi.gaussian_filter(em, 3.0)[..., None] * 60
    # --- the void round the cutaway, and its silhouette
    filled = kind > 0
    yy = np.arange(H, dtype=np.float32)[:, None, None] / H
    back = VOID_TOP * (1 - yy) + VOID_BOT * yy
    final = np.where(filled[..., None], np.clip(out, 0, 255), back).astype(np.uint8)
    pad = np.pad(filled, 1)
    ring = (pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]) & ~filled
    final[ring] = M.OUTLINE
    for name, txt, ang, z, colr in (('storage', 'STORAGE', 64.0, 22.5, '#e2604a'), ('storage', 'B-01', 120.0, 22.5, '#e2604a'),
                                    ('power', 'POWER', 64.0, 23.0, '#e2604a'), ('oxygen', 'OXYGEN', 90.0, 33.5, '#2aa89c')):
        x, y = M.project(*room_pt(name, ang, r_in(name), z))
        M.draw_text(final, int(x - M.text_width(txt) / 2), int(y), txt, A.hex2rgb(colr), shadow=tuple(int(v) for v in WHITE[3]))
    x, y = M.project(*room_pt('power', 90.0, r_in('power') - 1.2, 27.0))
    M.draw_text(final, int(x - M.text_width('OFFLINE') / 2), int(y - 2), 'OFFLINE', A.hex2rgb('#ff5a4a'), shadow=(20, 16, 30))
    Image.fromarray(final).save(os.path.join(OUT, 'base_interior.png'))

    # --- game data
    meta = export_game_data(D, kind, foot, Xg, Yg)
    meta.update(name='base_interior', image='base_interior.png', size=[W, H], origin_px=[M.AX, M.AY])
    meta['rooms'] = {name: dict(label=rm['label'], center=[rm['X'], rm['Y']], radius=rm['R']) for name, rm in ROOMS.items()}
    meta['zoom'] = dict(max_view_px=[W, H], frames={})
    meta['door'] = export_door()
    meta['repair_machines'] = repair_machine_info(reactor_c, gen_c)
    meta['fx'] = dict(
        shafts=[dict(hull=[[round(float(x), 1), round(float(y), 1)] for x, y in s['hull']],
                     hole=[round(float(v), 1) for v in M.project(*s['hole'].mean(axis=0))]) for s in sh],
        leds=[dict(px=pxl(p), color='#ff5a4a', kind=k) for p, k in pfx['leds'] + ofx['leds']],
        core=pxl(pfx['core']),
        sparks=[pxl(p) for p in pfx['sparks'] + ofx['sparks']],
        vapor=[dict(px=pxl(p), dir=[round(float(v), 3) for v in A.nz(np.array(M.project(*(p + d))) - np.array(M.project(*p)))])
               for p, d in ofx['vapor']],
        circuit_board=board_info(pfx['pcb']),
        tanks=[[round(float(v), 1) for v in M.project(*(t + A.nz(gen_c - t) * 8.6 + np.array([0, 0, 17.0])))] for t in tanks],
    )
    with open(os.path.join(OUT, 'base_interior.json'), 'w') as fh:
        json.dump(meta, fh, indent=1)
    Image.fromarray(final).resize((W // 2, H // 2), Image.LANCZOS).save(os.path.join(OUT, 'preview_half.png'))
    print(f'interior done in {time.time() - t_start:.1f}s -> {OUT}')


def pxl(P):
    return [round(float(v), 1) for v in M.project(*P)]


def repair_machine_info(reactor_c, gen_c):
    """Gameplay anchors derived from the same model centres as the machine art."""
    return [dict(id=key, label=label,
                 world=[round(float(v), 2) for v in c[:2]],
                 stand_world=[round(float(v), 2) for v in (c + np.array([0, -30, 0]))[:2]],
                 progress_px=pxl(c + np.array([0, 0, 43])))
            for key, label, c in [('power', 'POWER GENERATOR', reactor_c),
                                  ('oxygen', 'O2 GENERATOR', gen_c)]]


def refresh_repair_metadata():
    path = os.path.join(OUT, 'base_interior.json')
    with open(path) as fh:
        meta = json.load(fh)
    # build() establishes these offsets before exporting projected positions.
    M.AX, M.AY = meta['origin_px']
    rs = np.random.default_rng(42)
    _, reactor_c, _ = power_props(rs)
    _, gen_c, _, _ = oxygen_props(rs)
    meta['repair_machines'] = repair_machine_info(reactor_c, gen_c)
    with open(path, 'w') as fh:
        json.dump(meta, fh, indent=1)
        fh.write('\n')
    print('Machine repair anchors refreshed; existing art preserved.')


def board_info(b):
    """Where the circuit board is on screen (to fix it, later): its corners, centre and empty socket."""
    hx, hz = b['half']
    corners = [pxl(b['center'] + b['R'] @ np.array([sx * hx, -0.3, sz * hz])) for sx, sz in ((-1, 1), (1, 1), (1, -1), (-1, -1))]
    return dict(center=pxl(b['center']), socket=pxl(b['socket']), corners=corners,
                world=[round(float(b['center'][0]), 2), round(float(b['center'][1]), 2)],
                note='The circuit board in the power room service cabinet. Not interactive yet.')


def export_game_data(D, kind, foot, Xg, Yg):
    depth = np.zeros((M.H, M.W, 4), np.uint8)
    dq = np.where(kind > 0, np.clip(D * M.DEPTH_SCALE, 0, 65534), 65535).astype(np.uint32)
    depth[..., 0], depth[..., 1] = dq >> 8, dq & 255
    depth[..., 3] = 255
    Image.fromarray(depth).save(os.path.join(OUT, 'base_interior_depth.png'))
    region = floor_region(Xg, Yg)
    walk = np.zeros(region.shape, bool)
    for i, (name, rm) in enumerate(ROOMS.items()):
        walk |= np.hypot(Xg - rm['X'], Yg - rm['Y']) < r_in(name) - 3.5
    for a, b in CORRIDORS:
        x0, x1, y = corridor_rect(a, b)
        walk |= (Xg > x0) & (Xg < x1) & (np.abs(Yg - y) < CORR_HALF - 3.0)
    walk &= ~ndi.binary_dilation(foot, iterations=1)
    hq = np.clip((0.0 + M.HEIGHT_OFFSET) * M.HEIGHT_SCALE, 0, 65535)
    grid = np.zeros((N, N, 4), np.uint8)
    grid[..., 0], grid[..., 1] = int(hq) >> 8, int(hq) & 255
    grid[..., 2] = np.where(walk, 255, 0)
    grid[..., 3] = 255
    Image.fromarray(grid.transpose(1, 0, 2).copy()).save(os.path.join(OUT, 'base_interior_walk.png'))
    st = ROOMS['storage']
    spawn = [st['X'], st['Y'] + r_in('storage') - 22.0]
    print(f'walkable {walk.mean() * 100:.1f}% of the grid')
    return dict(game=dict(depth_png='base_interior_depth.png', walk_png='base_interior_walk.png', depth_scale=M.DEPTH_SCALE,
                          height_offset=M.HEIGHT_OFFSET, height_scale=M.HEIGHT_SCALE, world_units_per_px=S, depth_to_px=KY,
                          px_per_unit=PX, character_scale=1.0 / PX, grid_size=N, spawn_world=spawn))


def export_door():
    """The airlock door's opening as sprite frames, and where the astronaut stands to use it."""
    frames = [door_parts(i / (M.DOOR_FRAMES - 1)) for i in range(M.DOOR_FRAMES)]
    box = M.sprite_box(frames, pad=3)
    strip = np.concatenate([M.sprite_rgba(M.render_sprite(fp, box)) for fp in frames], axis=1)
    Image.fromarray(strip).save(os.path.join(OUT, 'anim', 'door.png'))
    f = door_frame_pt()
    lamp = f + np.array([0, -1.4 * DOOR_K, (6.9 + 7.9) * DOOR_K])
    lx, ly = M.project(*lamp)
    return dict(file='anim/door.png', frames=M.DOOR_FRAMES, position=[box[0], box[1]], frame_size=[box[2], box[3]],
                sort_y=round(float(M.project(*f)[1]), 1), world=[round(float(f[0]), 2), round(float(f[1]), 2)],
                dir=[0.0, -1.0], lamp_px=[round(float(lx), 1), round(float(ly), 1)], height=round(14.8 * DOOR_K, 1))


if __name__ == '__main__':
    np.seterr(all='ignore')
    if '--repair-metadata-only' in sys.argv:
        refresh_repair_metadata()
    else:
        build()
