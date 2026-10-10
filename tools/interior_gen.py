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

Day and night: the light mask (_light.png) says how much of each pixel is its own light (LEDs,
  the emergency lines, the oxygen cell), the sun mask (_sun.png) how much is daylight coming in
  (shafts, sunlit patches, the windows' glow). The game keeps the first lit at night and takes the
  second away.

Writes assets/maps/base_interior/: base_interior.png, _depth.png, _walk.png, _light.png, _sun.png, .json, anim/,
and machines/: the power room's reactor and the oxygen generator on their own, as transparent sprites.
Also writes repaired_power/, repaired_oxygen/, repaired_both/: all four room views with
restored machines, matching depth/walk/light data, and no fault effects for repaired equipment.
machines.json retains three projected repair sites on each actual machine for reference.
CrackRepairUI uses the owner's exact supplied panel PNGs, unchanged under machines/reference/.
REPAIR_PANEL_DESIGN=reference (default) | equipment | detailed | simple retains earlier designs.
The reference mode exports the wall crop and damage samples read from the original pixels;
it never writes the owner-supplied PNGs. --repair-panels-only refreshes inspection metadata
without rendering the room variants (legacy designs regenerate their inspection images).
interior_props.json places six gatherable scraps using the existing generated prop sheets, and the
cargo box: a loose prop now (props/cargo_box*.png: whole, three cracks, burst open) that the tool
lifts and the astronaut stands on (top, half, yaw), with the ration packs it spills (props/ration*.png).
Storage's window band has three smashed panes, one on the far wall (hidden in the view you come in
by); window_cracks in each view's JSON says where to stand under each and where this view draws it.
The eighteen glass pickups are single thin shards with baked reflection sweeps (three variants,
animation.variant_frames/fps). windows/ holds scan patches and complete restoration states,
including the sun/light masks with sealed holes' shafts removed. window_repair_gen.py owns
the inspection assets. Storage's barrel cluster is omitted so the cargo box has a clear route.
--props-only refreshes loose-prop sprites, keeping placements and session IDs unchanged.
--repair-metadata-only refreshes machine interaction anchors without rendering the art.
--solar-input-only renders the small wall inlet repeaters and refreshes their four-view
anchors in every machine-repair variant. The panels occupy opposite diagonal walls;
only the one on a standing wall is drawn, so camera cutaways never leave floating lights.

Four views: like the overworld, the base is rendered from four sides (the camera turns in quarter
turns). Each view cuts away the walls nearest the camera. View 0 writes the usual files, view k
the same set with a _rk suffix; the walk grid belongs to the base, so there is one. The sun shafts
fall the same way in the world in every view; the furniture's key light stays put on screen.
"""
import hashlib
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
ROOMS = {   # dome: the base room outside it on the overworld (mars_map_gen BASE_ROOMS); the airlocks are in it
    'storage': dict(X=0.0, Y=OY, R=94.0, label='STORAGE', dome='command'),
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
HOLES = [('burst', 66.0), ('crescent', 114.0),    # storage window band (angle round the room, degrees)
         ('gash', -100.0)]                       # the third faces away from the door: turn the camera to find it
CARGO_AT = (52.0, 34.0)           # the cargo box, from storage's middle (a loose prop now: the tool lifts it)
CARGO_YAW = -0.25                 # how it is turned on the floor; its footprint turns with it
CARGO_HALF = np.array([11.5, 7.0, 7.2])
CARGO_RATIONS = 4                 # ration packs inside, spilled when it gives way

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
    'windowglass': ['#5aa8b4', '#86cfd2', '#b6ece6', '#e6fff8'],
    'glassedge': ['#b8b7cb', '#dad9e6', '#f0f0f6', '#ffffff'],
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


M.VIEW_C = np.array([0.0, OY + 5.0, 0.0])                # the views turn round the middle of the base


def view_th(th):
    """An angle round a room (in the base's frame) as the current view sees it."""
    return th - M.VIEW * math.pi / 2


def room_pt(name, ang_deg, r, z=0.0):
    rm = ROOMS[name]
    a = math.radians(ang_deg)
    return cam(rm['X'] + r * math.cos(a), rm['Y'] + r * math.sin(a), z)


def r_in(name):
    return ROOMS[name]['R'] - WALL_T / 2


# ================================================================== frame
def set_frame():
    cv = {n: M.to_view([rm['X'], rm['Y']]) for n, rm in ROOMS.items()}     # where this view sees the rooms
    xmax = max(abs(cv[n][0]) + rm['R'] for n, rm in ROOMS.items()) + WALL_T + 14
    ymax = max(cv[n][1] + rm['R'] for n, rm in ROOMS.items()) + WALL_T
    ymin = min(cv[n][1] - rm['R'] for n, rm in ROOMS.items()) - WALL_T - 10
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
    """A round wall: tall on the side away from the camera, cut low on the side nearest it, with
    openings. Built in the base's frame; th is an angle round the room in that frame."""

    def __init__(self, name, cuts, view=None):
        rm = ROOMS[name]
        self.c = np.array([rm['X'], rm['Y']])
        self.R = rm['R']
        self.cuts = cuts            # boxes (cx, cy, hx, hy, top) cut through the wall
        self.view = M.VIEW if view is None else view

    def local(self, P):
        return P

    def height(self, th):
        return WALL_LOW + (WALL_H - WALL_LOW) * M.smoothstep(-0.36, 0.04, np.sin(th - self.view * math.pi / 2))

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
        for side in (1, -1):
            h = corridor_wall_h(side)
            parts.append(P_('cwall', BoxWall((cx, y + side * (CORR_HALF + WALL_T / 2), h / 2), (hx, WALL_T / 2, h / 2)), 'white',
                            f'cwall_{b}_{side}'))
    return parts


def corridor_wall_h(side):
    """A corridor's wall on one side (+1 / -1 along the base's y): tall only if it is the far side
    in this view; when the corridor runs away from the camera both are cut low."""
    return CORR_H if M.vrot([0.0, float(side)])[1] > 0.5 else WALL_LOW


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


CARGO_CRACKS = [   # one for each pane the box is stood on to reach: where it starts, its plane, how far it runs
    (np.array([-4.5, -7.0, 7.2]), A.nz([1.0, 0.15, 0.0]), 7.5),       # over the top and down the front
    (np.array([11.5, 2.0, 7.2]), A.nz([0.1, 1.0, 0.25]), 8.0),        # over the top and down the right end
    (np.array([3.0, 7.0, 7.2]), A.nz([1.0, -0.3, 0.1]), 8.5),         # over the top and down the back
]


def decal_cargo_wall(part, P):
    """A wall of the cargo box: dark ribs across it, the coral band near its top (not on the lid)."""
    q = part.sdf.local(P)
    h = part.sdf.half
    out = np.full(len(P), OID['steel'])
    along = q[:, 0] if h[0] >= h[1] else q[:, 1]
    out[np.mod(along + 0.5, 2.6) < 0.7] = OID['cable']
    if h[2] > 2.0:
        out[np.abs(q[:, 2] - h[2] * 0.45) < 0.8] = OID['coral']
    return out


def decal_cargo(stage):
    """The cargo box after `stage` cracks: each a jagged split over the top and down one side,
    a dark gap with a bright torn edge, so the top shows every crack from every view."""
    def decal(part, P):
        out = decal_container(part, P)
        q = part.sdf.local(P)
        for i, (c, n, length) in enumerate(CARGO_CRACKS[:stage]):
            s = np.linalg.norm(q - c, axis=1)
            d = (q - c) @ n + 0.45 * np.sin(s * 1.7 + i) + 0.2 * np.sin(s * 4.3 + 2 * i)
            w = 0.35 + 0.4 * np.clip(1 - s / length, 0, 1)
            near = s < length
            out[near & (np.abs(d) > w) & (np.abs(d) < w + 0.45)] = OID['white']
            out[near & (np.abs(d) < w)] = OID['dark']
        return out
    return decal


def decal_ration(part, P):
    """A ration pack: tan foil, crimped steel seals at the ends, a coral label on top."""
    q = part.sdf.local(P)
    h = part.sdf.half
    out = np.full(len(P), OID['sack'])
    out[np.abs(q[:, 0]) > h[0] - 0.45] = OID['steel']
    out[(np.abs(q[:, 0]) < h[0] * 0.38) & (q[:, 2] > 0)] = OID['coral']
    return out


def ration(k):
    """A ration pack (an MRE) lying on the floor, three ways."""
    R = A.rz([0.4, -0.7, 1.3][k]) @ A.rx([0.0, 0.18, -0.12][k])
    return [P_('pouch', A.RoundBox(np.array([0.0, 0.0, 0.75]), (2.3, 1.6, 0.55), 0.45, R), 'sack', 'ration', decal_ration)]


def cargo_box(stage):
    """The storage room's cargo box, standing at the origin: whole (0), cracked once per pane it
    has been stood on to reach (1-3), or crushed flat (4) - its walls burst out round the tray,
    the lid dropped onto it, ration packs left in it. Flat, so whoever is in it stands on top."""
    R = A.rz(CARGO_YAW)
    h = CARGO_HALF
    if stage < 4:
        return [P_('container', A.RoundBox(np.array([0.0, 0.0, h[2]]), h, 0.8, R), 'steel', 'cargo', decal_cargo(stage))]

    def piece(c, half, rot):
        return A.RoundBox(R @ np.asarray(c, float), half, 0.4, R @ rot)

    def fallen(hinge, c, half, rot):                     # a wall turned about its bottom edge
        hinge = np.asarray(hinge, float)
        return piece(hinge + rot @ (np.asarray(c, float) - hinge), half, rot)
    return [P_('tray', piece([0, 0, 0.9], (h[0], h[1], 0.9), np.eye(3)), 'steel', 'cargo', decal_cargo_wall),
            P_('wall', fallen([0, -7.4, 0.4], [0, -7.4, 7.0], (h[0] - 0.4, 0.5, 6.6), A.rx(1.42)), 'steel', 'cargo', decal_cargo_wall),
            P_('wall', fallen([0, 7.4, 0.4], [0, 7.4, 7.0], (h[0] - 0.3, 0.5, 6.6), A.rx(-1.36)), 'steel', 'cargo', decal_cargo_wall),
            P_('wall', fallen([-11.9, 0, 0.4], [-11.9, 0, 6.4], (0.5, h[1] - 0.6, 6.0), A.ry(-1.45)), 'steel', 'cargo', decal_cargo_wall),
            P_('wall', fallen([11.9, 0, 0.4], [11.9, 0, 6.4], (0.5, h[1] - 0.6, 6.0), A.ry(1.18)), 'steel', 'cargo', decal_cargo_wall),
            P_('lid', piece([-1.6, 1.0, 2.4], (h[0] - 1.6, h[1] - 1.2, 0.5), A.rz(0.2) @ A.ry(0.1)), 'steel', 'cargo', decal_cargo_wall),
            P_('pouch', piece([7.4, -3.6, 2.2], (2.3, 1.6, 0.55), A.rz(0.5) @ A.rx(0.2)), 'sack', 'cargo', decal_ration),
            P_('pouch', piece([-4.0, -11.5, 1.6], (2.3, 1.6, 0.55), A.rz(-0.8)), 'sack', 'cargo', decal_ration)]


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
    # (the cargo box at CARGO_AT is a loose prop the tool can lift: export_cargo_box)
    # Keep this route clear for carrying the cargo box between the three window repairs.
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
    rg = np.random.default_rng(260)                      # and under the far pane (its own dice: the rest stays put)
    for k in range(12):
        p = room_pt('storage', HOLES[2][1] + rg.uniform(-14, 14), rg.uniform(64, 84), 0.25)
        sz = rg.uniform(0.6, 1.6)
        parts.append(P_('shard', A.RoundBox(p, (sz, sz * 0.6, 0.18), 0.1, A.rz(rg.uniform(0, TAU))),
                        'tglass' if k % 3 else 'shard', f'gshard_far{k}'))
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


def window_material(x, y, bay, xs, ys):
    """The window band, shared by the world, restored patches and glass inspection."""
    a = (WIN[1] - WIN[0]) / 2.5
    qi, ri, _, _, edge = M.hex_cell(x, y - a / 2, a)
    frame = (edge < 0.32) | (y < 0.45) | (y > WIN[1] - WIN[0] - 0.45)
    k = np.clip(np.floor(y / (WIN[1] - WIN[0]) * 3.2 + bay * 0.8 + 0.4 * M._h(qi, ri, 3)), 0, 3).astype(int)
    col = SKYWIN[k].copy()
    col[frame] = WHITE[4]
    sw = np.mod(xs * 1.0 + ys * 1.5, 70.0) < 3.5
    col[sw & ~frame] = col[sw & ~frame] * 0.6 + 255 * 0.4
    return col, frame


def shade_walls(img, D, gid, wall_gids, bay_img, closed=frozenset()):
    t0 = time.time()
    ys, xs = np.nonzero(np.isin(gid, wall_gids))
    O = view_rays(ys, xs)
    t = (D[ys, xs] - O[:, 1]) / M.F[1]
    P = M.to_canon(O + t[:, None] * M.F)                  # the wall points, in the base's frame
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
    side = np.where(P[:, 1] > OY + 5.0, 1, -1)
    for sd in (1, -1):
        face[cor & (side == sd) & (z > corridor_wall_h(sd) - 0.8)] = 2
    nrm[cor] = np.stack([np.zeros(len(P)), -side, np.zeros(len(P))], -1)[cor]
    nrm = M.vrot(nrm)                                     # lit and seen in the view
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
    win = inner & (z > WIN[0]) & (z < WIN[1]) & ~(cor & (corridor_wall_h(1) < WIN[1]) & (corridor_wall_h(-1) < WIN[1]))
    arc = np.where(cor, P[:, 0], arc)
    glow_mask = np.zeros(len(P), np.float32)
    hole_mask = np.zeros(len(P), bool)
    if win.any():
        a = (WIN[1] - WIN[0]) / 2.5
        x = arc[win]
        y = z[win] - WIN[0]
        cw, frame = window_material(x, y, bay[win], xs[win], ys[win])
        col[win] = cw
        glow_mask[np.nonzero(win)[0][~frame]] = 0.55
        # storage: the three smashed panes, bright with daylight
        si = names.index('storage')
        for kind_, ang in HOLES:
            if kind_ in closed:
                continue
            rs = np.random.default_rng(int(ang) % 360)
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
    Rd = M.crot(np.array([M.F[0], M.F[1], -M.F[2]]))     # the view's reflected ray, in the base's frame
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
    if shafts_floor is not None:
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
    else:
        q = np.zeros(n, np.float32)
    img[ys, xs] = np.clip(col, 0, 255).astype(np.uint8)
    g = np.zeros(D.shape, np.float32)
    g[ys, xs] = np.clip(glow, 0, 1)
    sun = np.zeros(D.shape, np.float32)
    sun[ys, xs] = q
    print(f'floor shaded in {time.time() - t0:.1f}s')
    return g, sun


# ================================================================== the light through the holes
def sunlit(ang):
    """Does the sun shine in through a pane at this angle round storage? Only those facing it."""
    a = math.radians(ang)
    return math.cos(a) * -LIGHT_IN[0] + math.sin(a) * -LIGHT_IN[1] > 0.0


def hole_world_polys(closed=frozenset()):
    """Each smashed pane the sun shines through, as a polygon in the world."""
    a = (WIN[1] - WIN[0]) / 2.5
    Ri = r_in('storage')
    st = ROOMS['storage']
    out = []
    for kind_, ang in HOLES:
        if kind_ in closed or not sunlit(ang):
            continue
        rs = np.random.default_rng(int(ang) % 360)
        poly, _ = M.hole_shape(kind_, a * 1.15, rs)
        pts = []
        for lx, ly in poly:
            th = math.radians(ang) + lx / Ri
            z = WIN[0] + (WIN[1] - WIN[0]) / 2 + ly
            pts.append(cam(st['X'] + Ri * math.cos(th), st['Y'] + Ri * math.sin(th), z))
        out.append((kind_, np.array(pts)))
    return out


def shaft_geometry(closed=frozenset()):
    """Light shafts: the hole polygons, where their light lands on the floor, and the screen polygon
    each shaft covers (for the haze and the dust)."""
    out = []
    for id_, poly in hole_world_polys(closed):
        t = poly[:, 2] / -LIGHT_IN[2]
        land = poly + t[:, None] * LIGHT_IN
        scr = np.array([M.project(*M.to_view(p)) for p in np.vstack([poly, land])])
        from scipy.spatial import ConvexHull
        hull = scr[ConvexHull(scr).vertices]
        out.append(dict(pane=id_, hole=poly, floor=land[:, :2], hull=hull))
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
def build(fixed=frozenset()):
    """The base's furniture once (so every view shows the same things), then each view of it."""
    t_start = time.time()
    os.makedirs(os.path.join(OUT, 'anim'), exist_ok=True)
    M.SUN = SUN_IN
    rs = np.random.default_rng(77)
    s_parts = storage_props(rs)
    glass_positions = [p.sdf.c[:2].tolist() for p in s_parts if p.group.startswith('gshard')]
    # Keep the original random calls: furniture stays exactly where it was in every view.
    s_parts = [p for p in s_parts if not p.group.startswith('gshard')]
    p_parts, reactor_c, pfx = power_props(rs)
    o_parts, gen_c, tanks, ofx = oxygen_props(rs)
    # Build the original models first so random environment detail stays identical.
    if 'power' in fixed:
        p_parts = restore_power(p_parts, reactor_c)
        pfx['sparks'], pfx['leds'] = [], []
    if 'oxygen' in fixed:
        o_parts = restore_oxygen(o_parts, gen_c, tanks)
        ofx['sparks'], ofx['vapor'] = [], []
        ofx['leds'] = [(p, 'steady') for p, _ in ofx['leds']]
    M.VIEW, M.SFX = 0, ''
    set_frame()
    export_machines(p_parts + o_parts, dict(power_generator=reactor_c, oxygen_generator=gen_c))
    if not fixed:
        export_repair_panels()

    # footprints for soft contact shadows on the floor and for the walk grid (the base's frame)
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
    furniture = dict(parts=s_parts + p_parts + o_parts, reactor_c=reactor_c, gen_c=gen_c, pfx=pfx, ofx=ofx, tanks=tanks,
                     foot=foot, ao_grid=ao_grid, Xg=Xg, Yg=Yg, fixed=fixed)
    for k in M.VIEWS:
        M.VIEW, M.SFX = k, M.view_sfx(k)
        render_view(k, furniture)
    M.VIEW, M.SFX = 0, ''
    if not fixed:
        export_loose_scrap(reactor_c, gen_c, glass_positions)
    print(f'interior done in {time.time() - t_start:.1f}s -> {OUT}')


def label_visible(ang):
    """Lettering on a room's wall shows only where this view leaves the wall standing tall."""
    return math.sin(view_th(math.radians(ang))) > 0.3


def shade_room(base, D, kind, gid, wall_gids, fl, region, Xf, Yf, bay_img, fur, closed=frozenset()):
    """Shade the same geometry with selected panes sealed: no hole, shaft or hole bloom remains.
    Reuse this pass for every restoration state so overlapping beams and masks are exact."""
    img = base.copy()
    H, W = D.shape
    jj, ii = np.mgrid[0:H, 0:W]
    sh = shaft_geometry(closed)
    ys, xs = np.nonzero(fl & (gid == 0))
    pu, pv = M.to_grid(Xf[ys, xs], Yf[ys, xs])
    prop_ao = np.clip(M.sample(fur['ao_grid'], pu, pv) * 1.3, 0, 1)
    fglow, sun = shade_floor(img, D, kind, region[ys, xs], Xf[ys, xs], Yf[ys, xs], ys, xs, bay_img[ys, xs], prop_ao,
                             [s['floor'] for s in sh])
    wglow, _, _ = shade_walls(img, D, gid, wall_gids, bay_img, closed)
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
        sun[m] = np.maximum(sun[m], lvl[m])
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
    # what is its own light (kept at night) and what is daylight (taken away at night)
    wlit = np.where(np.abs(wglow - 0.6) < 1e-3, wglow, 0.0)            # the emergency line
    wsun = np.where(np.abs(wglow - 0.6) < 1e-3, 0.0, wglow)            # the windows and the holes
    own = np.maximum(fglow, wlit)
    light = np.maximum.reduce([M.EMIT.astype(np.float32) / 255, own,
                               np.clip(ndi.gaussian_filter(own, 2.0) * 2.2, 0, 0.8),
                               np.clip(ndi.gaussian_filter(em, 3.0) * 2.5, 0, 0.85)])
    sun = np.maximum.reduce([sun, wsun, np.clip(ndi.gaussian_filter(wsun, 4.0) * 1.6, 0, 0.7)])
    # --- the void round the cutaway, and its silhouette
    filled = kind > 0
    yy = np.arange(H, dtype=np.float32)[:, None, None] / H
    back = VOID_TOP * (1 - yy) + VOID_BOT * yy
    final = np.where(filled[..., None], np.clip(out, 0, 255), back).astype(np.uint8)
    pad = np.pad(filled, 1)
    ring = (pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]) & ~filled
    final[ring] = M.OUTLINE
    light[~filled] = 1.0                                  # the void round the cutaway never changes
    light[ring] = 0.0
    sun[~filled | ring] = 0.0
    for name, txt, ang, z, colr in (('storage', 'STORAGE', 64.0, 22.5, '#e2604a'), ('storage', 'B-01', 120.0, 22.5, '#e2604a'),
                                    ('power', 'POWER', 64.0, 23.0, '#e2604a'), ('oxygen', 'OXYGEN', 90.0, 33.5, '#2aa89c')):
        if not label_visible(ang):
            continue
        x, y = M.project(*M.to_view(room_pt(name, ang, r_in(name), z)))
        M.draw_text(final, int(x - M.text_width(txt) / 2), int(y), txt, A.hex2rgb(colr), shadow=tuple(int(v) for v in WHITE[3]))
    if label_visible(90.0):
        x, y = M.project(*M.to_view(room_pt('power', 90.0, r_in('power') - 1.2, 27.0)))
        status = 'ONLINE' if 'power' in fur['fixed'] else 'OFFLINE'
        M.draw_text(final, int(x - M.text_width(status) / 2), int(y - 2), status,
                    A.hex2rgb('#7fe6cf' if 'power' in fur['fixed'] else '#ff5a4a'), shadow=(20, 16, 30))
    return final, sun, light, sh



def render_view(k, fur):
    t_start = time.time()
    sfx = M.SFX
    set_frame()
    W, H = M.W, M.H
    img = np.zeros((H, W, 3), np.uint8)
    D = np.full((H, W), np.inf, np.float32)
    kind = np.zeros((H, W), np.uint8)
    gid = np.zeros((H, W), np.int32)
    jj, ii = np.mgrid[0:H, 0:W]
    bay_img = M.BAYER[jj % 4, ii % 4]
    M.EMIT = np.zeros((H, W), np.uint8)                  # props drawn with a light ramp mark it

    # --- the floor (plane z = 0)
    O = view_rays(jj.ravel(), ii.ravel())
    t = -O[:, 2] / M.F[2]
    P = O + t[:, None] * M.F
    Pc = M.to_canon(P)                                    # the floor's patterns belong to the base
    region = floor_region(Pc[:, 0], Pc[:, 1]).reshape(H, W)
    fl = region > 0
    D[fl] = P[:, 1].reshape(H, W)[fl]
    kind[fl] = 1
    Xf, Yf = Pc[:, 0].reshape(H, W), Pc[:, 1].reshape(H, W)
    del O, t, P, Pc

    # --- walls (cut away on the side nearest the camera), furniture and the door, turned into the view
    t0 = time.time()
    gb = 1
    wparts = M.turned(wall_parts())
    gw0 = gb
    gb = M.render_groups(wparts, img, D, kind, gid, gb)
    wall_gids = np.arange(gw0, gb)
    gb = M.render_groups(M.turned(fur['parts']), img, D, kind, gid, gb)
    gb = M.render_groups(M.turned(door_parts(0.0)), img, D, kind, gid, gb)
    print(f'view {M.VIEW}: walls and furniture in {time.time() - t0:.1f}s')

    # Re-shade only colours and light, retaining the one shared geometry/depth/walk render.
    base = img.copy()
    states = {}
    for mask in range(8):
        closed = {id_ for i, (id_, _) in enumerate(HOLES) if mask & (1 << i)}
        states[mask] = shade_room(base, D, kind, gid, wall_gids, fl, region, Xf, Yf, bay_img, fur, closed)
    final, sun, light, sh = states[0]
    Image.fromarray(final).save(os.path.join(OUT, f'base_interior{sfx}.png'))
    for field, values in [('light', light), ('sun', sun)]:
        Image.fromarray(np.round(np.clip(values, 0, 1) * 255).astype(np.uint8)).save(
            os.path.join(OUT, f'base_interior_{field}{sfx}.png'))
    M.EMIT = None

    # --- game data
    reactor_c, gen_c, pfx, ofx, tanks = fur['reactor_c'], fur['gen_c'], fur['pfx'], fur['ofx'], fur['tanks']
    meta = export_game_data(D, kind, fur['foot'], fur['Xg'], fur['Yg'], world=(M.VIEW == 0))
    meta['game'].update(light_png=f'base_interior_light{sfx}.png', sun_png=f'base_interior_sun{sfx}.png', heading=M.VIEW,
                        view_center=[float(M.VIEW_C[0]), float(M.VIEW_C[1])])
    meta.update(name='base_interior', image=f'base_interior{sfx}.png', size=[W, H], origin_px=[M.AX, M.AY], view=M.VIEW,
                views=[f'base_interior{M.view_sfx(i)}.json' for i in range(4)])
    meta['rooms'] = {name: dict(label=rm['label'], center=[rm['X'], rm['Y']], radius=rm['R'],
                                **({'dome': rm['dome']} if 'dome' in rm else {})) for name, rm in ROOMS.items()}
    meta['zoom'] = dict(max_view_px=[W, H], frames={})
    meta['door'] = export_door()
    meta['repair_machines'] = repair_machine_info(reactor_c, gen_c)
    meta['solar_input'] = solar_input_info()
    meta['repair_variants'] = {str(mask): folder + '/base_interior.json' for mask, folder in
                               [(1, 'repaired_power'), (2, 'repaired_oxygen'), (3, 'repaired_both')]}
    meta['fixed_machines'] = sorted(fur['fixed'])
    meta['window_cracks'] = window_crack_info()
    patches = export_window_patches(D, gid, wall_gids, states)
    meta['window_restorations'] = export_window_restorations(states)
    for pane in meta['window_cracks']:
        pane['patch'] = patches.get(pane['id'], {})
    meta['fx'] = dict(
        shafts=[dict(pane=s['pane'], hull=[[round(float(x), 1), round(float(y), 1)] for x, y in s['hull']],
                     hole=pxl(s['hole'].mean(axis=0))) for s in sh],
        leds=[dict(px=pxl(p), color='#7fe6cf' if k == 'steady' else '#ff5a4a', kind=k) for p, k in pfx['leds'] + ofx['leds']],
        core=[0, 0] if 'power' in fur['fixed'] else pxl(pfx['core']),
        sparks=[pxl(p) for p in pfx['sparks'] + ofx['sparks']],
        vapor=[dict(px=pxl(p), dir=[round(float(v), 3) for v in A.nz(np.array(M.project(*(p + d))) - np.array(M.project(*p)))])
               for p, d in ofx['vapor']],
        circuit_board=board_info(pfx['pcb']),
        tanks=[pxl(t + A.nz(gen_c - t) * 8.6 + np.array([0, 0, 17.0])) for t in tanks],
    )
    if 'power' in fur['fixed']:
        del meta['fx']['circuit_board']
    with open(os.path.join(OUT, f'base_interior{sfx}.json'), 'w') as fh:
        json.dump(meta, fh, indent=1)
    # Replace previews atomically: an interrupted write must not corrupt the prior preview.
    preview = os.path.join(OUT, f'preview_half{sfx}.png')
    Image.fromarray(final).resize((W // 2, H // 2), Image.LANCZOS).save(preview + '.tmp', format='PNG')
    os.replace(preview + '.tmp', preview)
    print(f'view {M.VIEW} rendered in {time.time() - t_start:.1f}s')


def pxl(P):
    """A point in the base's frame, in the current view's map pixels."""
    return [round(float(v), 1) for v in M.project(*M.to_view(P))]


def repair_machine_info(reactor_c, gen_c):
    """Gameplay anchors derived from the same model centres as the machine art."""
    return [dict(id=key, label=label,
                 world=[round(float(v), 2) for v in c[:2]],
                 stand_world=[round(float(v), 2) for v in (c + np.array([0, -30, 0]))[:2]],
                 progress_px=pxl(c + np.array([0, 0, 43])))
            for key, label, c in [('power', 'POWER GENERATOR', reactor_c),
                                  ('oxygen', 'O2 GENERATOR', gen_c)]]


def refresh_repair_metadata():
    rs = np.random.default_rng(42)
    _, reactor_c, _ = power_props(rs)
    _, gen_c, _, _ = oxygen_props(rs)
    for k in range(4):                                    # every view's data that exists
        path = os.path.join(OUT, f'base_interior{M.view_sfx(k)}.json')
        if not os.path.exists(path):
            continue
        with open(path) as fh:
            meta = json.load(fh)
        # build() establishes these offsets before exporting projected positions.
        M.AX, M.AY = meta['origin_px']
        M.VIEW = k
        meta['repair_machines'] = repair_machine_info(reactor_c, gen_c)
        with open(path, 'w') as fh:
            json.dump(meta, fh, indent=1)
            fh.write('\n')
    M.VIEW = 0
    print('Machine repair anchors refreshed; existing art preserved.')


def solar_input_info():
    """A physical inlet repeater on the standing diagonal wall, clear of the reactor."""
    angle = 45.0 if label_visible(45.0) else 225.0
    center = room_pt('power', angle, r_in('power') - 1.0, 21.0)
    return dict(anchor=pxl(center), world=center.tolist(), panel_id='ne' if angle == 45 else 'sw',
                housing=f'solar_input/housing{M.view_sfx(M.VIEW)}.png',
                lights=f'solar_input/lights{M.view_sfx(M.VIEW)}.png')


def export_solar_input():
    """SDF housing plus eight three-channel lens states, shared by all repair variants."""
    root = os.path.join(M.ROOT, 'assets', 'maps', 'base_interior')
    folder = os.path.join(root, 'solar_input')
    os.makedirs(folder, exist_ok=True)
    for k in range(4):
        path = os.path.join(root, f'base_interior{M.view_sfx(k)}.json')
        with open(path) as stream:
            meta = json.load(stream)
        M.VIEW = k
        M.AX, M.AY = meta['origin_px']
        info = solar_input_info()
        c = np.array(info['world'])
        angle = math.radians(45 if info['panel_id'] == 'ne' else 225)
        R = A.rz(angle - math.pi / 2)
        normal = np.array([math.cos(angle), math.sin(angle), 0])
        parts = [P_('inletframe', A.RoundBox(c, [9.3, .6, 4], .45, R), 'steel', 'inlet'),
                 P_('inletface', A.RoundBox(c - normal * .7, [8.5, .35, 3.25], .25, R), 'darkwin', 'inlet'),
                 P_('inletstripe', A.RoundBox(c + [0, 0, 3.5] - normal * .8, [8, .35, .35], .1, R), 'teal', 'inlet')]
        lamps = []
        for x, ramp in [(-5, 'mustard'), (0, 'teal'), (5, 'coral')]:
            parts.append(P_('lensrim', A.Torus(c - normal * 1.0 + R @ np.array([x, 0, 0]), 1.9, .35,
                                              M.yaw_to(-normal) @ A.ry(math.pi / 2)), ramp, 'inlet'))
        for state in range(8):
            lamps.append([P_('lens', A.Disc(c - normal * 1.2 + R @ np.array([x, 0, 0]), 1.75, .35, .25,
                                           M.yaw_to(-normal)), ramp if state & (1 << group) else 'darkwin', f'lens{group}')
                          for group, (x, ramp) in enumerate([(-5, 'mustard'), (0, 'teal'), (5, 'coral')])])
        parts = M.turned(parts)
        lamps = [M.turned(frame) for frame in lamps]
        box = M.sprite_box([parts] + lamps, pad=2)
        Image.fromarray(M.sprite_rgba(M.render_sprite(parts, box))).save(os.path.join(root, info['housing']))
        strip = np.concatenate([M.sprite_rgba(M.render_sprite(frame, box)) for frame in lamps], axis=1)
        Image.fromarray(strip).save(os.path.join(root, info['lights']))
        info.update(position=list(box[:2]), size=list(box[2:]), frames=8)
        for variant in ['', 'repaired_power', 'repaired_oxygen', 'repaired_both']:
            target = os.path.join(root, variant, f'base_interior{M.view_sfx(k)}.json')
            with open(target) as stream:
                data = json.load(stream)
            data['solar_input'] = info
            with open(target, 'w') as stream:
                json.dump(data, stream, indent=1)
                stream.write('\n')
    M.VIEW = 0
    print('Solar wall inlet: three lenses, four views, all repair variants.')


def board_info(b):
    """Where the circuit board is on screen (to fix it, later): its corners, centre and empty socket."""
    hx, hz = b['half']
    corners = [pxl(b['center'] + b['R'] @ np.array([sx * hx, -0.3, sz * hz])) for sx, sz in ((-1, 1), (1, 1), (1, -1), (-1, -1))]
    return dict(center=pxl(b['center']), socket=pxl(b['socket']), corners=corners,
                world=[round(float(b['center'][0]), 2), round(float(b['center'][1]), 2)],
                note='The circuit board in the power room service cabinet. Not interactive yet.')


def export_game_data(D, kind, foot, Xg, Yg, world=True):
    """The view's depth map, and (view 0, world=True) the base's walk grid."""
    depth = np.zeros((M.H, M.W, 4), np.uint8)
    dq = np.where(kind > 0, np.clip(D * M.DEPTH_SCALE, 0, 65534), 65535).astype(np.uint32)
    depth[..., 0], depth[..., 1] = dq >> 8, dq & 255
    depth[..., 3] = 255
    Image.fromarray(depth).save(os.path.join(OUT, f'base_interior_depth{M.SFX}.png'))
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
    if world:
        Image.fromarray(grid.transpose(1, 0, 2).copy()).save(os.path.join(OUT, 'base_interior_walk.png'))
    st = ROOMS['storage']
    spawn = [st['X'], st['Y'] + r_in('storage') - 22.0]
    print(f'walkable {walk.mean() * 100:.1f}% of the grid')
    return dict(game=dict(depth_png=f'base_interior_depth{M.SFX}.png', walk_png='base_interior_walk.png', depth_scale=M.DEPTH_SCALE,
                          height_offset=M.HEIGHT_OFFSET, height_scale=M.HEIGHT_SCALE, world_units_per_px=S, depth_to_px=KY,
                          px_per_unit=PX, character_scale=1.0 / PX, grid_size=N, spawn_world=spawn))


MACHINES = {   # name: what it is, which part groups belong to it
    'power_generator': ('The power room reactor, smashed open: gash showing the dead core, fallen coil, '
                        'cap knocked askew, wires spilling out.',
                        lambda g: g in ('reactor', 'coil7', 'coil24', 'coilfallen', 'cap') or g.startswith(('wireg', 'wiret'))),
    'oxygen_generator': ('The oxygen generator, broken down: smashed turbine chamber, bent fan, cap askew, '
                         'blown-off panel and spilled wires, cracked cell, fallen coolant cylinder.',
                         lambda g: g in ('gen', 'genpanel', 'fins', 'chamber', 'fan', 'o2cap', 'cool0', 'cool1', 'o2ctl')
                         or g.startswith(('o2wire', 'cell'))),
}


def export_machines(parts, feet):
    """The two machines on their own, as transparent sprites: the very parts the room is rendered
    from, under the same light. machines.json gives each one's size and anchor (the pixel where
    the middle of its base stands on the floor). preview/ holds 4x copies for looking at."""
    out = os.path.join(OUT, 'machines')
    os.makedirs(os.path.join(out, 'preview'), exist_ok=True)
    info = {}
    for name, (what, pick) in MACHINES.items():
        ps = [p for p in parts if pick(p.group)]
        box = M.sprite_box([ps], pad=3)
        rgba = M.sprite_rgba(M.render_sprite(ps, box))
        ys, xs = np.nonzero(rgba[..., 3])
        y0, y1, x0, x1 = ys.min() - 1, ys.max() + 2, xs.min() - 1, xs.max() + 2      # trim to the drawing
        rgba = rgba[y0:y1, x0:x1]
        Image.fromarray(rgba).save(os.path.join(out, f'{name}.png'))
        h, w = rgba.shape[:2]
        Image.fromarray(rgba).resize((w * 4, h * 4), Image.NEAREST).save(os.path.join(out, 'preview', f'{name}_x4.png'))
        ax, ay = M.project(*feet[name])
        info[name] = dict(file=f'machines/{name}.png', size=[int(w), int(h)],
                          anchor=[round(float(ax - box[0] - x0), 1), round(float(ay - box[1] - y0), 1)], note=what)
        # Sites are authored in the machine model's world frame, never in UI/map pixels.
        offsets = ([[-3, -8, 15.5], [4, -7.5, 21], [1, -5, 30.8]] if name == 'power_generator'
                   else [[-6, -8.8, 8.6], [2, -8.4, 13], [-1.8, -3, 32.8]])
        info[name]['repair_sites'] = [[round(float(v), 1) for v in
                                      np.array(M.project(*(feet[name] + offset))) - [box[0] + x0, box[1] + y0]]
                                     for offset in np.array(offsets)]
        print(f'machine: {name} {w}x{h} px')
    with open(os.path.join(out, 'machines.json'), 'w') as fh:
        json.dump(info, fh, indent=1)


def restore_power(parts, c):
    """Reassemble the approved reactor: sealed housing, three mounted coils and a level cap."""
    pick = MACHINES['power_generator'][1]
    out = [p for p in parts if not pick(p.group)]
    out += [P_('plinth', A.Disc(c + [0, 0, 1.2], 15, 1.2, .5, M.UPAX), 'steel', 'reactor'),
            P_('housing', A.Disc(c + [0, 0, 15], 9.5, 13, 2, M.UPAX), 'white', 'reactor', decal_reactor),
            P_('cap', A.Ellipsoid(c + [0, 0, 30], (9.6, 9.6, 3)), 'white', 'cap'),
            P_('capring', A.Torus(c + [0, 0, 29.6], 9.4, .8), 'coral', 'cap'),
            P_('status', A.Sphere(c + [0, -9.5, 19], .7), 'ledcyan', 'reactor')]
    for z in (7, 15.5, 24):
        out.append(P_('coil', A.Torus(c + [0, 0, z], 10.6, 1.3), 'mustard', 'coil7'))
    return out


def export_repair_panels():
    """Use the owner's original panel images; retain generated walls as legacy versions.
    Read-only reference images supply the crop and exact hole-placement geometry."""
    out = os.path.join(OUT, 'machines')
    os.makedirs(os.path.join(out, 'preview'), exist_ok=True)
    path = os.path.join(out, 'machines.json')
    with open(path) as fh:
        info = json.load(fh)
    width, height = 336, 117
    design = os.environ.get('REPAIR_PANEL_DESIGN', 'reference')
    if design == 'reference':
        source_rect = [43, 99, 642, 219]
        for machine in ('power', 'oxygen'):
            file = f'machines/reference/{machine}.png'
            source_path = os.path.join(OUT, file)
            with open(source_path, 'rb') as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
            with Image.open(source_path) as source:
                x, y, w, h = source_rect
                pixels = np.asarray(source.convert('RGB'))[y:y+h, x:x+w]
            void = (pixels[..., 0] < 20) & (pixels[..., 1] < 18) & (pixels[..., 2] < 30)
            labels, count = ndi.label(void)
            components = sorted(range(1, count + 1), key=lambda k: np.count_nonzero(labels == k), reverse=True)[:3]
            if len(components) != 3 or any(np.count_nonzero(labels == k) < 1000 for k in components):
                raise ValueError(f'{file}: expected three original holes')
            components.sort(key=lambda k: np.where(labels == k)[1].mean())
            sites, samples = [], []
            dark = (pixels[..., 0] <= 36) & (pixels[..., 1] <= 26) & (pixels[..., 2] <= 46)
            for k in components:
                ys, xs = np.where(labels == k)
                site = np.round([(xs.mean() + .5) * width / w, (ys.mean() + .5) * height / h]).astype(int)
                # Include the broken rim and short dark fracture branches around each aperture.
                damage = (labels == k) | (ndi.binary_dilation(labels == k, iterations=10) & dark)
                ys, xs = np.where(damage)
                points = np.unique(np.round(np.column_stack(((xs + .5) * width / w, (ys + .5) * height / h)), 0), axis=0)
                sites.append(site.tolist())
                samples.append((points - site).astype(int).tolist())
            info[machine + '_generator']['repair_panel'] = dict(file=file, size=[width, height],
                source_rect=source_rect, sites=sites, damage_samples=samples, baked_damage=True,
                view='flat', design=design, sha256=digest,
                note='Owner-supplied original PNG, unchanged. Display only its wall region; holes are already in the image.')
        with open(path, 'w') as fh:
            json.dump(info, fh, indent=1)
        print('Original machine panel crops and damage metadata exported; source PNGs unchanged.')
        return
    R = np.column_stack((M.CR, M.F, M.CU))
    c = np.array([0., 0., 60.])
    half = np.array([width * S / 2 - .5, .8, height * S / 2 - .5])
    cx, cy = M.project(*c)
    box = (round(cx - width / 2), round(cy - height / 2), width, height)
    for machine, accent in [('power', 'coral'), ('oxygen', 'teal')]:
        def decal(part, P, machine=machine, accent=accent):
            q = part.sdf.local(P)
            x, y = q[:, 0] / S + width / 2, height / 2 - q[:, 2] / S
            if design == 'equipment':
                material = np.full(len(P), OID['steel'])
                if machine == 'power':
                    material[(x > 137) & (x < 207) & (y > 50)] = OID['cable']
                    material[(x > 257) & (y > 42)] = OID['dark']
                    seams = [(136, 6, height - 6), (208, 6, height - 6), (258, 42, height - 6)]
                else:
                    material[(x > 69) & (x < 116)] = OID['white']
                    material[(x > 116) & (x < 214) & (y < 55)] = OID['tglass']
                    material[(x > 214) & (x < 258)] = OID['tglass']
                    material[(x > 258) & (y > 44)] = OID['tglass']
                    seams = [(69, 6, height - 6), (116, 6, height - 6), (214, 6, height - 6), (258, 6, height - 6)]
                    material[(x > 116) & (x < 214) & (np.abs(y - 55) < .7)] = OID['cable']
                    material[(x > 116) & (x < 214) & (np.abs(y - 56.3) < .5)] = OID['white']
                    material[(x > 258) & (np.abs(y - 44) < .7)] = OID['cable']
                for column, start, end in seams:
                    length = (y > start) & (y < end)
                    material[length & (np.abs(x - column) < .7)] = OID['cable']
                    material[length & (np.abs(x - column - 1.4) < .5)] = OID['white']
                # A restrained shared frame and hazard foot; no labels, graphs or surface noise.
                material[(x < 3) | (x > width - 3) | (y < 3)] = OID['white']
                material[(y > 3) & (y < 6)] = OID[accent]
                material[y > height - 6] = OID['cable']
                material[(y > height - 6) & (y < height - 3) & (np.mod(x + y, 14) < 5)] = OID['mustard']
                return material
            if design == 'detailed':
                material = np.full(len(P), OID['steel'])
                # Flat panel seams and beveled outer frame: hardware uses the actual machine ramps.
                material[(x < 3) | (x > width - 3) | (y < 3)] = OID['white']
                material[(y > 3) & (y < 6)] = OID[accent]
                material[y > height - 6] = OID['cable']
                if machine == 'power':
                    # Unwrapped reactor shell: two broad gold coil collars around silver ribs.
                    material[((y > 9) & (y < 23)) | ((y > 98) & (y < 110))] = OID['mustard']
                    material[((y > 10) & (y < 12)) | ((y > 99) & (y < 101))] = OID['white']
                    material[(y > 19) & (y < 22) & (np.mod(x, 16) < 2)] = OID['foil']
                    material[(y > 106) & (y < 109) & (np.mod(x, 16) < 2)] = OID['foil']
                    clamps = np.mod(x - 24, 48) < 2.5
                    material[clamps & (((y > 14) & (y < 22)) | ((y > 101) & (y < 109)))] = OID['steel']
                    for row in (26, 45, 70, 94):
                        material[(np.abs(y - row) < .65) & (x > 22) & (x < width - 22)] = OID['white']
                    # Open service leads sit outside the three welding fields.
                    for column, ramp in ((8, 'coral'), (12, 'teal'), (16, 'mustard')):
                        wire = np.abs(x - column - np.sin(y / 15) * 1.5) < .75
                        material[wire & (y > 29) & (y < 90)] = OID[ramp]
                    material[(x > width - 14) & (x < width - 7) & (y > 32) & (y < 88)] = OID['mustard']
                    material[(x > width - 11) & (x < width - 9) & (y > 35) & (y < 85)] = OID['foil']
                else:
                    # Teal chamber face, pale mounting bands, silver ventilated base and hazard foot.
                    field = (x > 19) & (x < width - 19) & (y > 25) & (y < 93)
                    material[field] = OID['tglass']
                    material[((y > 20) & (y < 26)) | ((y > 92) & (y < 97))] = OID['white']
                    material[(y > 26) & (y < 29)] = OID['teal']
                    vent = ((x > 27) & (x < 97) | (x > width - 74) & (x < width - 26)) & (y > 99) & (y < 110)
                    material[vent & (np.mod(y, 3) < 1.1)] = OID['cable']
                    material[(y > height - 7) & (y < height - 3)] = OID['cable']
                    material[(y > height - 7) & (y < height - 3) & (np.mod(x + y, 9) < 4)] = OID['mustard']
                for column in (112, 224):
                    join = (y > 29) & (y < 93)
                    material[join & (np.abs(x - column) < .65)] = OID['cable']
                    material[join & (np.abs(x - column - 1.2) < .5)] = OID['white']
                    for row in (33, 87):
                        material[(np.abs(x - column) < 1.6) & (np.abs(y - row) < 1.1)] = OID['white']
                # Small casing scuffs, kept clear of the intended damage sites.
                for sx, sy in ((36, 31), (140, 37), (244, 30), (206, 90)):
                    material[(x > sx) & (x < sx + 7) & (np.abs(y - sy - (x - sx) * .16) < .4)] = OID['white']
                return material
            material = np.full(len(P), OID['white'])
            # Clean printed trim, identical material accents to the corresponding casing.
            material[y < 5] = OID[accent]
            material[(y > height - 5) & (y < height - 2)] = OID['steel']
            if machine == 'power':
                # The reactor's fine steel bands and gold coil channels, shown face-on.
                material[(np.abs(y - 25) < .6) | (np.abs(y - 94) < .6)] = OID['steel']
                material[(x > width - 33) & (x < width - 29) & (y > 18) & (y < height - 18)] = OID['mustard']
                material[(x > width - 26) & (x < width - 24) & (y > 18) & (y < height - 18)] = OID['steel']
            else:
                # The oxygen housing's teal strip and recessed horizontal cooling grille.
                material[(y > 22) & (y < 25)] = OID['teal']
                grille = (x > width - 48) & (x < width - 18) & (y > height - 32) & (y < height - 14)
                material[grille & (np.mod(y, 4) < 1.2)] = OID['dark']
            return material
        parts = [P_('inspection_wall', A.RoundBox(c, half, .3, R), 'white', 'wall', decal)]
        def point(x, y, depth=1.15):
            return c + R @ [(x - width / 2) * S, -depth, (height / 2 - y) * S]

        if design == 'equipment':
            def module_decal(part, P):
                q = part.sdf.local(P) / S
                hw, hh = part.sdf.half[0] / S, part.sdf.half[2] / S
                x, y = q[:, 0] + hw, hh - q[:, 2]
                material = np.full(len(P), OID['darkwin'])
                inner = (np.abs(q[:, 0]) < hw - 2) & (np.abs(q[:, 2]) < hh - 2)
                material[~inner] = OID['steel']
                material[(q[:, 2] > hh - 1.2) | (q[:, 0] < -hw + 1)] = OID['white']
                if part.name == 'core':
                    core = (q[:, 0] / (hw - 5)) ** 2 + (q[:, 2] / (hh - 3)) ** 2 < 1
                    material[core] = OID['redcore']
                    material[core & (np.abs(q[:, 0]) < 4)] = OID['coral']
                    material[core & (np.abs(q[:, 2]) < 2)] = OID['coral']
                    material[core & (np.mod(x - 3, 10) < 1.5)] = OID['cable']
                elif part.name == 'vent':
                    slats = inner & (np.mod(y, 5) < 1.4)
                    material[slats] = OID['teal' if machine == 'oxygen' else 'steel']
                elif part.name == 'status':
                    for index, ramp in enumerate(('mustard', 'coral', 'dark')):
                        if machine == 'oxygen':
                            led = np.hypot(x - hw * 1.5, y - (8 + index * 10)) < 2.2
                            bar = (x > 5) & (x < hw + 1) & (np.abs(y - (8 + index * 10)) < 2.7)
                            material[bar] = OID['white' if index == 0 else 'tglass']
                        else:
                            led = np.hypot(x - (9 + index * 14), y - hh) < 2.5
                        material[led] = OID[ramp]
                return material

            def module(name, x, y, w, h):
                parts.append(P_(name, A.RoundBox(point(x + w / 2, y + h / 2), (w * S / 2, .28, h * S / 2), .3, R),
                                'steel', name, module_decal))

            def pipe(x, y, w, h, ramp):
                parts.append(P_('pipe', A.RoundBox(point(x + w / 2, y + h / 2, 1.6),
                                (w * S / 2, .4, h * S / 2), .65 * S, R), ramp, f'pipe{x}:{y}'))

            face = np.column_stack((-M.F, M.CR, M.CU))
            def port_decal(part, P):
                q = part.sdf.local(P) / S
                radius = np.hypot(q[:, 1], q[:, 2])
                edge = part.sdf.radius / S
                material = np.full(len(P), OID['white'])
                if machine == 'oxygen':
                    material[radius < edge - 3] = OID['teal']
                    material[radius < edge - 6] = OID['darkwin']
                    material[(radius > edge - 4) & (radius < edge - 3)] = OID['steel']
                    if part.name == 'fan':
                        angle = np.arctan2(q[:, 2], q[:, 1])
                        material[(radius > 2) & (radius < edge - 3) & (np.mod(angle + radius * .08, TAU / 3) < .65)] = OID['tglass']
                        material[radius < 2] = OID['steel']
                else:
                    material[radius > edge - 1.5] = OID['steel']
                    needle = (np.abs(q[:, 1] - q[:, 2] * .6) < .65) & (radius < edge - 3)
                    material[needle] = OID['coral']
                    material[radius < 1.8] = OID['steel']
                return material

            if machine == 'power':
                # Pressure gauge, warm core, one status bay and two broad gold pipe runs.
                parts.append(P_('gauge', A.Disc(point(28, 25), 12 * S, .28, .15, face), 'white', 'gauge', port_decal))
                module('core', 143, 9, 58, 39)
                module('vent', 143, 54, 59, 53)
                module('status', 271, 9, 57, 25)
                pipe(6, 87, 124, 5, 'mustard')
                pipe(209, 25, 123, 5, 'mustard')
                pipe(327, 25, 5, 44, 'mustard')
                for column in (23, 63, 103):
                    pipe(column, 84, 2, 11, 'steel')
                for column in (227, 269, 310):
                    pipe(column, 22, 2, 11, 'steel')
            else:
                # Three legible assemblies, kept broad and quiet around the welding holes.
                parts.append(P_('chamber', A.Disc(point(165, 29), 20 * S, .3, .25, face), 'white', 'chamber', port_decal))
                parts.append(P_('fan', A.Disc(point(299, 23), 12 * S, .3, .15, face), 'teal', 'fan', port_decal))
                module('vent', 11, 12, 47, 27)
                module('status', 218, 8, 36, 36)
                for column in (82, 103):
                    pipe(column, 44, 4, 63, 'teal')
                    for row in (51, 76, 101):
                        pipe(column - 2, row, 8, 2, 'steel')
        if design == 'detailed':
            if machine == 'power':
                def relay_decal(part, P):
                    q = part.sdf.local(P) / S
                    material = np.full(len(P), OID['cable'])
                    lens = (np.abs(q[:, 0]) < 9) & (np.abs(q[:, 2]) < 3)
                    material[lens] = OID['redcore']
                    material[lens & (np.abs(q[:, 2]) < .7) & (q[:, 0] < 4)] = OID['coral']
                    material[(np.abs(q[:, 0]) > 11) & (np.abs(q[:, 2]) > 3)] = OID['white']
                    return material
                parts.append(P_('relay', A.RoundBox(point(168, 16), (14 * S, .28, 5 * S), .2, R), 'cable', 'relay', relay_decal))
            else:
                # A small front-facing cooling fan and the machine's paired glass coolant cells.
                face = np.column_stack((-M.F, M.CR, M.CU))
                def fan_decal(part, P):
                    q = part.sdf.local(P) / S
                    radius = np.hypot(q[:, 1], q[:, 2])
                    angle = np.arctan2(q[:, 2], q[:, 1])
                    material = np.full(len(P), OID['darkwin'])
                    material[(radius > 3) & (radius < 9) & (np.mod(angle + radius * .06, TAU / 6) < .5)] = OID['steel']
                    material[radius > 10] = OID['teal']
                    material[radius < 2.5] = OID['white']
                    return material
                parts.append(P_('fan', A.Disc(point(168, 16, 1.35), 11 * S, .32, .1, face), 'steel', 'fan', fan_decal))
                def coolant_decal(part, P):
                    q = part.sdf.local(P) / S
                    material = np.full(len(P), OID['teal'])
                    glass = (np.abs(q[:, 0]) < 3) & (np.abs(q[:, 2]) < 25)
                    material[glass] = OID['tglass']
                    material[glass & (q[:, 0] < -1.5)] = OID['shard']
                    material[np.abs(q[:, 2]) > 26] = OID['white']
                    material[(np.abs(q[:, 0]) < 1.2) & (np.abs(q[:, 2]) < 18) & (np.mod(q[:, 2], 8) < 1)] = OID['white']
                    return material
                for column in (11, width - 11):
                    parts.append(P_('coolant', A.RoundBox(point(column, 59), (5 * S, .32, 31 * S), 1.1 * S, R), 'teal', f'coolant{column}', coolant_decal))
        for x in (-half[0] + 3 * S, half[0] - 3 * S):
            for z in (-half[2] + 7 * S, half[2] - 7 * S):
                bolt = c + R @ [x, -.95, z]
                parts.append(P_('fastener', A.RoundBox(bolt, (.8, .25, .8), .12, R), 'steel', 'bolt'))
        rgba = M.sprite_rgba(M.render_sprite(parts, box))
        file = f'machines/{machine}_repair_panel.png'
        Image.fromarray(rgba).save(os.path.join(OUT, file))
        Image.fromarray(rgba).resize((width * 4, height * 4), Image.NEAREST).save(os.path.join(out, 'preview', f'{machine}_repair_panel_x4.png'))
        info[machine + '_generator']['repair_panel'] = dict(file=file, size=[width, height],
            sites=[[55, 65], [167, 73], [278, 58]], view='flat', design=design,
            note='Flat front-facing machine casing, following the approved draft; three holes and fractures are drawn by the puzzle model.')
    with open(path, 'w') as fh:
        json.dump(info, fh, indent=1)
    print('Flat machine repair panels generated.')


def export_loose_scrap(reactor_c, gen_c, glass_positions):
    """Enough salvage for both machines, in reachable front-of-room positions outside F priority."""
    source = os.path.join(M.ROOT, 'assets', 'maps', 'red_planet', 'red_planet_props.json')
    with open(source) as fh:
        sheets = json.load(fh)
    def relative(sprites):
        return {name: dict(sprite, file='../red_planet/' + sprite['file']) for name, sprite in sprites.items()}
    objects = []
    for c in (reactor_c, gen_c):
        for frame, offset in enumerate(([-16, -64, 0], [10, -65, 0], [34, -52, 0])):
            p = c + offset
            objects.append(dict(kind='scrap', frame=frame, job='gather',
                                world=[float(p[0]), float(p[1])], radius=4.0, solid=False))
    own_views, box = export_cargo_box()
    objects.append(box)
    # Twelve fragments under the front panes and six under the far gash. Append after the box
    # so the session IDs of all existing props remain stable.
    objects.extend(glass_pickups(glass_positions))
    sprites_views = [dict(relative(s), **own) for s, own in zip(sheets['sprites_views'], own_views)]
    data = dict(sprites=sprites_views[0], sprites_views=sprites_views, objects=objects, lamps=[],
                note='Eighteen collectible glass fragments, six per window, six machine scraps, and the cargo box (lift it, stand on it: '
                     'top = its height, half = half its footprint turned by yaw, contents = what spills when it breaks). '
                     'Session IDs persist through airlocks.')
    with open(os.path.join(OUT, 'interior_props.json'), 'w') as fh:
        json.dump(data, fh, indent=1)


def glass_pickups(positions):
    """Keep shards under their authored panes but move any obstructed scatter onto open floor."""
    walk = np.array(Image.open(os.path.join(OUT, 'base_interior_walk.png')))[..., 2]
    def clear(p):
        for dx, dy in ((0, 0), (4, 0), (-4, 0), (0, 4), (0, -4)):
            u, v = M.to_grid(p[0] + dx, p[1] + dy)
            u, v = math.floor(u), math.floor(v)
            if not (0 <= u < N and 0 <= v < N and walk[v, u] == 255):
                return False
        return True
    objects = []
    for index in list(range(0, 24, 2)) + list(range(26, 38, 2)):
        original = np.array(positions[index])
        spot = None
        for radius in (0, 2, 4, 6, 8, 10, 12, 16):
            for angle in np.arange(8) * TAU / 8:
                p = original + radius * np.array([math.cos(angle), math.sin(angle)])
                if clear(p):
                    spot = p.tolist()
                    break
            if spot is not None:
                break
        if spot is None:
            raise ValueError(f'No open floor for glass {index}: {original}')
        objects.append(dict(kind='glass', frame=index % 3, job='gather', world=spot, radius=3.0, solid=False))
    return objects


def prop_sheet(name, frames_parts, k):
    """A loose thing's frames in a strip, as view k sees it (turned about its foot), the way
    tools/props_gen.py draws the overworld's props but under the base's light; the anchor is
    where its foot point sits."""
    frames_parts = [M.turned(fp, about=np.zeros(3), k=k) for fp in frames_parts]
    box = M.sprite_box(frames_parts, pad=3)
    frames = [M.render_sprite(fp, box) for fp in frames_parts]
    # Thin glass uses the original floor debris's exposed teal/white edges, without the opaque
    # black silhouette of crates and metal salvage. Reflections remain inside the SDF surface.
    strip = np.concatenate([np.dstack([fr['rgb'], fr['filled'].astype(np.uint8) * 255])
                            if name == 'glass' else M.sprite_rgba(fr) for fr in frames], axis=1)
    fn = f'props/{name}{M.view_sfx(k)}.png'
    Image.fromarray(strip).save(os.path.join(OUT, fn))
    return dict(file=fn, frames=len(frames_parts), frame_size=[box[2], box[3]],
                anchor=[round(M.AX - box[0], 1), round(M.AY - box[1], 1)])


def export_cargo_box():
    """The cargo box as a loose prop the tool lifts and you stand on (frames: whole, three cracks,
    burst), and the ration packs it spills, in every view. Returns each view's sheets and the box."""
    os.makedirs(os.path.join(OUT, 'props'), exist_ok=True)
    models = dict(cargo_box=[cargo_box(s) for s in range(5)], ration=[ration(k) for k in range(3)],
                  glass=[glass_fragment(k, f) for k in range(3) for f in range(28)])
    views = [{name: prop_sheet(name, fps, k) for name, fps in models.items()} for k in range(4)]
    for view in views:
        view['glass'].update(animation=dict(variant_frames=28, fps=9), shadow_alpha=.22)
    st = ROOMS['storage']
    h = CARGO_HALF
    box = dict(kind='cargo_box', frame=0, job='lift', world=[st['X'] + CARGO_AT[0], st['Y'] + CARGO_AT[1]],
               radius=round(float(np.hypot(h[0], h[1])), 1), solid=False, top=round(float(2 * h[2]), 1),
               half=[float(h[0]), float(h[1])], yaw=CARGO_YAW, contents=dict(kind='ration', count=CARGO_RATIONS),
               drop_sound='cargo_drop')
    return views, box


def glass_fragment(k, frame=0):
    """One angular chip of teal glass, a thin bevel and a brief moving white reflection.
    Facets use the existing tglass/SKYWIN/WHITE ramps; no paper-like overlapping sheets."""
    a, b, yaw = [(2.1, .9, -.35), (1.6, 1.15, .7), (1.25, .85, 1.2)][k]
    c = cam(0, 0, .24)
    R = A.rz(yaw) @ A.rx(.08)
    base = A.RoundBox(c, (a, b, .12), .04, R)
    # Two diagonal bites create a pointed broken edge rather than a rounded rectangle.
    sdf = Cut(base, A.RoundBox(c + R @ [a, -b, 0], (.75, .55, .5), .02, R @ A.rz(.55)))
    sdf = Cut(sdf, A.RoundBox(c + R @ [-a, b, 0], (.5, .55, .5), .02, R @ A.rz(-.45)))
    def facet(part, points):
        q = part.sdf.local(points)
        mat = np.full(len(points), OID['windowglass' if k == 0 else 'tglass'])
        # A pale sharp fracture edge and one quiet reflected facet; most of the face stays teal.
        mat[(q[:, 1] > b - .18) & (q[:, 0] < a * .4)] = OID['glassedge']
        mat[(q[:, 0] + q[:, 1] * .8 > a * .45)] = OID['windowglass']
        if 1 <= frame <= 6:
            sweep = -a - b * .5 + (frame - 1) / 5 * (2 * a + b)
            mat[np.abs(q[:, 0] + q[:, 1] * .7 - sweep) < .3] = OID['glassedge']
        return mat
    return [P_('glass', sdf, 'tglass', 'glass', facet)]


def export_window_patches(D, gid, wall_gids, states):
    """Pristine window pixels and their real world-height for the live scanning pass.
    Read the re-shaded sealed state, including its own local light/sun masks: no crack halo
    or light from the old aperture is copied onto the clean pane."""
    os.makedirs(os.path.join(OUT, 'windows'), exist_ok=True)
    ys, xs = np.nonzero(np.isin(gid, wall_gids))
    O = view_rays(ys, xs)
    t = (D[ys, xs] - O[:, 1]) / M.F[1]
    P = M.to_canon(O + t[:, None] * M.F)
    room, th = wall_layers(P)
    st = ROOMS['storage']
    rr = np.hypot(P[:, 0] - st['X'], P[:, 1] - st['Y'])
    win = (room == list(ROOMS).index('storage')) & (rr < st['R']) & (P[:, 2] > WIN[0]) & (P[:, 2] < WIN[1])
    data = {}
    for index, (id_, ang) in enumerate(HOLES):
        sel = win & (np.abs(th * rr - math.radians(ang) * rr) < 4 * (WIN[1] - WIN[0]) / 2.5)
        if not sel.any():
            continue
        xx, yy = xs[sel], ys[sel]
        x0, y0, x1, y1 = xx.min(), yy.min(), xx.max() + 1, yy.max() + 1
        shape = (y1 - y0, x1 - x0)
        final, sun, light, _ = states[1 << index]
        rgba = np.zeros((*shape, 4), np.uint8)
        rgba[yy - y0, xx - x0, :3] = final[yy, xx]
        rgba[yy - y0, xx - x0, 3] = 255
        height = np.zeros(shape, np.uint8)
        height[yy - y0, xx - x0] = np.clip((WIN[1] - P[sel, 2]) / (WIN[1] - WIN[0]) * 255, 0, 255).astype(np.uint8)
        stem = f'windows/{id_}{M.SFX}'
        Image.fromarray(rgba).save(os.path.join(OUT, stem + '.png'))
        Image.fromarray(height).save(os.path.join(OUT, stem + '_height.png'))
        for field, values in [('sun', sun), ('light', light)]:
            Image.fromarray(np.round(np.clip(values[y0:y1, x0:x1], 0, 1) * 255).astype(np.uint8)).save(
                os.path.join(OUT, stem + '_' + field + '.png'))
        data[id_] = dict(file=stem + '.png', height=stem + '_height.png', sun=stem + '_sun.png',
                        light=stem + '_light.png', position=[int(x0), int(y0)])
    return data


def export_window_restorations(states):
    """Small exact replacements for each repaired-pane combination, including overlapping shafts.
    The combined colour pass removes cracks, rims, halos and floor/wall light together; geometry
    stays unchanged. Full local mask rectangles replace the corresponding sun/light values."""
    original, sun0, light0, _ = states[0]
    data = []
    for mask in range(1, 8):
        final, sun, light, _ = states[mask]
        changed = np.any(final != original, axis=-1) | (sun != sun0) | (light != light0)
        info = dict(panes=[id_ for index, (id_, _) in enumerate(HOLES) if mask & (1 << index)])
        if changed.any():
            yy, xx = np.nonzero(changed)
            x0, y0, x1, y1 = xx.min(), yy.min(), xx.max() + 1, yy.max() + 1
            stem = f'windows/restored_{mask}{M.SFX}'
            rgba = np.dstack([final[y0:y1, x0:x1], changed[y0:y1, x0:x1].astype(np.uint8) * 255])
            Image.fromarray(rgba).save(os.path.join(OUT, stem + '.png'))
            for field, values in [('sun', sun), ('light', light)]:
                Image.fromarray(np.round(np.clip(values[y0:y1, x0:x1], 0, 1) * 255).astype(np.uint8)).save(
                    os.path.join(OUT, stem + '_' + field + '.png'))
            info.update(file=stem + '.png', sun=stem + '_sun.png', light=stem + '_light.png',
                        position=[int(x0), int(y0)])
        data.append(info)
    return data


def window_crack_info():
    """Storage's smashed panes, to stand under and mend: where on the floor to stand (world, the
    middle of the box pushed to the wall under it), the middle of the hole (world, with its
    height), and where this view draws that (map px; seen = the view leaves that wall standing)."""
    out = []
    for kind_, ang in HOLES:
        mid = room_pt('storage', ang, r_in('storage'), (WIN[0] + WIN[1]) / 2)
        stand = room_pt('storage', ang, r_in('storage') - 14.0)
        out.append(dict(id=kind_, world=[round(float(v), 2) for v in stand[:2]], hole=[round(float(v), 2) for v in mid],
                        px=pxl(mid), seen=bool(RoomWall('storage', []).height(math.radians(ang)) > WIN[1]),
                        reach_min_height=round(float(mid[2] - 22.0 - 10.0), 1)))
    return out


def restore_oxygen(parts, c, tanks):
    """Rebuild the same O2 assembly: sealed panels/glass, straight fan, coolant and bottle pipe."""
    remove = {'genpanel', 'fan', 'o2cap', 'cool1', 'pipe1', 'pipe1b'}
    out = [p for p in parts if p.group not in remove and not p.group.startswith('o2wire')
           and p.name not in ('o2housing', 'o2coil', 'cellglass', 'chamber', 'o2screen', 'o2led', 'fin')]
    out.append(P_('o2housing', A.RoundBox(c + [0, 0, 8.6], (12.5, 8.4, 7.2), 1.6), 'white', 'gen', decal_o2))
    tube = Cut(A.Disc(c + [0, 0, 22.5], 8, 7, 1, M.UPAX), A.Disc(c + [0, 0, 22.5], 7, 8, .5, M.UPAX))
    out += [P_('chamber', tube, 'tglass', 'chamber'),
            P_('hub', A.Disc(c + [0, 0, 22.5], 1.5, 6, .4, M.UPAX), 'steel', 'fan'),
            P_('o2cap', A.Ellipsoid(c + [0, 0, 31.6], (8.8, 8.8, 2.4)), 'white', 'o2cap'),
            P_('o2capring', A.Torus(c + [0, 0, 31.2], 8.6, .7), 'teal', 'o2cap'),
            P_('o2vent', A.Disc(c + [0, 0, 33.7], 3, .6, .3, A.ry(-math.pi / 2)), 'steel', 'o2cap'),
            P_('coolant', A.RoundCone(c + [17, -4, 6], c + [17, 6.5, 6], 3.2, 3.2), 'teal', 'cool1'),
            P_('coolband', A.Torus(c + [17, 1.2, 6], 3.35, .5, A.rx(math.pi / 2)), 'white', 'cool1')]
    for j in range(6):
        a = j / 6 * TAU + .3
        out.append(P_('blade', A.RoundBox(c + [math.cos(a)*3.7, math.sin(a)*3.7, 22.5],
                                        (2.7, .32, 4.2), .2, A.rz(a) @ A.rx(.45)), 'steel', 'fan'))
    for y in np.arange(-6.6, 6.7, 1.65):
        out.append(P_('fin', A.RoundBox(c + [14, y, 8.2], (1.7, .22, 5.2), .12), 'steel', 'fins'))
    for k, dx in enumerate((-10.2, 10.2)):
        cc = c + [dx, -2.6, 0]
        out.append(P_('cellglass', A.Disc(cc + [0, 0, 25.5], 2.7, 2.2, .3, M.UPAX), 'tglass', f'cell{k}'))
        if k == 1:
            out.append(P_('liquid', A.Disc(cc + [0, 0, 20.4], 2.7, 3, .3, M.UPAX), 'liquid', 'cell1'))
    pc = c + [6.5, -9.4, 10.6]
    out += [P_('o2screen', A.RoundBox(pc + [-.7, -1.1, .2], (2.3, .2, 1.7), .2, A.rx(.25)), 'screen', 'o2ctl'),
            P_('o2led', A.Sphere(pc + [2.5, -1.3, 1.2], .55), 'ledcyan', 'o2ctl')]
    t = tanks[1]
    out.append(P_('pipe', A.RoundCone(c + [0, 0, 26] + A.nz(t-c)*8.4,
                                    t + [0, 0, 24] + A.nz(c-t)*7.8, 1.1, 1.1), 'teal', 'pipe1'))
    return out


def export_door():
    """The airlock door's opening as sprite frames, and where the astronaut stands to use it (in the
    base's frame; the sprite and pixels as the current view sees it)."""
    frames = [M.turned(door_parts(i / (M.DOOR_FRAMES - 1))) for i in range(M.DOOR_FRAMES)]
    box = M.sprite_box(frames, pad=3)
    strip = np.concatenate([M.sprite_rgba(M.render_sprite(fp, box)) for fp in frames], axis=1)
    Image.fromarray(strip).save(os.path.join(OUT, 'anim', f'door{M.SFX}.png'))
    f = door_frame_pt()
    lamp = f + np.array([0, -1.4 * DOOR_K, (6.9 + 7.9) * DOOR_K])
    lx, ly = M.project(*M.to_view(lamp))
    return dict(file=f'anim/door{M.SFX}.png', frames=M.DOOR_FRAMES, position=[box[0], box[1]], frame_size=[box[2], box[3]],
                sort_y=round(float(M.project(*M.to_view(f))[1]), 1), world=[round(float(f[0]), 2), round(float(f[1]), 2)],
                dir=[0.0, -1.0], lamp_px=[round(float(lx), 1), round(float(ly), 1)], height=round(14.8 * DOOR_K, 1))


if __name__ == '__main__':
    np.seterr(all='ignore')
    if '--solar-input-only' in sys.argv:
        M.SUN = SUN_IN
        export_solar_input()
    elif '--repair-metadata-only' in sys.argv:
        refresh_repair_metadata()
    elif '--repair-panels-only' in sys.argv:
        M.VIEW, M.SFX = 0, ''
        M.SUN = SUN_IN
        set_frame()
        export_repair_panels()
    elif '--props-only' in sys.argv:
        M.VIEW, M.SFX = 0, ''
        M.SUN = SUN_IN
        set_frame()
        path = os.path.join(OUT, 'interior_props.json')
        with open(path) as fh:
            data = json.load(fh)
        views, _ = export_cargo_box()
        for sprites, own in zip(data['sprites_views'], views):
            sprites.update(own)
        data['sprites'] = data['sprites_views'][0]
        parts = storage_props(np.random.default_rng(77))
        positions = [p.sdf.c[:2].tolist() for p in parts if p.group.startswith('gshard')]
        data['objects'] = [o for o in data['objects'] if o['kind'] != 'glass'] + glass_pickups(positions)
        with open(path, 'w') as fh:
            json.dump(data, fh, indent=1)
    else:
        build()
        root = OUT
        for folder, fixed in [('repaired_power', {'power'}), ('repaired_oxygen', {'oxygen'}),
                              ('repaired_both', {'power', 'oxygen'})]:
            OUT = os.path.join(root, folder)
            build(fixed)
        export_solar_input()
