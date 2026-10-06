#!/usr/bin/env python3
"""
Astronaut sprite generator
==========================

The astronaut is modelled out of signed-distance primitives, posed by a small
procedural rig (IK legs, FK/IK arms, secondary motion on helmet + antenna) and
ray-marched through a 2:1 isometric orthographic camera *directly at pixel
resolution*. Every pixel is then cel-shaded from hand-picked, hue-shifted colour
ramps, inner-lined, outlined and packed into sprite sheets + a JSON manifest.

    python tools/astronaut_sprite_gen.py            # full build
    python tools/astronaut_sprite_gen.py --quick    # contact sheet only (fast)

Everything that defines the look (palette, proportions, timing) is a constant
near the top of the file, so the art can be re-tuned and re-exported.
"""
import json
import math
import os
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# Multitool designs:  v1  a handheld tool (white body, coral cap, claw prongs round a lens)
#                     v2  an arm gauntlet that unfolds from a pack device (red and gold armour)
TOOL_DESIGN = os.environ.get('TOOL_DESIGN', 'v2')
OUT = os.path.join(ROOT, 'assets', 'characters', 'astronaut')

# ------------------------------------------------------------------ camera / frame
FRAME_W, FRAME_H = 64, 64
ANCHOR = (32, 56)                # feet touch the ground here (pixel-corner coords)
PITCH = math.radians(30.0)       # 2:1 pixel-isometric camera (tiles are 2:1 diamonds)
SCALE = math.cos(PITCH)          # world units per pixel -> 1 unit of height == 1px

# ------------------------------------------------------------------ palette
# dark -> light. Shadows drift toward violet, lights toward warm cream (cozy).
RAMPS = {
    'suit':    ['#6f6486', '#a99bb4', '#e4d9d0', '#fff9ef'],
    'rim':     ['#4a4262', '#71668a', '#a69ab2', '#cfc5cc'],
    'pack':    ['#5f5679', '#9286a3', '#c8bdc0', '#e9e0d8'],
    'coral':   ['#7e2f48', '#c04e57', '#ec7a5a', '#ffb183'],
    'mustard': ['#7d4a32', '#c3843b', '#efb950', '#ffe193'],
    'dark':    ['#272038', '#3b3253', '#574d70', '#7f759a'],
    'teal':    ['#1b4f5e', '#2a8a8c', '#4fc6b4', '#aef0da'],
    'visor':   ['#111430', '#1a2450', '#243c6c', '#335f88', '#64aeb8', '#eefcf4'],
    'bulb':    ['#a8582e', '#eb9b45', '#ffd468', '#fff7d2'],
    'wood':    ['#3f2630', '#6b4038', '#99654a', '#c99466'],
    # the multitool: glossy white shell, an emitter lens that lights up when it is out
    'tool':    ['#77738f', '#b8b5c9', '#ecebf4', '#ffffff'],
    'lens':    ['#2f6f8c', '#69c8e6', '#c9f6ff', '#ffffff'],
    'gun':     ['#16142a', '#272544', '#403f66', '#6c6c98'],
    'armor':   ['#5c1626', '#a3283a', '#e2483e', '#ff9468'],
    'gold':    ['#7a4422', '#c78a32', '#f4c24e', '#fff0a8'],
    'gunlit':  ['#20203c', '#363a62', '#566290', '#8a9ccc'],
    'lensoff': ['#1c2440', '#2c3d5c', '#46607e', '#7894ae'],
}
OUTLINE = '#22182c'
STALK = '#3b3253'


def hex2rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


RAMP_NAMES = list(RAMPS)
RID = {n: i for i, n in enumerate(RAMP_NAMES)}
RAMP_RGB = [[hex2rgb(c) for c in RAMPS[n]] for n in RAMP_NAMES]

# ------------------------------------------------------------------ proportions
ANKLE_H = 2.0
THIGH, SHIN = 5.0, 4.8
LEG_MAX = (THIGH + SHIN) * 0.985
HIP = np.array([2.75, 0.0, -1.3])          # pelvis frame
SHOULDER = np.array([5.6, -0.2, 7.7])      # torso frame
UPPER, FORE = 4.0, 3.6
NECK_Z = 9.9
HELMET_OFF = np.array([0.0, 0.4, 7.9])     # head frame, from neck pivot
HELMET_R = np.array([9.0, 8.6, 8.3])
VISOR = (0.72, 0.50, 0.02)                 # half-width, half-height, centre (helmet direction space)
TOE, HEEL = 3.4, 1.5
STAND_Z = 12.8

D2R = math.pi / 180.0
TAU = 2.0 * math.pi


# ================================================================== math helpers
def rx(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]], float)


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]], float)


def rz(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], float)


def euler(yaw=0.0, pitch=0.0, roll=0.0):
    """yaw about +z, pitch>0 leans the top toward +y (forward), roll>0 toward +x."""
    return rz(yaw) @ rx(-pitch) @ ry(roll)


def length(q):
    return np.sqrt(np.einsum('ij,ij->i', q, q))


def nz(v):
    v = np.asarray(v, float)
    return v / np.linalg.norm(v)


def ease(x):
    x = min(max(x, 0.0), 1.0)
    return 0.5 - 0.5 * math.cos(math.pi * x)


def lerp(a, b, t):
    return a + (b - a) * t


def smin(a, b, k):
    h = np.maximum(k - np.abs(a - b), 0.0) / k
    return np.minimum(a, b) - h * h * k * 0.25


# ================================================================== SDF primitives
class Sphere:
    def __init__(self, c, r):
        self.c, self.r = np.asarray(c, float), r

    def local(self, P):
        return P - self.c

    def __call__(self, P):
        return length(P - self.c) - self.r


class Ellipsoid:
    def __init__(self, c, radii, R=None):
        self.c = np.asarray(c, float)
        self.rad = np.asarray(radii, float)
        self.R = np.eye(3) if R is None else R

    def local(self, P):
        return (P - self.c) @ self.R

    def __call__(self, P):
        q = self.local(P)
        k0 = length(q / self.rad)
        k1 = length(q / (self.rad * self.rad))
        return k0 * (k0 - 1.0) / np.maximum(k1, 1e-6)


class RoundBox:
    def __init__(self, c, half, rad, R=None):
        self.c = np.asarray(c, float)
        self.half = np.asarray(half, float)
        self.rad = rad
        self.R = np.eye(3) if R is None else R

    def local(self, P):
        return (P - self.c) @ self.R

    def __call__(self, P):
        q = np.abs(self.local(P)) - (self.half - self.rad)
        return length(np.maximum(q, 0.0)) + np.minimum(q.max(axis=1), 0.0) - self.rad


class RoundCone:
    """Capsule with different end radii (Inigo Quilez)."""

    def __init__(self, a, b, r1, r2):
        self.a, self.b = np.asarray(a, float), np.asarray(b, float)
        self.r1, self.r2 = r1, r2
        ba = self.b - self.a
        self.ba = ba
        self.l2 = float(ba @ ba)
        self.rr = r1 - r2
        self.a2 = self.l2 - self.rr * self.rr
        self.il2 = 1.0 / self.l2

    def local(self, P):
        return ((P - self.a) @ self.ba) * self.il2   # 0 at a, 1 at b

    def __call__(self, P):
        pa = P - self.a
        y = pa @ self.ba
        z = y - self.l2
        w = pa * self.l2 - y[:, None] * self.ba
        x2 = np.einsum('ij,ij->i', w, w)
        y2 = y * y * self.l2
        z2 = z * z * self.l2
        k = math.copysign(1.0, self.rr) * self.rr * self.rr * x2
        d_b = np.sqrt(x2 + z2) * self.il2 - self.r2
        d_a = np.sqrt(x2 + y2) * self.il2 - self.r1
        d_m = (np.sqrt(np.maximum(x2 * self.a2 * self.il2, 0.0)) + y * self.rr) * self.il2 - self.r1
        return np.where(np.sign(z) * self.a2 * z2 > k, d_b,
                        np.where(np.sign(y) * self.a2 * y2 < k, d_a, d_m))


class Torus:
    def __init__(self, c, major, minor, R=None):
        self.c = np.asarray(c, float)
        self.major, self.minor = major, minor
        self.R = np.eye(3) if R is None else R

    def local(self, P):
        return (P - self.c) @ self.R

    def __call__(self, P):
        q = self.local(P)
        a = np.sqrt(q[:, 0] ** 2 + q[:, 1] ** 2) - self.major
        return np.sqrt(a * a + q[:, 2] ** 2) - self.minor


class Disc:
    """Rounded cylinder whose axis is the local x axis."""

    def __init__(self, c, radius, half_len, rounding, R=None):
        self.c = np.asarray(c, float)
        self.radius, self.half, self.rnd = radius, half_len, rounding
        self.R = np.eye(3) if R is None else R

    def local(self, P):
        return (P - self.c) @ self.R

    def __call__(self, P):
        q = self.local(P)
        dr = np.sqrt(q[:, 1] ** 2 + q[:, 2] ** 2) - (self.radius - self.rnd)
        dh = np.abs(q[:, 0]) - (self.half - self.rnd)
        out = np.sqrt(np.maximum(dr, 0) ** 2 + np.maximum(dh, 0) ** 2)
        return np.minimum(np.maximum(dr, dh), 0.0) + out - self.rnd


# ================================================================== scene
BLEND_K = {'body': 2.2, 'armL': 0.9, 'armR': 0.9, 'legL': 1.0, 'legR': 1.0}


class Part:
    def __init__(self, name, sdf, ramp, group, blend=None, decal=None, emissive=False):
        self.name, self.sdf, self.ramp, self.group = name, sdf, ramp, group
        self.blend, self.decal, self.emissive = blend, decal, emissive


class Scene:
    def __init__(self, parts):
        self.parts = parts
        groups, order = {}, []
        for i, p in enumerate(parts):
            key = p.blend if p.blend else ('solo', i)
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append(i)
        self.groups = [(BLEND_K.get(k, 0.0) if isinstance(k, str) else 0.0, groups[k]) for k in order]
        names = []
        for p in parts:
            if p.group not in names:
                names.append(p.group)
        self.group_names = names
        self.group_of = np.array([names.index(p.group) for p in parts])

    def dist_all(self, P):
        return np.stack([p.sdf(P) for p in self.parts])

    def combine(self, D):
        total = None
        for k, idx in self.groups:
            d = D[idx[0]]
            for j in idx[1:]:
                d = smin(d, D[j], k) if k > 0 else np.minimum(d, D[j])
            total = d if total is None else np.minimum(total, d)
        return total

    def __call__(self, P):
        return self.combine(self.dist_all(P))


# ================================================================== decals
def decal_helmet(part, P):
    q = part.sdf.local(P) / HELMET_R
    d = q / np.maximum(length(q), 1e-6)[:, None]
    e = (d[:, 0] / VISOR[0]) ** 2 + ((d[:, 2] - VISOR[2]) / VISOR[1]) ** 2
    out = np.full(len(P), RID['suit'])
    front = d[:, 1] > 0.0
    out[front & (e < 1.38)] = RID['rim']
    out[front & (e < 1.0)] = RID['visor']
    return out


def decal_torso(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), RID['suit'])
    # belt
    out[q[:, 2] < -3.4] = RID['dark']
    buckle = (q[:, 2] < -3.3) & (q[:, 2] > -5.2) & (q[:, 1] > 2.0) & (np.abs(q[:, 0]) < 1.25)
    out[buckle] = RID['mustard']
    # chest control panel
    front = q[:, 1] > 2.0
    panel = front & (np.abs(q[:, 0] - 0.2) < 2.5) & (q[:, 2] > -0.6) & (q[:, 2] < 2.2)
    out[panel] = RID['dark']
    out[panel & (q[:, 0] < -0.2) & (q[:, 2] > 0.1) & (q[:, 2] < 1.6)] = RID['teal']
    out[panel & (q[:, 0] > 0.9) & (q[:, 2] > 0.1) & (q[:, 2] < 1.6)] = RID['coral']
    return out


def decal_pack(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), RID['pack'])
    out[(q[:, 2] > 1.2) & (q[:, 2] < 2.7)] = RID['coral']
    back = q[:, 1] < -1.3
    vent = back & (np.abs(q[:, 0]) < 2.6) & (q[:, 2] > -3.2) & (q[:, 2] < -0.2)
    out[vent] = RID['dark']
    out[vent & (q[:, 0] > 0.6) & (q[:, 2] > -2.4) & (q[:, 2] < -1.0)] = RID['teal']
    return out


def decal_boot(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), RID['coral'])
    out[q[:, 2] < -0.95] = RID['dark']
    return out


# ================================================================== the multitool
# A compact device clipped to the right side of the backpack. Taken out, it bursts open into
# a ring of armour plates that fly onto the right forearm and lock into a gauntlet: dark
# segmented plating with glowing seams, a coral spine, and an emitter on the back of the hand
# that does the work (mining beam, gathering stream, lifting tether, repair scan).
TOOL_PACK = np.array([5.95, -5.1, 3.4])           # torso frame: the device on the backpack
TOOL_PACK_WRIST = np.array([6.1, -4.2, 4.6])      # where the hand goes to take it
TOOL_HOLD = np.array([8.8, 3.0, 4.9])             # ready: forearm out to the side and forward
TOOL_AIM = np.array([4.0, 7.0, 5.0])              # working: arm out straight at the target


class Moved:
    """Moves and scales an SDF about a point (plates flying into place)."""

    def __init__(self, inner, c, delta, k):
        self.inner, self.c, self.delta, self.k = inner, np.asarray(c, float), np.asarray(delta, float), max(k, 0.05)

    def _in(self, P):
        return self.c + (P - self.c - self.delta) / self.k

    def local(self, P):
        return self.inner.local(self._in(P))

    def __call__(self, P):
        return self.inner(self._in(P)) * self.k


def _arm_frame(E, W, up_hint):
    f = nz(W - E)
    up = np.asarray(up_hint, float) - (np.asarray(up_hint, float) @ f) * f
    if np.linalg.norm(up) < 1e-3:
        up = np.array([1.0, 0.0, 0.0]) - (np.array([1.0, 0.0, 0.0]) @ f) * f
    up = nz(up)
    return f, up, np.cross(f, up)


def device_parts(c, f, up, side, lit=False):
    """The folded-up multitool: a little dark slab with a coral cap and a lens."""
    Rb = np.stack([side, f, up], axis=1)
    return [Part('device', RoundBox(c, (1.25, 1.9, 1.05), 0.6, Rb), 'gun', 'tool'),
            Part('devcap', RoundBox(c + f * 1.5, (1.3, 0.5, 1.1), 0.45, Rb), 'coral', 'tool'),
            Part('devstrip', RoundBox(c + up * 1.05, (0.35, 1.3, 0.2), 0.15, Rb), 'lens' if lit else 'lensoff', 'tool'),
            Part('lens', Sphere(c + f * 2.05, 0.55), 'lens' if lit else 'lensoff', 'tool')], c + f * 2.1


def gauntlet_parts(E, W, deploy, lit, up_hint):
    """The gauntlet round the forearm E -> W. deploy 0..1: folded in the hand, bursting open
    into a ring of plates, plates flying onto the forearm (wrist first), locked. Returns parts
    and the emitter lens centre."""
    f, up, side = _arm_frame(E, W, up_hint)
    L = float(np.linalg.norm(W - E))
    hand = W + f * 0.9
    if deploy < 0.22:                                     # still folded, in the hand
        grow = 1.0 + 0.4 * deploy / 0.22
        dev, tip = device_parts(hand + up * 1.5, f, up, side)
        return [Part(q.name, Moved(q.sdf, hand + up * 1.5, np.zeros(3), grow), q.ramp, q.group) for q in dev], tip
    Rb = np.stack([side, f, up], axis=1)
    Rd = np.stack([f, side, up], axis=1)
    Rr = np.stack([side, up, f], axis=1)
    emit_c = W + f * 1.1 + up * 1.85
    lens_c = emit_c + f * 1.25
    final = [   # (name, sdf, ramp, arrival order: 0 = first, near the wrist)
        ('plate', RoundCone(E + f * L * 0.70, E + f * L * 1.06, 2.75, 2.65), 'armor', 0),
        ('plate', RoundCone(E + f * L * 0.38, E + f * L * 0.66, 2.9, 2.8), 'armor', 1),
        ('plate', RoundCone(E + f * L * 0.02, E + f * L * 0.34, 3.0, 2.92), 'armor', 2),
        ('elbow', Ellipsoid(E - f * 0.35, (2.95, 2.95, 2.95)), 'gold', 3),
        ('spine', RoundBox(E + f * L * 0.52 + up * 2.75, (0.95, L * 0.52, 0.6), 0.4, Rb), 'gold', 1),
        ('knuckle', RoundBox(hand + up * 1.25 + f * 0.25, (1.85, 1.45, 0.7), 0.45, Rb), 'gold', 0),
        ('emitter', Disc(emit_c, 1.8, 1.1, 0.5, Rd), 'gunlit', 0),
        ('emring', Torus(emit_c + f * 1.0, 1.62, 0.48, Rr), 'gold', 0),
    ]
    parts = []
    n = len(final)
    for i, (name, sdf, ramp, order) in enumerate(final):
        c, _ = _bound(sdf)
        ang = i / n * TAU
        burst = hand + up * 1.5 + (up * math.cos(ang) + side * math.sin(ang)) * 4.6 + f * 0.8
        open_ = min(1.0, (deploy - 0.22) / 0.2)               # fanning out of the device
        e = ease(open_)
        fly = ease(min(1.0, max(0.0, (deploy - 0.45 - 0.07 * order) / 0.3)))   # onto the arm
        start = lerp(hand + up * 1.5, burst, e)
        pos = lerp(start, c, fly)
        k = lerp(0.55 + 0.4 * e, 1.0, fly)
        parts.append(Part(name, Moved(sdf, c, pos - c, k), ramp, 'tool'))
    if deploy >= 0.9:                                     # seams light up once it locks
        for sf in (0.36, 0.68):
            parts.append(Part('seam', Torus(E + f * L * sf, 2.95, 0.45, Rr), 'lens' if lit else 'lensoff', 'tool'))
        parts.append(Part('spinelight', RoundBox(E + f * L * 0.52 + up * 3.38, (0.35, L * 0.4, 0.14), 0.12, Rb),
                          'lens' if lit else 'lensoff', 'tool'))
    parts.append(Part('lens', Sphere(lens_c, 1.25 if deploy >= 0.75 else 1.25 * max(0.0, (deploy - 0.45) / 0.3)),
                      'lens' if lit else 'lensoff', 'tool'))
    return parts, lens_c


def _bound(sdf):
    if isinstance(sdf, Sphere):
        return sdf.c, sdf.r
    if isinstance(sdf, (Ellipsoid,)):
        return sdf.c, float(sdf.rad.max())
    if isinstance(sdf, RoundBox):
        return sdf.c, float(np.linalg.norm(sdf.half))
    if isinstance(sdf, RoundCone):
        return (sdf.a + sdf.b) / 2, math.sqrt(sdf.l2) / 2 + max(sdf.r1, sdf.r2)
    if isinstance(sdf, Torus):
        return sdf.c, sdf.major + sdf.minor
    return sdf.c, sdf.radius


# ------------------------------------------------------------------ v1: the handheld tool
TOOL1_PACK_FWD = np.array([0.0, 0.22, 1.0])
TOOL1_HOLD = np.array([4.8, 3.0, 3.7])            # close in, elbow bent: a relaxed carry
TOOL1_HOLD_FWD = np.array([-0.08, 1.0, -0.22])
TOOL1_AIM = np.array([4.2, 6.6, 4.6])
TOOL1_AIM_FWD = np.array([-0.08, 1.0, -0.26])
TOOL_K = 1.35                                     # overall size of the v1 tool


def _frame_from(fwd, up_hint):
    fwd = nz(fwd)
    up = np.asarray(up_hint, float) - (np.asarray(up_hint, float) @ fwd) * fwd
    if np.linalg.norm(up) < 1e-3:
        up = np.array([0.0, -1.0, 0.0]) - (np.array([0.0, -1.0, 0.0]) @ fwd) * fwd
    up = nz(up)
    return fwd, up, np.cross(fwd, up)


def tool_parts_v1(grip, fwd, up_hint, open_, lit):
    """The v1 multitool: a glossy white body over a dark grip, a glowing status strip on top,
    and a dark emitter head with a coral collar, a big lens and three claw prongs that fan open
    when it powers up. Built around the point where the hand holds it."""
    k = TOOL_K
    fwd, up, side = _frame_from(fwd, up_hint)
    Rb = np.stack([side, fwd, up], axis=1)
    Rd = np.stack([fwd, side, up], axis=1)
    Rr = np.stack([side, up, fwd], axis=1)
    body_c = grip + (fwd * 3.0 + up * 0.85) * k
    head_c = grip + (fwd * 6.4 + up * 0.85) * k
    lens_c = head_c + fwd * 1.0 * k
    parts = [
        Part('tbody', RoundBox(body_c, np.array([1.25, 3.1, 1.3]) * k, 1.0 * k, Rb), 'tool', 'tool'),
        Part('tback', RoundBox(grip + (-fwd * 0.4 + up * 0.85) * k, np.array([1.05, 0.7, 1.05]) * k, 0.6 * k, Rb),
             'coral', 'tool'),
        Part('tgrip', RoundCone(grip + (up * 0.35 - fwd * 0.1) * k, grip + (-up * 1.8 - fwd * 0.7) * k, 0.85 * k, 0.72 * k),
             'dark', 'tool'),
        Part('tstrip', RoundBox(grip + (fwd * 2.8 + up * 2.2) * k, np.array([0.42, 2.0, 0.38]) * k, 0.32 * k, Rb),
             'teal' if lit else 'dark', 'tool'),
        Part('thead', Disc(head_c, 2.0 * k, 0.95 * k, 0.5 * k, Rd), 'dark', 'tool'),
        Part('tring', Torus(head_c + fwd * 0.5 * k, 1.95 * k, 0.45 * k, Rr), 'coral', 'tool'),
        Part('lens', Sphere(lens_c, 1.25 * k), 'lens' if lit else 'lensoff', 'tool'),
    ]
    for j in range(3):
        a = math.radians(90 + 120 * j)
        radial = up * math.sin(a) + side * math.cos(a)
        root = head_c + (radial * 1.55 - fwd * 0.2) * k
        tip = root + (radial * (0.15 + 1.0 * open_) + fwd * (0.8 + 1.4 * open_)) * k
        parts.append(Part('prong', RoundCone(root, tip, 0.5 * k, 0.32 * k), 'tool', 'tool'))
    return parts, lens_c


# ================================================================== rig
def two_bone(root, target, l1, l2, pole):
    d = target - root
    dist = float(np.linalg.norm(d))
    u = d / max(dist, 1e-6)
    dist = min(dist, (l1 + l2) * 0.999)
    end = root + u * dist
    ca = (l1 * l1 + dist * dist - l2 * l2) / (2 * l1 * dist)
    ca = min(max(ca, -1.0), 1.0)
    sa = math.sqrt(1 - ca * ca)
    w = pole - (pole @ u) * u
    w = w / max(np.linalg.norm(w), 1e-6)
    mid = root + l1 * (ca * u + sa * w)
    return mid, end


def arm_fk(side, swing, abduct, bend):
    """Returns shoulder, elbow, wrist in torso frame."""
    sx = 1.0 if side == 'R' else -1.0
    S = SHOULDER * np.array([sx, 1, 1])
    down = np.array([0.0, 0.0, -1.0])
    Ra = ry(-sx * abduct)
    up_dir = rx(swing) @ Ra @ down
    fo_dir = rx(swing + bend) @ Ra @ down
    E = S + UPPER * up_dir
    W = E + FORE * fo_dir
    return S, E, W


def base_pose():
    return dict(
        pelvis=np.array([0.0, 0.0, STAND_Z]),
        pelvis_rot=(0.0, 0.0, 0.0),
        torso_rot=(0.0, 0.0, 0.0),
        head_rot=(0.0, 0.0, 0.0),
        head_off=np.zeros(3),
        feet={'L': (np.array([-2.9, 0.0, ANKLE_H]), 0.0, -0.10),
              'R': (np.array([2.9, 0.0, ANKLE_H]), 0.0, 0.10)},
        arms={'L': ('fk', 0.0, 0.18, 0.25), 'R': ('fk', 0.0, 0.18, 0.25)},
        antenna=(0.0, 0.0),
        bulb=1.0,
        tool=dict(where='pack', open=0.0, lit=False),
    )


def build_parts(pose):
    pel = np.asarray(pose['pelvis'], float)
    Rp = euler(*pose['pelvis_rot'])
    Rt = Rp @ euler(*pose['torso_rot'])
    Rh = Rt @ euler(*pose['head_rot'])

    def tp(v):
        return pel + Rt @ np.asarray(v, float)

    parts = []
    # --- body
    parts.append(Part('hips', RoundBox(pel + Rp @ np.array([0, 0, -0.6]), (4.5, 3.4, 2.5), 2.2, Rp),
                      'suit', 'body', blend='body'))
    parts.append(Part('torso', RoundBox(tp((0, 0, 5.0)), (5.6, 4.0, 4.9), 3.0, Rt),
                      'suit', 'body', blend='body', decal=decal_torso))
    parts.append(Part('collar', Torus(tp((0, 0, 9.9)), 3.7, 1.35, Rt), 'coral', 'body'))
    parts.append(Part('pack', RoundBox(tp((0, -5.4, 5.6)), (4.6, 2.2, 4.5), 1.8, Rt),
                      'pack', 'pack', decal=decal_pack))

    # --- head
    neck = tp((0, 0, NECK_Z)) + pose['head_off']
    hc = neck + Rh @ HELMET_OFF
    parts.append(Part('helmet', Ellipsoid(hc, HELMET_R, Rh), 'suit', 'head', decal=decal_helmet))
    for sx in (-1.0, 1.0):
        parts.append(Part('ear', Disc(hc + Rh @ np.array([sx * 8.6, 0.2, 0.3]), 2.6, 1.25, 0.6, Rh),
                          'coral', 'head'))
    ax_, ay_ = pose['antenna']
    stalk_base = hc + Rh @ np.array([9.4, 0.0, 2.3])
    stalk_tip = hc + Rh @ np.array([10.8 + ax_, -0.4 + ay_, 8.2])
    parts.append(Part('bulb', Sphere(stalk_tip, 1.35), 'bulb', 'bulb', emissive=True))

    # --- arms
    for side in 'LR':
        sx = 1.0 if side == 'R' else -1.0
        spec = pose['arms'][side]
        if spec[0] == 'fk':
            S, E, W = arm_fk(side, *spec[1:])
            S, E, W = tp(S), tp(E), tp(W)
        else:  # ('ik', target_char_frame, pole_char_frame)
            S = tp(SHOULDER * np.array([sx, 1, 1]))
            E, W = two_bone(S, np.asarray(spec[1], float), UPPER, FORE, np.asarray(spec[2], float))
        hand_dir = nz(W - E)
        g = 'arm' + side
        parts.append(Part('upper' + side, RoundCone(S, E, 2.15, 1.9), 'suit', g, blend=g))
        parts.append(Part('fore' + side, RoundCone(E, W, 1.9, 1.75), 'suit', g, blend=g))
        parts.append(Part('glove' + side, Sphere(W + hand_dir * 0.9, 2.05), 'coral', g, blend=g))
        if side == 'R':
            arm_r = (E, W)

    # --- legs
    for side in 'LR':
        sx = 1.0 if side == 'R' else -1.0
        hip = pel + Rp @ (HIP * np.array([sx, 1, 1]))
        target, fpitch, fyaw = pose['feet'][side]
        target = np.asarray(target, float)
        pole = Rp @ np.array([sx * 0.25, 1.0, 0.0])
        knee, ankle = two_bone(hip, target, THIGH, SHIN, pole)
        g = 'leg' + side
        Rf = rz(fyaw) @ rx(fpitch)
        parts.append(Part('thigh' + side, RoundCone(hip, knee, 2.55, 2.25), 'suit', g, blend=g))
        parts.append(Part('shin' + side, RoundCone(knee, ankle, 2.25, 2.0), 'suit', g, blend=g))
        parts.append(Part('boot' + side, RoundBox(ankle + Rf @ np.array([0, 1.0, -0.4]), (2.25, 3.0, 1.6), 1.35, Rf),
                          'coral', g, blend=g, decal=decal_boot))
    # --- the multitool: a gauntlet on the right forearm, or folded up on the backpack
    tool = pose.get('tool')
    if tool:
        if tool['where'] == 'arm':
            tp_, tip = gauntlet_parts(arm_r[0], arm_r[1], tool['deploy'], tool['lit'], Rt @ np.array([0.0, 0.0, 1.0]))
        elif tool['where'] == 'hand':
            E_, W_ = arm_r
            tp_, tip = tool_parts_v1(W_ + nz(W_ - E_) * 0.9, tool['fwd'], Rt @ np.array([0.0, 0.0, 1.0]), tool['open'], tool['lit'])
        elif TOOL_DESIGN == 'v1':
            tp_, tip = tool_parts_v1(tp(TOOL_PACK), Rt @ TOOL1_PACK_FWD, Rt @ np.array([1.0, 0.0, 0.0]), 0.0, False)
        else:
            tp_, tip = device_parts(tp(TOOL_PACK), Rt @ nz([0.0, 0.22, 1.0]), Rt @ np.array([1.0, 0.0, 0.0]),
                                    Rt @ nz(np.cross([0.0, 0.22, 1.0], [1.0, 0.0, 0.0])))
        parts += tp_
        pose['_tip'] = tip
    return parts, (stalk_base, stalk_tip)


# ================================================================== camera / renderer
class Camera:
    def __init__(self, W=FRAME_W, H=FRAME_H, anchor=ANCHOR, scale=SCALE, pitch=PITCH):
        self.W, self.H, self.ax, self.ay, self.s = W, H, anchor[0], anchor[1], scale
        self.f = np.array([0.0, math.cos(pitch), -math.sin(pitch)])
        self.r = np.array([1.0, 0.0, 0.0])
        self.u = np.array([0.0, math.sin(pitch), math.cos(pitch)])
        jj, ii = np.mgrid[0:H, 0:W]
        sx = ((ii + 0.5 - self.ax) * scale).reshape(-1, 1)
        sy = ((self.ay - (jj + 0.5)) * scale).reshape(-1, 1)
        self.plane = sx * self.r + sy * self.u
        # key light: upper-left, slightly toward the viewer (classic pixel-art lighting)
        self.L = nz(-0.50 * self.r + 0.60 * self.u - 0.62 * self.f)


CAM = Camera()
DIRS = {'N': 0, 'NE': 45, 'E': 90, 'SE': 135, 'S': 180, 'SW': 225, 'W': 270, 'NW': 315}


def march(scene, O, f, t0, t1, eps=0.01, steps=150, factor=0.9):
    t = t0.copy()
    hit = np.zeros(len(O), bool)
    active = np.nonzero(t1 > t0)[0]
    for _ in range(steps):
        if active.size == 0:
            break
        P = O[active] + t[active, None] * f
        d = scene(P)
        t[active] += d * factor
        h = d < eps
        hit[active[h]] = True
        keep = (~h) & (t[active] < t1[active])
        active = active[keep]
    return hit, t


def shadow_test(scene, P, L, steps=48, tmax=40.0):
    t = np.full(len(P), 0.6)
    occ = np.zeros(len(P), bool)
    active = np.arange(len(P))
    for _ in range(steps):
        if active.size == 0:
            break
        Q = P[active] + t[active, None] * L
        d = scene(Q)
        h = d < 0.02
        occ[active[h]] = True
        t[active] += np.maximum(d, 0.05)
        active = active[(~h) & (t[active] < tmax)]
    return occ


def render(parts, compass_deg, stalk=None, bulb=1.0, cam=CAM, center=(0, 0, 19.0), radius=34.0,
           shadows=True, lines=True):
    scene = Scene(parts)
    Ryaw = rz(-compass_deg * D2R)
    fc, rc, uc, Lc = cam.f @ Ryaw, cam.r @ Ryaw, cam.u @ Ryaw, cam.L @ Ryaw
    O = (cam.plane - cam.f * 100.0) @ Ryaw

    oc = O - np.asarray(center)
    b = oc @ fc
    c = np.einsum('ij,ij->i', oc, oc) - radius * radius
    disc = b * b - c
    sq = np.sqrt(np.maximum(disc, 0.0))
    t0 = np.where(disc > 0, -b - sq, 0.0)
    t1 = np.where(disc > 0, -b + sq, -1.0)

    hit, t = march(scene, O, fc, t0, t1)
    H = np.nonzero(hit)[0]
    W_, H_ = cam.W, cam.H
    rgba = np.zeros((H_ * W_, 4), np.uint8)
    depth = np.full(H_ * W_, np.inf)
    group = np.full(H_ * W_, -1)
    ramp_map = np.full(H_ * W_, -1)
    if H.size == 0:
        return rgba.reshape(H_, W_, 4)

    P = O[H] + t[H, None] * fc
    depth[H] = P @ fc

    # normals
    e = 0.04
    n = np.zeros_like(P)
    for k in range(3):
        dv = np.zeros(3)
        dv[k] = e
        n[:, k] = scene(P + dv) - scene(P - dv)
    n /= np.maximum(length(n), 1e-9)[:, None]

    D = scene.dist_all(P)
    mat = np.argmin(D, axis=0)
    group[H] = scene.group_of[mat]

    ramp = np.array([RID[parts[m].ramp] for m in mat])
    for i, p in enumerate(parts):
        if p.decal is not None:
            sel = mat == i
            if sel.any():
                ramp[sel] = p.decal(p, P[sel])

    # --- lighting
    ndl = n @ Lc
    wrap = (ndl + 0.3) / 1.3
    level = (wrap > 0.24).astype(int) + (wrap > 0.55) + (wrap > 0.86)

    # contact occlusion: surfaces hugging a different body part step down one shade
    other = D.copy()
    same = scene.group_of[:, None] == scene.group_of[mat][None, :]
    other[same] = np.inf
    near = other.min(axis=0) < 0.6
    level = np.where(near, level - 1, level)

    head_parts = [p for p in parts if p.group == 'head']
    if shadows and head_parts:
        hid = scene.group_names.index('head')
        lit = (ndl > 0.0) & (scene.group_of[mat] != hid)
        occ = np.zeros(len(P), bool)
        if lit.any():
            occ[lit] = shadow_test(Scene(head_parts), P[lit] + n[lit] * 0.35, Lc)
        level = np.where(occ, level - 1, level)
    level = np.clip(level, 0, 3)

    # --- special materials
    col = np.zeros((len(P), 3), np.uint8)
    for ri, name in enumerate(RAMP_NAMES):
        sel = ramp == ri
        if not sel.any():
            continue
        cols = np.array(RAMP_RGB[ri], np.uint8)
        if name == 'visor':
            helm = next(p for p in parts if p.name == 'helmet')
            q = helm.sdf.local(P[sel]) / HELMET_R
            q /= length(q)[:, None]
            vx = q[:, 0] / VISOR[0]
            vz = (q[:, 2] - VISOR[2]) / VISOR[1]
            # deep glass at the top, a soft teal glow pooling at the bottom edge
            vl = np.where(vz > 0.30, 1, np.where(vz > -0.38, 2, 3))
            vl = np.where(vz < -0.80, 4, vl)
            # stylised "//" glass shine on the upper-left, small cool glint lower-right
            a = math.radians(-35)

            def streak(cx, cz, w, h):
                sx_ = (vx - cx) * math.cos(a) - (vz - cz) * math.sin(a)
                sz_ = (vx - cx) * math.sin(a) + (vz - cz) * math.cos(a)
                return (sx_ / w) ** 2 + (sz_ / h) ** 2 < 1.0

            shine = streak(-0.46, 0.22, 0.15, 0.46) | streak(-0.12, 0.40, 0.08, 0.26)
            glint = ((vx - 0.58) / 0.14) ** 2 + ((vz + 0.45) / 0.2) ** 2 < 1.0
            vl = np.where(shine, 5, vl)
            vl = np.where(glint, 4, vl)
            col[sel] = cols[vl]
        elif name == 'lens':
            lv = np.where(ndl[sel] > 0.2, 3, 2)
            col[sel] = cols[lv]
        elif name in ('gun', 'armor', 'gold'):           # polished armour: a hard specular edge
            R_ = fc - 2.0 * (n[sel] @ fc)[:, None] * n[sel]
            lv = np.clip(level[sel] + ((R_ @ Lc) > 0.9), 0, 3)
            col[sel] = cols[lv]
        elif name == 'bulb':
            lv = np.where(ndl[sel] > 0.45, 3, 2)
            lv = np.clip(lv - int(round((1.0 - bulb) * 2)), 0, 3)
            col[sel] = cols[lv]
        else:
            col[sel] = cols[level[sel]]
    # tiny specular glint on the helmet shell
    helm_px = (ramp == RID['suit']) & (np.array([parts[m].name for m in mat]) == 'helmet')
    if helm_px.any():
        R = fc - 2.0 * (n @ fc)[:, None] * n
        glint = helm_px & ((R @ Lc) > 0.975)
        col[glint] = (255, 255, 255)
    ramp_map[H] = ramp
    rgba[H, :3] = col
    rgba[H, 3] = 255

    img = rgba.reshape(H_, W_, 4)
    dep = depth.reshape(H_, W_)
    grp = group.reshape(H_, W_)
    rmap = ramp_map.reshape(H_, W_)
    filled = img[:, :, 3] > 0

    # --- inner lines: farther surface next to a nearer, different body part
    if lines:
        line = np.zeros_like(filled)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            nd = np.full_like(dep, np.inf)
            ng = np.full_like(grp, -1)
            ys = slice(max(dy, 0), H_ + min(dy, 0))
            yd = slice(max(-dy, 0), H_ + min(-dy, 0))
            xs = slice(max(dx, 0), W_ + min(dx, 0))
            xd = slice(max(-dx, 0), W_ + min(-dx, 0))
            nd[yd, xd] = dep[ys, xs]
            ng[yd, xd] = grp[ys, xs]
            line |= filled & (ng >= 0) & (ng != grp) & (nd < dep - 1.2)
        line &= rmap != RID['visor']
        ys, xs = np.nonzero(line)
        for y, x in zip(ys, xs):
            img[y, x, :3] = RAMP_RGB[rmap[y, x]][0]

    # --- outline
    pad = np.pad(filled, 1)
    nb = pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]
    out = nb & ~filled
    oc_ = hex2rgb(OUTLINE)
    img[out, 0], img[out, 1], img[out, 2], img[out, 3] = oc_[0], oc_[1], oc_[2], 255

    # --- antenna stalk (1px line, depth tested)
    if stalk is not None:
        a, b = stalk
        pa = np.array([cam.ax + a @ rc / cam.s, cam.ay - a @ uc / cam.s, a @ fc])
        pb = np.array([cam.ax + b @ rc / cam.s, cam.ay - b @ uc / cam.s, b @ fc])
        steps = int(max(abs(pb[0] - pa[0]), abs(pb[1] - pa[1])) * 2) + 1
        sc = hex2rgb(STALK)
        for k in range(steps + 1):
            p = pa + (pb - pa) * (k / steps)
            x, y = int(math.floor(p[0])), int(math.floor(p[1]))
            if 0 <= x < W_ and 0 <= y < H_:
                if grp[y, x] == scene.group_names.index('bulb'):
                    continue
                if not filled[y, x] or p[2] < dep[y, x] - 0.3:
                    img[y, x, :3] = sc
                    img[y, x, 3] = 255
    return img


# ================================================================== animations
def foot_cycle(u, S, beta, lift, strike, off, kick=1.0):
    """Ankle (y, z) and pitch for one foot over a gait cycle, u in [0,1)."""
    if u < beta:                                   # stance: planted, sliding back at body speed
        s = u / beta
        y = S / 2 - S * s
        z = 0.0
        if s < 0.2:
            pitch = strike * (1 - ease(s / 0.2))
        elif s > 0.62:
            pitch = -off * ease((s - 0.62) / 0.38)
        else:
            pitch = 0.0
    else:                                          # swing: lift, carry forward, prepare strike
        s = (u - beta) / (1 - beta)
        y = -S / 2 + S * ease(s) ** kick
        z = lift * math.sin(math.pi * s ** (1.0 / (1.0 + 0.45 * (kick - 1.0)))) if kick != 1.0 \
            else lift * math.sin(math.pi * s)
        pitch = lerp(-off, strike, ease(s))
    z += TOE * math.sin(-pitch) if pitch < 0 else HEEL * math.sin(pitch)
    return y, ANKLE_H + z, pitch


def pelvis_reach(pelvis_z, feet, stance):
    """Lower the pelvis if a planted foot could not be reached."""
    z = pelvis_z
    for side, (pos, _, _) in feet.items():
        if not stance[side]:
            continue
        sx = 1.0 if side == 'R' else -1.0
        hx, hy = sx * HIP[0], HIP[1]
        dx, dy = pos[0] - hx, pos[1] - hy
        h2 = (LEG_MAX * 0.995) ** 2 - dx * dx - dy * dy
        if h2 > 0:
            z = min(z, pos[2] + math.sqrt(h2) - HIP[2])
    return z


def pose_idle(t):
    p = base_pose()
    breath = 0.5 - 0.5 * math.cos(TAU * t)
    lag = 0.5 - 0.5 * math.cos(TAU * (t - 0.09))
    p['pelvis'] = np.array([0.0, 0.0, STAND_Z - 0.45 + 0.55 * breath])
    p['torso_rot'] = (0.0, 0.03 - 0.035 * breath, 0.0)
    p['head_off'] = np.array([0.0, 0.0, 0.55 * lag - 0.25])
    p['head_rot'] = (0.05 * math.sin(TAU * t), -0.02 + 0.03 * lag, 0.045 * math.sin(TAU * t + 0.6))
    for side, sx in (('L', -1), ('R', 1)):
        p['arms'][side] = ('fk', 0.05 * math.sin(TAU * t + (0 if sx > 0 else 1.2)),
                           0.20 + 0.06 * breath, 0.30 + 0.12 * lag)
    p['antenna'] = (0.9 * math.sin(TAU * (t - 0.16)), 0.35 * math.cos(TAU * (t - 0.16)))
    # a slow double-blink of the beacon near the end of the loop
    blink = {11: 0.5, 12: 0.0, 13: 0.5, 14: 1.0}.get(int(round(t * 16)) % 16, 1.0)
    p['bulb'] = blink
    return p


def gait_pose(t, S, beta, lift, strike, off, kick, base_z, bob, bob_phase, lean, arm_swing,
              arm_bend, arm_bend_var, arm_abduct, hip_yaw, chest_yaw, sway, head_lag, ant_back):
    p = base_pose()
    feet, stance = {}, {}
    for side, ph in (('L', 0.0), ('R', 0.5)):
        sx = 1.0 if side == 'R' else -1.0
        u = (t + ph) % 1.0
        y, z, pitch = foot_cycle(u, S, beta, lift, strike, off, kick)
        feet[side] = (np.array([sx * 2.85, y, z]), pitch, sx * 0.06)
        stance[side] = u < beta
    p['feet'] = feet
    nominal = base_z + bob * math.cos(4 * math.pi * (t - bob_phase))
    pz = pelvis_reach(nominal, feet, stance)
    p['pelvis'] = np.array([sway * -math.cos(TAU * (t - beta / 2)), 0.0, pz])
    c = math.cos(TAU * t)
    p['pelvis_rot'] = (-hip_yaw * c, 0.0, -0.025 * math.cos(TAU * (t - beta / 2)))
    p['torso_rot'] = (chest_yaw * c, lean + 0.02 * math.cos(4 * math.pi * (t - bob_phase)), 0.0)
    p['head_rot'] = (-0.6 * chest_yaw * c, -0.4 * lean + 0.03 * math.cos(4 * math.pi * (t - bob_phase - head_lag)), 0.0)
    p['head_off'] = np.array([0.0, 0.0, 0.35 * math.cos(4 * math.pi * (t - bob_phase - head_lag))])
    for side, sgn in (('R', 1.0), ('L', -1.0)):
        sw = sgn * arm_swing * math.cos(TAU * (t - 0.04))
        bend = arm_bend + arm_bend_var * max(0.0, sw / max(arm_swing, 1e-6))
        p['arms'][side] = ('fk', sw, arm_abduct, bend)
    p['antenna'] = (0.35 * math.sin(TAU * (t - 0.1)),
                    -ant_back - 0.6 * math.cos(4 * math.pi * (t - bob_phase - 0.14)))
    return p


WALK_STRIDE, WALK_STANCE = 11.0, 0.56   # a long, brisk stride
RUN_STRIDE, RUN_STANCE = 12.0, 0.38


def pose_walk(t):
    return gait_pose(t, S=WALK_STRIDE, beta=WALK_STANCE, lift=2.8, strike=0.32, off=0.5, kick=1.0,
                     base_z=STAND_Z - 0.6, bob=0.6, bob_phase=0.25, lean=0.07,
                     arm_swing=0.55, arm_bend=0.32, arm_bend_var=0.4, arm_abduct=0.12,
                     hip_yaw=0.10, chest_yaw=0.12, sway=0.35, head_lag=0.08, ant_back=1.0)


def pose_run(t):
    return gait_pose(t, S=RUN_STRIDE, beta=RUN_STANCE, lift=5.0, strike=0.18, off=0.70, kick=1.6,
                     base_z=STAND_Z - 0.9, bob=0.75, bob_phase=0.44, lean=0.24,
                     arm_swing=0.85, arm_bend=1.45, arm_bend_var=0.25, arm_abduct=0.18,
                     hip_yaw=0.16, chest_yaw=0.2, sway=0.2, head_lag=0.1, ant_back=2.6)


RUNG = 6.0                 # ladder rung spacing (world units == px)
CLIMB_RISE = 2 * RUNG      # body rise per cycle
HAND_TOP = 26.0
FOOT_TOP = HAND_TOP - 3 * RUNG + 1.2   # foot rests 1.2 above the rung it stands on


def climb_limb(u, top, hold=0.56, away=1.6):
    if u < hold:                      # gripping: fixed to the ladder, slides down vs body
        return top - CLIMB_RISE * u, 0.0
    s = (u - hold) / (1 - hold)       # reaching: arc back up, pulled off the ladder
    bottom = top - CLIMB_RISE * hold
    return lerp(bottom, top, ease(s)), away * math.sin(math.pi * s)


def pose_climb(t):
    p = base_pose()
    p['pelvis'] = np.array([0.35 * math.sin(TAU * t), -0.3, STAND_Z + 0.2 + 0.35 * math.sin(4 * math.pi * t)])
    p['pelvis_rot'] = (0.06 * math.sin(TAU * t), 0.04, 0.05 * math.sin(TAU * t))
    p['torso_rot'] = (-0.08 * math.sin(TAU * t), 0.05, -0.06 * math.sin(TAU * t))
    p['head_rot'] = (0.05 * math.sin(TAU * t), -0.10, 0.04 * math.sin(TAU * t))
    p['head_off'] = np.array([0.0, 0.0, 0.25 * math.sin(4 * math.pi * (t - 0.08))])
    for side, ph in (('L', 0.0), ('R', 0.5)):
        sx = 1.0 if side == 'R' else -1.0
        z, away = climb_limb((t + ph) % 1.0, HAND_TOP)
        target = np.array([sx * 9.3, 3.0 - away, z])
        p['arms'][side] = ('ik', target, np.array([sx * 1.0, -0.4, -0.7]))
    for side, ph in (('R', 0.0), ('L', 0.5)):
        sx = 1.0 if side == 'R' else -1.0
        z, away = climb_limb((t + ph) % 1.0, FOOT_TOP)
        p['feet'][side] = (np.array([sx * 3.2, 2.0 - away, z]), 0.12 * away, sx * 0.05)
    p['antenna'] = (0.6 * math.sin(TAU * (t - 0.12)), -0.5 + 0.5 * math.sin(4 * math.pi * (t - 0.2)))
    return p


# Jump key poses. The game picks frames from the jump physics (see JUMP_PHASES), so each
# frame is a pose rather than a time step. Airborne poses are drawn relative to the
# ground anchor; the game lifts the whole sprite by the jump height.
#   pz: pelvis offset  tp: torso pitch  hz: helmet lag  arm: (swing, abduct, bend)
#   feet: (x, y, lift, pitch) with an extra lift on one foot for asymmetry  ant: antenna lag
JUMP_KEYS = [
    dict(pz=-2.0, tp=0.22, hp=0.06, hz=-0.5, arm=(-0.55, 0.16, 0.45), feet=(2.9, 0.0, 0.0, 0.0, 0.0), ant=(0.0, 0.8)),
    dict(pz=-3.0, tp=0.30, hp=0.08, hz=-0.8, arm=(-0.95, 0.18, 0.55), feet=(2.9, 0.0, 0.0, 0.0, 0.0), ant=(0.0, 1.4)),
    dict(pz=0.9, tp=-0.04, hp=-0.10, hz=0.5, arm=(2.3, 0.25, 0.25), feet=(2.6, -0.4, 1.4, -0.65, 0.0), ant=(0.0, -1.6)),
    dict(pz=0.4, tp=0.0, hp=-0.12, hz=0.3, arm=(2.0, 0.35, 0.35), feet=(2.4, -0.2, 3.0, -0.45, 0.4), ant=(0.2, -1.8)),
    dict(pz=0.0, tp=0.04, hp=-0.08, hz=0.1, arm=(1.5, 0.55, 0.4), feet=(2.6, 0.4, 4.0, -0.25, 0.5), ant=(0.4, -1.2)),
    dict(pz=0.0, tp=0.02, hp=-0.04, hz=0.0, arm=(0.7, 1.05, 0.35), feet=(3.4, 0.6, 3.6, -0.1, 0.6), ant=(0.8, -0.2)),
    dict(pz=0.1, tp=0.0, hp=-0.02, hz=0.15, arm=(0.55, 1.15, 0.3), feet=(3.6, 0.3, 3.4, 0.0, 0.0), ant=(0.0, 0.4)),
    dict(pz=0.0, tp=0.02, hp=-0.04, hz=0.05, arm=(0.7, 1.05, 0.35), feet=(3.4, 0.0, 3.6, -0.05, -0.6), ant=(-0.8, -0.1)),
    dict(pz=-0.2, tp=0.06, hp=0.02, hz=-0.1, arm=(1.1, 0.8, 0.3), feet=(3.0, 0.2, 2.0, 0.05, 0.3), ant=(0.0, 1.2)),
    dict(pz=0.3, tp=0.08, hp=0.04, hz=-0.2, arm=(1.4, 0.6, 0.25), feet=(3.0, 0.4, 0.8, 0.2, 0.0), ant=(0.0, 1.8)),
    dict(pz=-3.2, tp=0.32, hp=0.10, hz=-1.0, arm=(0.55, 0.55, 0.7), feet=(3.2, 0.2, 0.0, 0.0, 0.0), ant=(0.0, 2.2)),
    dict(pz=-1.3, tp=0.14, hp=0.04, hz=-0.3, arm=(0.15, 0.3, 0.4), feet=(3.0, 0.0, 0.0, 0.0, 0.0), ant=(0.0, 0.6)),
]
JUMP_PHASES = {'crouch': [0, 1], 'takeoff': [2], 'rise': [3, 4], 'apex': [5, 6, 7], 'fall': [8, 9], 'land': [10, 11]}


def pose_jump(t):
    k = JUMP_KEYS[int(round(t * len(JUMP_KEYS))) % len(JUMP_KEYS)]
    p = base_pose()
    p['pelvis'] = np.array([0.0, 0.0, STAND_Z + k['pz']])
    p['torso_rot'] = (0.0, k['tp'], 0.0)
    p['head_rot'] = (0.0, k['hp'], 0.0)
    p['head_off'] = np.array([0.0, 0.0, k['hz']])
    swing, abduct, bend = k['arm']
    p['arms'] = {'L': ('fk', swing, abduct, bend), 'R': ('fk', swing * 0.94, abduct * 1.05, bend)}
    fx, fy, lift, pitch, skew = k['feet']
    p['feet'] = {'L': (np.array([-fx, fy, ANKLE_H + lift + max(skew, 0.0)]), pitch, -0.10),
                 'R': (np.array([fx, fy, ANKLE_H + lift + max(-skew, 0.0)]), pitch, 0.10)}
    p['antenna'] = k['ant']
    return p


def with_tool(p, hand, deploy=1.0, lit=True, pole=(1.0, -0.35, -0.8)):
    """Arm out with the gauntlet on: the wrist goes to a torso-frame point (IK), the elbow
    hangs out and back; the gauntlet follows the forearm."""
    Rt = euler(*p['pelvis_rot']) @ euler(*p['torso_rot'])
    pel = np.asarray(p['pelvis'], float)
    p['arms']['R'] = ('ik', pel + Rt @ np.asarray(hand, float), Rt @ np.array(pole))
    p['tool'] = dict(where='arm', deploy=deploy, lit=lit)
    return p


def pose_idle_tool(t):
    breath = 0.5 - 0.5 * math.cos(TAU * t)
    p = pose_idle(t)
    return with_tool(p, TOOL_HOLD + np.array([0.0, 0.12 * math.sin(TAU * t), 0.35 * breath - 0.15]))


def pose_walk_tool(t):
    p = pose_walk(t)
    return with_tool(p, TOOL_HOLD + np.array([0.0, 0.3 * math.sin(TAU * t), 0.3 * math.cos(4 * math.pi * (t - 0.3))]))


def pose_run_tool(t):
    p = pose_run(t)
    return with_tool(p, np.array([8.4, 2.4, 5.4]) + np.array([0.0, 0.4 * math.sin(TAU * t), 0.45 * math.cos(4 * math.pi * (t - 0.4))]))


def pose_jump_tool(t):
    k = JUMP_KEYS[int(round(t * len(JUMP_KEYS))) % len(JUMP_KEYS)]
    p = pose_jump(t)
    lift = float(np.clip(k['arm'][0] * 0.55, -0.6, 1.3))          # rides up with the arm swing
    return with_tool(p, TOOL_HOLD + np.array([0.3, 0.2, 0.6 + lift]))


def pose_use(t):
    """Working: feet planted wide, leaning in, the gauntlet out at arm's length with a little
    kick on each pulse; the left hand comes up to steady the right forearm."""
    p = base_pose()
    pulse = max(0.0, math.sin(TAU * t)) ** 2
    p['pelvis'] = np.array([0.3, -0.2, STAND_Z - 0.8 + 0.15 * math.sin(TAU * t)])
    p['pelvis_rot'] = (-0.06, 0.0, 0.0)
    p['torso_rot'] = (0.05, 0.1 - 0.03 * pulse, 0.0)
    p['head_rot'] = (0.02, 0.06, 0.0)
    p['head_off'] = np.array([0.0, 0.0, -0.15 - 0.1 * pulse])
    p['feet'] = {'L': (np.array([-3.4, 2.0, ANKLE_H]), 0.0, -0.16),
                 'R': (np.array([3.1, -1.6, ANKLE_H]), 0.0, 0.2)}
    Rt = euler(*p['pelvis_rot']) @ euler(*p['torso_rot'])
    pel = np.asarray(p['pelvis'], float)
    p['arms']['L'] = ('ik', pel + Rt @ np.array([2.0, 5.0, 4.0]), Rt @ np.array([-1.0, -0.2, -0.8]))
    p['antenna'] = (0.4 * math.sin(TAU * t), 0.6 + 0.4 * pulse)
    return with_tool(p, TOOL_AIM - np.array([0.0, 0.5 * pulse, -0.12 * pulse]))


REST_R = arm_fk('R', 0.0, 0.2, 0.3)[2]
# Equip, as key poses (played in reverse to put the tool away): reach back to the backpack,
# take the folded device, bring it up in front of the chest, it bursts open into a ring of
# plates, the plates fly onto the forearm and lock, the emitter lights, settle at the ready.
EQUIP_KEYS = [
    dict(hand=REST_R * 0.45 + TOOL_PACK_WRIST * 0.55 + np.array([0.5, 0.0, 0.8]), held=False, yaw=-0.08, look=-0.1),
    dict(hand=TOOL_PACK_WRIST, held=False, yaw=-0.16, look=-0.22),
    dict(hand=TOOL_PACK_WRIST + np.array([0.4, 2.0, 2.6]), held=True, deploy=0.0, yaw=-0.1, look=-0.12),
    dict(hand=np.array([4.4, 5.2, 7.4]), held=True, deploy=0.18, yaw=0.08, look=0.1),
    dict(hand=np.array([4.6, 5.6, 7.8]), held=True, deploy=0.42, yaw=0.1, look=0.16),
    dict(hand=np.array([5.4, 5.8, 7.0]), held=True, deploy=0.62, yaw=0.08, look=0.12),
    dict(hand=np.array([7.4, 5.0, 6.0]), held=True, deploy=0.85, yaw=0.04, look=0.06),
    dict(hand=np.array([8.6, 4.0, 5.3]), held=True, deploy=1.0, yaw=0.0, look=0.02),
    dict(hand=TOOL_HOLD, held=True, deploy=1.0, yaw=0.0, look=0.0),
]
EQUIP_FRAMES = 18                 # in-betweens over the key poses, eased
EQUIP_LIT_AT = 6.5                # key position where the emitter lights


def equip_u(i):
    """Key-pose position (0 .. keys-1) of equip frame i: eased in and out."""
    x = i / (EQUIP_FRAMES - 1)
    x = x * x * (3 - 2 * x) * 0.3 + x * 0.7
    return x * (len(EQUIP_KEYS) - 1)


def pose_equip(t):
    u = equip_u(int(round(t * EQUIP_FRAMES)) % EQUIP_FRAMES)
    a = min(int(u), len(EQUIP_KEYS) - 2)
    f = u - a
    k0, k1 = EQUIP_KEYS[a], EQUIP_KEYS[a + 1]
    s_ = f * f * (3 - 2 * f)
    p = pose_idle(0.0)
    p['torso_rot'] = (lerp(k0['yaw'], k1['yaw'], s_), p['torso_rot'][1] + 0.03, 0.0)
    p['head_rot'] = (lerp(k0['look'], k1['look'], s_), -0.04, 0.0)
    hand = lerp(np.asarray(k0['hand']), np.asarray(k1['hand']), s_)
    held = k1['held'] if f >= 0.5 else k0['held']
    if held:
        dep = lerp(k0.get('deploy', 0.0), k1.get('deploy', 0.0), f)
        return with_tool(p, hand, dep, u >= EQUIP_LIT_AT, pole=(0.9, -0.6, -0.7))
    Rt = euler(*p['pelvis_rot']) @ euler(*p['torso_rot'])
    pel = np.asarray(p['pelvis'], float)
    p['arms']['R'] = ('ik', pel + Rt @ hand, Rt @ np.array([0.9, 0.2, -1.0]))
    return p


# ------------------------------------------------------------------ v1 poses: the handheld tool
def with_tool_v1(p, hand, fwd, open_=1.0, lit=True):
    Rt = euler(*p['pelvis_rot']) @ euler(*p['torso_rot'])
    pel = np.asarray(p['pelvis'], float)
    p['arms']['R'] = ('ik', pel + Rt @ np.asarray(hand, float), Rt @ np.array([0.7, -0.35, -1.0]))
    p['tool'] = dict(where='hand', fwd=Rt @ nz(fwd), open=open_, lit=lit)
    return p


def pose_idle_tool_v1(t):
    breath = 0.5 - 0.5 * math.cos(TAU * t)
    return with_tool_v1(pose_idle(t), TOOL1_HOLD + np.array([0.0, 0.1 * math.sin(TAU * t), 0.35 * breath - 0.15]),
                        TOOL1_HOLD_FWD + np.array([0.0, 0.0, 0.04 * math.sin(TAU * t + 0.8)]))


def pose_walk_tool_v1(t):
    return with_tool_v1(pose_walk(t), TOOL1_HOLD + np.array([0.0, 0.25 * math.sin(TAU * t), 0.3 * math.cos(4 * math.pi * (t - 0.3))]),
                        TOOL1_HOLD_FWD + np.array([0.0, 0.0, 0.05 * math.cos(4 * math.pi * (t - 0.35))]))


def pose_run_tool_v1(t):
    return with_tool_v1(pose_run(t), np.array([5.0, 2.4, 4.8]) + np.array([0.0, 0.3 * math.sin(TAU * t), 0.45 * math.cos(4 * math.pi * (t - 0.4))]),
                        np.array([-0.05, 1.0, 0.1 + 0.06 * math.cos(4 * math.pi * (t - 0.45))]))


def pose_jump_tool_v1(t):
    k = JUMP_KEYS[int(round(t * len(JUMP_KEYS))) % len(JUMP_KEYS)]
    lift = float(np.clip(k['arm'][0] * 0.55, -0.6, 1.3))
    return with_tool_v1(pose_jump(t), TOOL1_HOLD + np.array([0.15, 0.2, 0.6 + lift]), TOOL1_HOLD_FWD + np.array([0.0, 0.0, 0.1 * lift]))


def pose_use_v1(t):
    p = pose_use(t)
    pulse = max(0.0, math.sin(TAU * t)) ** 2
    p['arms']['L'] = ('fk', 0.45, 0.32, 0.85)
    return with_tool_v1(p, TOOL1_AIM - np.array([0.0, 0.45 * pulse, -0.12 * pulse]),
                        TOOL1_AIM_FWD + np.array([0.0, 0.0, 0.05 * pulse]))


EQUIP_KEYS_V1 = [
    dict(hand=REST_R * 0.45 + TOOL_PACK_WRIST * 0.55 + np.array([0.5, 0.0, 0.8]), held=False, yaw=-0.08, look=-0.1),
    dict(hand=TOOL_PACK_WRIST, held=False, yaw=-0.16, look=-0.22),
    dict(hand=TOOL_PACK_WRIST + np.array([0.4, 1.4, 2.4]), held=True, fwd=(0.1, 0.3, 1.0), open_=0.0, yaw=-0.12, look=-0.16),
    dict(hand=np.array([5.3, 3.0, 6.3]), held=True, fwd=(0.0, 0.8, 0.62), open_=0.0, yaw=-0.04, look=-0.05),
    dict(hand=np.array([4.8, 4.6, 4.9]), held=True, fwd=(-0.05, 1.0, 0.14), open_=0.35, yaw=0.02, look=0.02),
    dict(hand=np.array([4.8, 3.9, 4.0]), held=True, fwd=(-0.06, 1.0, -0.06), open_=0.85, yaw=0.01, look=0.04),
    dict(hand=np.array([4.8, 3.2, 3.4]), held=True, fwd=(-0.08, 1.0, -0.26), open_=1.0, yaw=0.0, look=0.02),
    dict(hand=TOOL1_HOLD, held=True, fwd=TOOL1_HOLD_FWD, open_=1.0, yaw=0.0, look=0.0),
]
EQUIP_FRAMES_V1 = 12
EQUIP_LIT_AT_V1 = 4.5


def equip_u_v1(i):
    x = i / (EQUIP_FRAMES_V1 - 1)
    x = x * x * (3 - 2 * x) * 0.35 + x * 0.65
    return x * (len(EQUIP_KEYS_V1) - 1)


def pose_equip_v1(t):
    u = equip_u_v1(int(round(t * EQUIP_FRAMES_V1)) % EQUIP_FRAMES_V1)
    a = min(int(u), len(EQUIP_KEYS_V1) - 2)
    f = u - a
    k0, k1 = EQUIP_KEYS_V1[a], EQUIP_KEYS_V1[a + 1]
    s_ = f * f * (3 - 2 * f)
    p = pose_idle(0.0)
    p['torso_rot'] = (lerp(k0['yaw'], k1['yaw'], s_), p['torso_rot'][1] + 0.03, 0.0)
    p['head_rot'] = (lerp(k0['look'], k1['look'], s_), -0.04, 0.0)
    hand = lerp(np.asarray(k0['hand']), np.asarray(k1['hand']), s_)
    held = k1['held'] if f >= 0.5 else k0['held']
    if held:
        f0 = np.asarray(k0.get('fwd', k1.get('fwd')), float)
        f1 = np.asarray(k1.get('fwd', f0), float)
        return with_tool_v1(p, hand, nz(lerp(nz(f0), nz(f1), s_)), lerp(k0.get('open_', 0.0), k1.get('open_', 0.0), s_),
                            u >= EQUIP_LIT_AT_V1)
    Rt = euler(*p['pelvis_rot']) @ euler(*p['torso_rot'])
    pel = np.asarray(p['pelvis'], float)
    p['arms']['R'] = ('ik', pel + Rt @ hand, Rt @ np.array([0.9, 0.2, -1.0]))
    return p


V1 = TOOL_DESIGN == 'v1'
ALL8 = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW']
ANIMS = {
    'idle':  dict(frames=16, fps=8,  fn=pose_idle,  dirs=ALL8, loop=True),
    'walk':  dict(frames=12, fps=12, fn=pose_walk,  dirs=ALL8, loop=True),
    'run':   dict(frames=10, fps=15, fn=pose_run,   dirs=ALL8, loop=True),
    'climb': dict(frames=12, fps=12, fn=pose_climb, dirs=['N', 'NE', 'NW'], loop=True),
    'jump':  dict(frames=len(JUMP_KEYS), fps=12, fn=pose_jump, dirs=ALL8, loop=False),
    # with the multitool out
    'equip':      dict(frames=EQUIP_FRAMES_V1 if V1 else EQUIP_FRAMES, fps=22 if V1 else 20,
                       fn=pose_equip_v1 if V1 else pose_equip, dirs=ALL8, loop=False, tool=True),
    'idle_tool':  dict(frames=16, fps=8,  fn=pose_idle_tool_v1 if V1 else pose_idle_tool, dirs=ALL8, loop=True, tool=True),
    'walk_tool':  dict(frames=12, fps=12, fn=pose_walk_tool_v1 if V1 else pose_walk_tool, dirs=ALL8, loop=True, tool=True),
    'run_tool':   dict(frames=10, fps=15, fn=pose_run_tool_v1 if V1 else pose_run_tool, dirs=ALL8, loop=True, tool=True),
    'jump_tool':  dict(frames=len(JUMP_KEYS), fps=12, fn=pose_jump_tool_v1 if V1 else pose_jump_tool, dirs=ALL8,
                       loop=False, tool=True),
    'use':        dict(frames=6, fps=12, fn=pose_use_v1 if V1 else pose_use, dirs=ALL8, loop=True, tool=True),
}


def render_pose(pose, d):
    parts, stalk = build_parts(pose)
    return render(parts, DIRS[d], stalk=stalk, bulb=pose['bulb'])


def tool_tip(pose, d):
    """Pixel position of the multitool's lens in the frame, and whether the body hides it."""
    parts, _ = build_parts(pose)
    tip = pose['_tip']
    Ryaw = rz(-DIRS[d] * D2R)
    fc, rc, uc = CAM.f @ Ryaw, CAM.r @ Ryaw, CAM.u @ Ryaw
    x, y = CAM.ax + tip @ rc / CAM.s, CAM.ay - tip @ uc / CAM.s
    body = Scene([q for q in parts if q.group != 'tool'])
    hit, _ = march(body, (tip - fc * 60.0)[None, :], fc, np.zeros(1), np.array([59.0]))
    return [round(float(x), 1), round(float(y), 1), 0 if hit[0] else 1]


# ================================================================== props for previews
def ladder_parts(scroll):
    parts = []
    for sx in (-1, 1):
        parts.append(Part('rail', RoundBox((sx * 11.2, 5.2, 25.0), (0.8, 0.8, 70.0), 0.5), 'wood', 'ladder'))
    for k in range(-8, 17):
        z = HAND_TOP - 0.8 - 30 + k * RUNG - (scroll % RUNG)
        parts.append(Part('rung', RoundCone((-11.0, 5.0, z), (11.0, 5.0, z), 0.55, 0.55), 'wood', 'ladder'))
    return parts


LADDER_CAM = Camera(W=64, H=112, anchor=(32, 80))   # taller frame so the ladder fills the viewer stage


def render_ladder(d, scroll, cam=CAM):
    return render(ladder_parts(scroll), DIRS[d], cam=cam, center=(0, 0, 25.0), radius=80.0,
                  shadows=False, lines=False)


# ================================================================== output helpers
def over(dst, src):
    a = src[:, :, 3:4].astype(float) / 255.0
    dst[:, :, :3] = (src[:, :, :3] * a + dst[:, :, :3] * (1 - a)).astype(np.uint8)
    dst[:, :, 3] = np.maximum(dst[:, :, 3], src[:, :, 3])
    return dst


def shadow_sprite():
    img = np.zeros((FRAME_H, FRAME_W, 4), np.uint8)
    cx, cy = ANCHOR
    for y in range(FRAME_H):
        for x in range(FRAME_W):
            dx = (x + 0.5 - cx) / 11.5
            dy = (y + 0.5 - cy) / 5.75
            r = dx * dx + dy * dy
            if r <= 1.0:
                img[y, x] = (34, 24, 44, 85 if r > 0.5 else 135)
    return img


BG = hex2rgb('#2b2438')
TILE_TOP = [hex2rgb('#4c4363'), hex2rgb('#574d70')]
TILE_EDGE = hex2rgb('#6d6288')
TILE_SIDE_L, TILE_SIDE_R = hex2rgb('#3a3250'), hex2rgb('#322b46')


def tile_backdrop(w=FRAME_W, h=FRAME_H, ladder=False):
    """A little iso floor tile under the feet, for previews only."""
    img = np.zeros((h, w, 4), np.uint8)
    img[:, :, :3] = BG
    img[:, :, 3] = 255
    if ladder:
        return img
    cx, cy = ANCHOR
    hw, hh, thick = 22, 11, 4
    for y in range(h):
        for x in range(w):
            dx = abs(x + 0.5 - cx) / hw
            top = dx + abs(y + 0.5 - cy) / hh
            if top <= 1.0:                                   # 2:1 diamond top face
                img[y, x, :3] = TILE_TOP[0]
                if top > 0.9:
                    img[y, x, :3] = TILE_EDGE if y < cy else TILE_TOP[1]
            elif y + 0.5 > cy and dx + abs(y + 0.5 - thick - cy) / hh <= 1.0:   # tile thickness
                img[y, x, :3] = TILE_SIDE_L if x < cx else TILE_SIDE_R
    return img


def upscale(img, k):
    return np.repeat(np.repeat(img, k, axis=0), k, axis=1)


# ================================================================== build
def build(quick=False):
    os.makedirs(OUT, exist_ok=True)
    prev_dir = os.path.join(OUT, 'preview')
    os.makedirs(prev_dir, exist_ok=True)
    t_start = time.time()
    frames = {}
    for name, a in ANIMS.items():
        n = a['frames']
        rows = []
        for d in a['dirs']:
            row = []
            for i in range(n):
                if quick and i % max(1, n // 4) != 0:
                    continue
                row.append(render_pose(a['fn'](i / n), d))
            rows.append(row)
        frames[name] = rows
        print(f'{name:6s} {len(rows)}x{len(rows[0])} frames  ({time.time() - t_start:.1f}s)', flush=True)

    # bounds check
    for name, rows in frames.items():
        for r, row in enumerate(rows):
            for c, f in enumerate(row):
                a = f[:, :, 3] > 0
                if a[0].any() or a[-1].any() or a[:, 0].any() or a[:, -1].any():
                    print(f'WARNING: {name} {ANIMS[name]["dirs"][r]} frame {c} touches the frame edge')

    shadow = shadow_sprite()

    # contact sheet (review)
    sheet_rows = []
    for name, rows in frames.items():
        for r, row in enumerate(rows):
            cells = []
            for f in row:
                bg = tile_backdrop(ladder=(name == 'climb'))
                if name != 'climb':
                    over(bg, shadow)
                cells.append(over(bg, f))
            sheet_rows.append(np.concatenate(cells, axis=1))
    wmax = max(r.shape[1] for r in sheet_rows)
    sheet_rows = [np.pad(r, ((0, 0), (0, wmax - r.shape[1]), (0, 0))) for r in sheet_rows]
    contact = np.concatenate(sheet_rows, axis=0)
    Image.fromarray(upscale(contact, 2)).save(os.path.join(prev_dir, 'contact_sheet.png'))
    if quick:
        print('quick contact sheet written')
        return

    # sprite sheets + manifest
    manifest = {
        'name': 'astronaut',
        'tool_design': TOOL_DESIGN,
        'frame_size': [FRAME_W, FRAME_H],
        'anchor': list(ANCHOR),
        'anchor_note': 'Pixel coordinate (from top-left of each frame) of the point between the feet on the ground. '
                       'Place this on the entity\'s ground position.',
        'projection': '2:1 pixel isometric (camera pitch 30 deg, yaw 45 deg to the tile grid)',
        'direction_note': 'Directions are screen-space compass directions. NE/SE/SW/NW run along the iso tile axes '
                          '(2px across : 1px down); N/E/S/W are the screen-aligned in-betweens.',
        'world_unit_px': {'vertical': 1.0, 'horizontal': round(1 / SCALE, 4)},
        'shadow': 'astronaut_shadow.png',
        'animations': {},
    }
    for name, rows in frames.items():
        a = ANIMS[name]
        sheet = np.concatenate([np.concatenate(row, axis=1) for row in rows], axis=0)
        fname = f'astronaut_{name}.png'
        Image.fromarray(sheet).save(os.path.join(OUT, fname))
        info = {
            'file': fname,
            'frames': a['frames'],
            'fps': a['fps'],
            'loop': a['loop'],
            'directions': a['dirs'],
            'layout': 'one row per direction (in the order listed), one column per frame',
        }
        if name == 'walk':
            info['ground_speed_world_per_sec'] = round(WALK_STRIDE / WALK_STANCE * a['fps'] / a['frames'], 3)
        if name == 'run':
            info['ground_speed_world_per_sec'] = round(RUN_STRIDE / RUN_STANCE * a['fps'] / a['frames'], 3)
        if name == 'jump':
            info['phases'] = JUMP_PHASES
            info['note'] = 'Pose set, not a timed loop: pick frames from the jump state (crouch, takeoff, ' \
                           'rise, apex, fall, land) and lift the sprite by the jump height.'
        if name == 'equip' and V1:
            info['lit_frame'] = next(i for i in range(EQUIP_FRAMES_V1) if equip_u_v1(i) >= EQUIP_LIT_AT_V1)
        elif name == 'equip':
            info['lit_frame'] = next(i for i in range(EQUIP_FRAMES) if equip_u(i) >= EQUIP_LIT_AT)
            info['open_frames'] = [next(i for i in range(EQUIP_FRAMES) if equip_u(i) >= 3.0),
                                   next(i for i in range(EQUIP_FRAMES) if equip_u(i) >= 6.0)]
            info['equip_note'] = 'open_frames: from the device bursting open to the plates locking on the arm.'
        if a.get('tool'):
            info['tool_tip'] = [[tool_tip(a['fn'](i / a['frames']), d) for i in range(a['frames'])] for d in a['dirs']]
            info['tool_tip_note'] = 'Per direction, per frame: [x, y, visible] of the multitool lens in frame pixels.'
        if name == 'climb':
            info['climb_speed_px_per_sec'] = round(CLIMB_RISE * a['fps'] / a['frames'], 3)
            info['ladder_rung_spacing_px'] = RUNG
            info['note'] = 'In-place animation: move the entity up the ladder at climb_speed_px_per_sec so the ' \
                           'hands and feet stay locked to the rungs.'
        manifest['animations'][name] = info
    for name in ('walk', 'run'):
        v = manifest['animations'][name]['ground_speed_world_per_sec']
        manifest['animations'][name]['screen_speed_px_per_sec'] = {
            'NE/SE/SW/NW': [round(v * math.sqrt(0.5) / SCALE, 2), round(v * math.sqrt(0.5) * math.sin(PITCH) / SCALE, 2)],
            'E/W': [round(v / SCALE, 2), 0.0],
            'N/S': [0.0, round(v * math.sin(PITCH) / SCALE, 2)],
        }
        manifest['animations'][name]['speed_note'] = 'Move the sprite at these [x, y] px/sec so the planted foot ' \
                                                     'does not slide.'
    Image.fromarray(shadow).save(os.path.join(OUT, 'astronaut_shadow.png'))
    with open(os.path.join(OUT, 'astronaut.json'), 'w') as fh:
        json.dump(manifest, fh, indent=2)

    # scrolling ladder for the climb preview (viewer only, not a game asset)
    climb = ANIMS['climb']
    ladder = np.concatenate([
        np.concatenate([render_ladder(d, CLIMB_RISE * i / climb['frames'], LADDER_CAM)
                        for i in range(climb['frames'])], axis=1)
        for d in climb['dirs']], axis=0)
    Image.fromarray(ladder).save(os.path.join(prev_dir, 'ladder_climb.png'))

    # interactive viewer: template + manifest inlined so it also works straight from disk
    viewer = dict(manifest, preview={
        'ladder': {'file': 'preview/ladder_climb.png', 'frame_size': [LADDER_CAM.W, LADDER_CAM.H],
                   'anchor': [LADDER_CAM.ax, LADDER_CAM.ay]}})
    with open(os.path.join(HERE, 'astronaut_viewer.html'), encoding='utf-8') as fh:
        page = fh.read().replace('__MANIFEST__', json.dumps(viewer))
    with open(os.path.join(OUT, 'viewer.html'), 'w', encoding='utf-8') as fh:
        fh.write('<!doctype html>\n' + page)

    # animated previews (3x, every direction side by side)
    k = 3
    for name, rows in frames.items():
        a = ANIMS[name]
        n = a['frames']
        gif_frames = []
        for i in range(n):
            cells = []
            for r, d in enumerate(a['dirs']):
                if name == 'climb':
                    bg = tile_backdrop(ladder=True)
                    over(bg, render_ladder(d, CLIMB_RISE * i / n))
                else:
                    bg = tile_backdrop()
                    over(bg, shadow)
                cells.append(over(bg, rows[r][i]))
            strip = np.concatenate(cells, axis=1)
            gif_frames.append(Image.fromarray(upscale(strip, k)[:, :, :3]))
        gif_frames[0].save(os.path.join(prev_dir, f'astronaut_{name}.gif'), save_all=True,
                           append_images=gif_frames[1:], duration=int(round(1000 / a['fps'])), loop=0,
                           disposal=1)
    print(f'done in {time.time() - t_start:.1f}s -> {OUT}')


if __name__ == '__main__':
    build(quick='--quick' in sys.argv)
