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
     stepped pits, craters, boulders, spiky mountain ranges - and flattened pads for
     domes, paths and the solar field. Three lands blend into each other with
     domain-warped edges: red dust around the base, an alien forest around the nursery
     (moss, glowing pools, crystal spires) and ice around the comms dome (snowfields,
     frozen lakes, charcoal peaks and cliffs under snow). Near the base, the satellite
     that crashed: its crater and the trench it ploughed, kept apart from the rest.
  2. Terrain: exact per-pixel ray/heightfield hits, solved per screen column with a
     running-max + binary search (no ray stepping), plus the cut-away crust walls.
  3. Light: cel-shaded ramps per land with ordered dithering, patchy dithered seams
     between lands, a sun shadow map, crevice AO, strata bands on cliff faces, rim
     highlights on cliff lips, lamp light pools, plant light on the moss, scorch marks.
  4. Props: SDF models ray-marched straight to pixels. Bases are modelled at design
     size and scaled up by DOME_SCALE as a whole (domes, interiors, airlocks, tower),
     plus the wreck and the ice crystals.
  5. Plants: every forest species is rendered once per variant in 8 sway frames; the
     game draws them as sprites (each sheet carries a depth row so the game can hide
     them behind cliffs). Plants behind dome glass are baked in under the glass.
  6. Glass: back shell, interior, front shell with fresnel tint, ribs and shine.
  7. Lines, glows, haze per land, space backdrop, and the game data: depth map,
     walk/height grid, biome grid, plant sheets, glow points and the crash scene
     (the ground as it was before, the falling satellite, smoke and spark points), and the
     light mask: how much of each pixel is its own light, so it stays lit at night.
  8. Four views: the camera turns round the world in quarter turns (G / H in the game). The
     world is built once; each view is rendered with the world turned about the middle of its
     grid, the sun staying put on screen. View 0 writes the usual files; view k writes the same
     set with a _rk suffix (map, depth, light, fx, minimap, plant and door sheets...). The walk
     and biome grids belong to the world, so there is one of each.
     Image/data exports replace completed files atomically, preserving previews and grids while
     editors/diff viewers hold the previous version open on Windows.

    MAP_VIEWS=0 python tools/mars_map_gen.py     # only some of the views (default 0123)
"""
import contextlib
import gc
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
from solar_layout import apply_terrain, footprints  # authored terraces, approaches and collision

ROOT = os.path.dirname(HERE)
OUT = os.environ.get('MAP_OUT', os.path.join(ROOT, 'assets', 'maps', 'red_planet'))

# ================================================================== camera / scale
DEG = math.pi / 180
TAU = 2.0 * math.pi
PX = 2.0                          # pixels per world unit of height (map pixel density)
S = math.cos(30 * DEG) / PX       # world units per pixel along the camera plane
KY = math.tan(30 * DEG)           # height-equivalent of one unit of depth
SQ2 = math.sqrt(2.0)
N = 2300                          # map side in world units (grid cells are 1 unit)
HALF = N / SQ2
W, H, AX, AY = 0, 0, 0.0, 0.0     # image frame, set by set_frame() once the world is known
F = np.array([0.0, math.cos(30 * DEG), -math.sin(30 * DEG)])
CR = np.array([1.0, 0.0, 0.0])
CU = np.array([0.0, math.sin(30 * DEG), math.cos(30 * DEG)])
SUN = A.nz([-0.62, -0.32, 0.62])  # same quadrant as the sprite light, a little lower for longer shadows
VIEWPORT = (384, 216)             # game view in px (project.godot); no two domes may share one
SEED = 11
# The light mask (red_planet_light.png): for every map pixel, how much of its colour is its own
# light (lamps, lit windows, glowing plants and pools, light pooling round them, the stars) rather
# than sunlight. The game keeps those pixels lit at night. Renderers write into it while it is set.
EMIT = None

# ================================================================== the four views
# The camera turns round the world in quarter turns (G / H in the game). The world is built once,
# in view 0's frame. View k is rendered with the world turned a quarter turn k times about the
# middle of its grid (VIEW_C): view = turn(world - VIEW_C) + VIEW_C. The sun stays put on screen,
# so every view is lit alike. While a view renders, the constants that place things (DOMES,
# PATHS, CRASH, SOLAR, BASE_ROOMS) hold its positions; models are built in view 0's frame (inside
# canonical()) and turned as a whole (turned()), so they show their other sides.
VIEW = 0
VIEWS = [int(c) for c in os.environ.get('MAP_VIEWS', '0123')]
VIEW_C = np.array([0.0, HALF, 0.0])
SFX = ''                          # file-name suffix of the view being written: '' for view 0, '_r1'...


def view_sfx(k):
    return '' if k % 4 == 0 else f'_r{k % 4}'


def _turn2(k):
    """The 2x2 quarter-turn matrix taking view 0's frame to view k's (clockwise seen from above)."""
    c, s_ = [(1, 0), (0, -1), (-1, 0), (0, 1)][k % 4]
    return np.array([[c, -s_], [s_, c]], float)


def to_view(P, k=None):
    """A point (or rows of points) in view 0's frame, as placed in view k."""
    k = VIEW if k is None else k
    out = np.array(P, float, copy=True)
    if k % 4:
        out[..., :2] = (out[..., :2] - VIEW_C[:2]) @ _turn2(k).T + VIEW_C[:2]
    return out


def to_canon(P, k=None):
    """A point placed in view k, back in view 0's frame."""
    k = VIEW if k is None else k
    out = np.array(P, float, copy=True)
    if k % 4:
        out[..., :2] = (out[..., :2] - VIEW_C[:2]) @ _turn2(k) + VIEW_C[:2]
    return out


def vrot(v, k=None):
    """A direction in view 0's frame, as it points in view k (any z is kept)."""
    k = VIEW if k is None else k
    out = np.array(v, float, copy=True)
    if k % 4:
        out[..., :2] = out[..., :2] @ _turn2(k).T
    return out


def crot(v, k=None):
    k = VIEW if k is None else k
    out = np.array(v, float, copy=True)
    if k % 4:
        out[..., :2] = out[..., :2] @ _turn2(k)
    return out


def rot_grid(a, k):
    """A world grid [u, v] as view k lays it out (the grid turns with the world)."""
    return np.ascontiguousarray(np.rot90(a, -(k % 4)))


def rot_window(win, k):
    """A grid window (u0, u1, v0, v1) after rot_grid's turn."""
    u0, u1, v0, v1 = win
    for _ in range(k % 4):
        u0, u1, v0, v1 = v0, v1, N - u1, N - u0
    return u0, u1, v0, v1


class TurnZ:
    """A model built in view 0's frame, seen in view k: turned with the world about a point."""

    def __init__(self, inner, k, about):
        self.inner, self.k, self.about = inner, k % 4, np.asarray(about, float)

    def back(self, P):                                    # view -> the model's frame
        out = np.array(P, float, copy=True)
        out[..., :2] = (out[..., :2] - self.about[:2]) @ _turn2(self.k) + self.about[:2]
        return out

    def fwd(self, P):
        out = np.array(P, float, copy=True)
        out[..., :2] = (out[..., :2] - self.about[:2]) @ _turn2(self.k).T + self.about[:2]
        return out

    def __call__(self, P):
        return self.inner(self.back(P))

    def local(self, P):
        return self.inner.local(self.back(P))

    def __getattr__(self, k):
        if k in ('inner', 'k', 'about'):
            raise AttributeError(k)
        return getattr(self.inner, k)


def turned(parts, about=None, k=None):
    """Parts built in view 0's frame, turned into view k (about the world's middle, or a point)."""
    k = VIEW if k is None else k
    if k % 4 == 0:
        return parts
    about = VIEW_C if about is None else about
    return [A.Part(p.name, TurnZ(p.sdf, k, about), p.ramp, p.group, blend=p.blend, decal=p.decal, emissive=p.emissive)
            for p in parts]


_PLACE = None


def _snapshot():
    """View 0's placing constants, kept to work out every view's from."""
    global _PLACE
    if _PLACE is None:
        _PLACE = dict(domes={n: (d['X'], d['Y']) for n, d in DOMES.items()},
                      rooms=[(r['dx'], r['dy']) for r in BASE_ROOMS],
                      paths=[list(pts) for pts in PATHS],
                      crash=(CRASH['X'], CRASH['Y'], tuple(CRASH['came_from'])),
                      solar=(SOLAR['X'], SOLAR['Y']))


def apply_view_constants(k):
    """Put the placing constants where view k sees them."""
    global _UNITS
    _snapshot()
    for n, (X, Y) in _PLACE['domes'].items():
        DOMES[n]['X'], DOMES[n]['Y'] = (float(v) for v in to_view([X, Y], k))
    for r, (dx, dy) in zip(BASE_ROOMS, _PLACE['rooms']):
        r['dx'], r['dy'] = (float(v) for v in vrot([dx, dy], k))
    for pts, pts0 in zip(PATHS, _PLACE['paths']):
        pts[:] = [tuple(float(v) for v in to_view(q, k)) for q in pts0]
    X, Y, cf = _PLACE['crash']
    CRASH['X'], CRASH['Y'] = (float(v) for v in to_view([X, Y], k))
    CRASH['came_from'] = tuple(float(v) for v in vrot(cf, k))
    SOLAR['X'], SOLAR['Y'] = (float(v) for v in to_view(_PLACE['solar'], k))
    _UNITS = None


@contextlib.contextmanager
def canonical():
    """Build models in view 0's frame: the placing constants (and VIEW) as they are in view 0."""
    global VIEW
    k = VIEW
    apply_view_constants(0)
    VIEW = 0
    try:
        yield
    finally:
        VIEW = k
        apply_view_constants(k)


def canon_unit(name):
    """A dome unit (room) as it is in view 0's frame."""
    with canonical():
        return next(dict(u) for u in dome_units() if u['name'] == name)

# ================================================================== layout (camera X/Y, world units)
DOME_SCALE = 2.5                  # bases are designed at R0 and scaled as a whole (doors ~1.6x the astronaut)
LAMP_SCALE = 1.5                  # path lamps ~22 units: as tall as the astronaut
# Lamps along the trails: off (the owner removed them). Their spots still keep plants and the
# spawn clear, so the forest is unchanged; TRAIL_LAMPS=1 draws them, their posts and light again.
TRAIL_LAMPS = os.environ.get('TRAIL_LAMPS', '0') == '1'
SOLAR_SCALE = 1.6
SOLAR_DESIGN = os.environ.get('SOLAR_DESIGN', 'field')  # approved field; 'array' retains the old panels
DOMES = {
    'base':    dict(X=-1000.0, Y=1620.0, R0=120.0, ribs=36),
    'nursery': dict(X=250.0, Y=2500.0, R0=80.0, ribs=24),
    'comms':   dict(X=1180.0, Y=1590.0, R0=80.0, ribs=24),
}
DOMES['base']['Z'] = DOMES['nursery']['Z'] = 0.0
# Main base designs:
#   v1   the original glass bubble
#   hex  one honeycomb dome of mirror metal and glass (the step between v1 and v2)
#   v2   three honeycomb rooms of mirror metal joined by corridors, a band of glass round each
#   v3   three smooth white rooms joined by corridors, a ring of honeycomb glass round each
BASE_DESIGN = os.environ.get('BASE_DESIGN', 'v3')
BASE_DOME = {'v1': 'glass', 'hex': 'hex', 'v2': 'rooms', 'v3': 'rooms'}[BASE_DESIGN]
BASE_POWERED = False              # the base is dead when the game starts: no lights, nothing turning
for _name, _d in DOMES.items():
    _d['powered'] = BASE_POWERED if _name == 'base' else True
# The main base: three rooms under honeycomb domes (offset from the base centre, radius, honeycomb
# frequency), joined by covered corridors. DOMES['base'] is then the circle around all of them.
BASE_ROOMS = [dict(name='command', dx=80.0, dy=0.0, R=135.0, freq=5),
              dict(name='habitat', dx=-167.0, dy=120.0, R=100.0, freq=4),
              dict(name='garage', dx=-167.0, dy=-120.0, R=100.0, freq=4)]
BASE_LINKS = [(0, 1), (1, 2), (2, 0)]
GLASS_BAND = (24.0, 50.0)         # base rooms: one band of glass panes round the middle, mirror metal elsewhere
if BASE_DOME == 'rooms':
    DOMES['base']['R0'] = 124.0
    DOMES['base']['R'] = DOMES['base']['R0'] * DOME_SCALE
_UNITS = None


def dome_units():
    """Every dome that gets drawn: the nursery, the comms dome, and the base (its three rooms).
    Each unit carries its owner (the DOMES entry) and how it is built."""
    global _UNITS
    if _UNITS is None:
        _UNITS = []
        for name, d in DOMES.items():
            if name == 'base' and BASE_DOME == 'rooms':
                for r in BASE_ROOMS:
                    _UNITS.append(dict(d, name=r['name'], owner=name, X=d['X'] + r['dx'], Y=d['Y'] + r['dy'],
                                       R=r['R'], R0=r['R'] / DOME_SCALE, freq=r['freq'],
                                       style='band' if BASE_DESIGN == 'v3' else 'hex'))
            else:
                _UNITS.append(dict(d, name=name, owner=name, freq=HEX_FREQ,
                                   style='hex' if name == 'base' and BASE_DOME == 'hex' else 'glass'))
    return _UNITS
DOMES['comms']['Z'] = 108.0       # up on the ice massif
# The comms dome stands on a stepped charcoal massif: tiers (radius, height, centre offset from
# the dome), outermost first. The roads climb it on ramps cut through the cliffs.
MASSIF = [(560.0, 36.0, (85.0, 65.0)), (445.0, 72.0, (40.0, 30.0)), (345.0, 108.0, (0.0, 0.0))]
ROAD_SLOPE = 0.42                 # steepest a road may climb
for _d in DOMES.values():
    _d['R'] = _d['R0'] * DOME_SCALE
# the satellite that came down near the base: wreck centre, crater, and the skid trench it
# ploughed coming in from the north-east (direction it came FROM)
CRASH = dict(X=-740.0, Y=1130.0, R=62.0, depth=19.0, came_from=(0.55, 0.835), trench=210.0)
SOLAR = dict(X=-860.0, Y=2050.0)
TOWER_TOP = 150.0                 # design units (scaled with the comms dome)
PATHS = [  # winding, never straight
    [(-1000, 1620), (-760, 1900), (-560, 1980), (-380, 2180), (-120, 2240), (60, 2420), (250, 2500)],   # base -> nursery
    [(-1000, 1620), (-760, 1400), (-500, 1420), (-260, 1200), (40, 1260), (300, 1080), (540, 1120),
     (720, 1110), (840, 1170), (900, 1260), (850, 1330), (930, 1400), (1020, 1430), (1050, 1500),
     (1180, 1590)],                                                            # base -> comms, switchbacks up the massif
    [(1180, 1590), (1040, 1730), (930, 1800), (870, 1900), (780, 1990), (640, 2140), (480, 2260),
     (250, 2500)],                                                             # comms -> nursery, down its back
]
# no road to the wreck (it only just came down), but keep the way there free of cliffs
CRASH_LANE = [(-1000, 1620), (-900, 1380), (-800, 1220), (-740, 1130)]
PATH_HALF = 9.5                  # trails: the walkable width kept clear (nothing is drawn on the ground)
WALK_SLOPE = 0.78                 # steepest ground an astronaut can walk (~38 degrees)
RAMP_SLOPE = 0.42                 # sand drifts piled against cliffs: gentle enough to climb
DRIFT_SIDE = 0.5                  # drift flanks: steep sand, still walkable on the diagonal
CRATERS = [  # X, Y, radius, depth, style: 'new' = rounded walkable bowl, 'old' = steep walls, jump in
    (-300.0, 1650.0, 90.0, 27.0, 'new'), (-450.0, 950.0, 60.0, 20.0, 'old'), (300.0, 1750.0, 70.0, 22.0, 'old'),
    (260.0, 720.0, 55.0, 18.0, 'new'), (-150.0, 2650.0, 60.0, 20.0, 'old')]
# spiky mountain ranges: centre X, Y, peaks, spread, min/max height (their look follows the biome)
SPIKE_RANGES = [
    (-600.0, 700.0, 6, 110.0, 70.0, 150.0),      # red: front-left
    (-150.0, 420.0, 5, 100.0, 70.0, 140.0),      # red: front
    (-1150.0, 1950.0, 5, 90.0, 70.0, 150.0),     # red: behind the base
    (960.0, 1960.0, 6, 110.0, 110.0, 220.0),     # ice: peaks behind the massif
    (1120.0, 1180.0, 6, 90.0, 100.0, 200.0),     # ice: at the massif's front foot
    (640.0, 760.0, 7, 120.0, 90.0, 200.0),       # ice: front-right
    (300.0, 470.0, 5, 100.0, 80.0, 170.0),       # ice: the front snowfield
    (380.0, 1000.0, 4, 80.0, 80.0, 170.0),       # ice: toward the middle
    (-250.0, 2850.0, 6, 130.0, 90.0, 190.0),     # forest: crystal spires
    (650.0, 2520.0, 5, 100.0, 80.0, 170.0),      # forest: east of the nursery
    (60.0, 3050.0, 7, 140.0, 100.0, 210.0),      # forest: the far back skyline
    (60.0, 1950.0, 3, 50.0, 130.0, 210.0),       # lone spires where the three lands meet
]
FOREST_R = (560.0, 1000.0)        # biome fades from full to none over this distance band
ICE_R = (600.0, 1050.0)
FOREST_C = (250.0, 2560.0)        # biome centres (the forest is around the nursery, the ice
ICE_C = (1000.0, 1380.0)          # leans past the comms dome into the right corner)
ICE_POLY = [(-109, 1213), (-17, 914), (11, 684), (6, 511), (40, 368), (126, 282), (227, 253),
            (300, -300), (2200, -300), (2200, 2400), (1250, 2300), (850, 1950), (700, 1500),
            (300, 1300)]   # the snowfields at the front, the massif and the whole right corner


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
    top = max(top, KY * cm['Y'] + cm['Z'] + (TOWER_TOP + 32) * DOME_SCALE)
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


def save_png(image, path):
    """Never truncate an image that an editor/viewer may still have memory-mapped."""
    image.save(path + '.tmp', format='PNG')
    os.replace(path + '.tmp', path)


def save_text(text, path):
    """Replace generated metadata/viewers without truncating an open prior version."""
    with open(path + '.tmp', 'w', encoding='utf-8') as stream:
        stream.write(text)
    os.replace(path + '.tmp', path)


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

# alien forest: dusky violet-teal moss, violet cliffs, glowing pools, crystal spires
T_RAMPS_F = dict(T_RAMPS, **{
    'ground': hexa('#100c20', '#18142c', '#1f1d3a', '#25294a', '#2b3a58', '#2f5064', '#3c6c70', '#5a907e'),
    'mesa':   hexa('#130e24', '#1e1632', '#2c2244', '#3c3058', '#4f426c', '#665a82', '#83769a', '#a296b2'),
    'pit':    hexa('#061620', '#0a2430', '#0e3640', '#134c50', '#1d6a60', '#2f9478', '#56c49a'),
    'path':   hexa('#17142a', '#221e38', '#2e2a48', '#3c3858', '#4c486a', '#5e5b7c', '#747290'),
    'rock':   hexa('#0c0918', '#151024', '#201a32', '#2c2642', '#3a3454', '#4a4566', '#5c5878'),
})
STRATA_F = [
    hexa('#120a20', '#20123a', '#341e52', '#4a2c6a', '#644286'),
    hexa('#160e2c', '#281a46', '#3e2c66', '#583f86', '#7458a2'),
    hexa('#0e0a1c', '#1a1430', '#2a2248', '#3c3462', '#544a7e'),
    hexa('#0c1424', '#14243a', '#1e3652', '#2a4c6c', '#3c6488'),
]
SPIKE_STRATA_F = [
    hexa('#140a26', '#26124a', '#3e1c6c', '#5a2a90', '#7a3cb0'),
    hexa('#0c1426', '#142a48', '#1e406a', '#2a5a8c', '#3a78aa'),
    hexa('#1a0c28', '#30164a', '#4c226a', '#6a3288', '#8c48a8'),
]
TIPS_F = hexa('#3a1a5a', '#7a2c9a', '#c04ad0', '#ee88ee', '#ffd8ff')       # glowing crystal tips
# ice: snowfields with lavender shadows, frozen lakes, charcoal basalt under snow caps
T_RAMPS_I = dict(T_RAMPS, **{
    'ground': hexa('#1a1e30', '#262c44', '#36405c', '#4c5a78', '#687896', '#8c9eb8', '#b4c6d8', '#e0ecf4'),
    'mesa':   hexa('#1c2034', '#2a304a', '#3e4864', '#586682', '#7888a4', '#9eb0c6', '#c8d8e6', '#f0f8fc'),
    'pit':    hexa('#0c1a30', '#12284a', '#1a3c66', '#245684', '#3676a4', '#5a9ec4', '#9cd2e8'),
    'path':   hexa('#22222e', '#30323e', '#424654', '#585e6e', '#727a8a', '#9098a8', '#b4bcc8'),
    'rock':   hexa('#0a0a0e', '#121218', '#1c1c24', '#282832', '#363642', '#464654', '#585868'),
})
STRATA_I = [
    hexa('#08080c', '#101016', '#1a1a22', '#262630', '#363642'),
    hexa('#0a0a10', '#14141c', '#20202a', '#2e2e3a', '#40404e'),
    hexa('#0c1016', '#16202a', '#22303e', '#324456', '#4a6078'),
    hexa('#0a0a0e', '#121218', '#1c1c24', '#2a2a34', '#3c3c48'),
]
SPIKE_STRATA_I = [
    hexa('#060608', '#0e0e12', '#18181e', '#24242c', '#34343e'),
    hexa('#08080c', '#121218', '#1e1e26', '#2c2c36', '#3e3e4a'),
    hexa('#0a0c10', '#141820', '#202832', '#2e3a46', '#42525e'),
]
TIPS_I = hexa('#5a6a88', '#8aa0bc', '#b8cce0', '#e2eef8', '#ffffff')       # heavy snow caps
BIOMES = [  # red, forest, ice
    dict(ramps=T_RAMPS, strata=STRATA, spike=SPIKE_STRATA, tips=FROST, tip_at=0.8),
    dict(ramps=T_RAMPS_F, strata=STRATA_F, spike=SPIKE_STRATA_F, tips=TIPS_F, tip_at=0.84),
    dict(ramps=T_RAMPS_I, strata=STRATA_I, spike=SPIKE_STRATA_I, tips=TIPS_I, tip_at=0.6),
]
SCORCH = np.array(A.hex2rgb('#1c1418'), np.float32)
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
    # alien flora
    'stem':     ['#1a1428', '#2c2240', '#45385e', '#62567c'],
    'cap':      ['#3a1440', '#6a2468', '#a2408e', '#dc76b8'],
    'cap2':     ['#161a44', '#283272', '#40569e', '#7090d0'],
    'cap3':     ['#0e3440', '#17646c', '#25a29e', '#76e6cc'],
    'capspot':  ['#5a2a60', '#9a4a9a', '#d880c8', '#ffc8f0'],
    'gill':     ['#1a5a5a', '#2fa8a0', '#5fe8d0', '#c8fff0'],
    'pod':      ['#3a5a1a', '#78b030', '#c0f060', '#f0ffc0'],
    'pod2':     ['#5a1a5a', '#b03aa8', '#f070e0', '#ffd0f8'],
    'orb':      ['#1a4a6a', '#2a90c0', '#60d8f8', '#d0f8ff'],
    'leafa':    ['#0f2a2e', '#1c4a4a', '#2e706a', '#4ea08a'],
    'corala':   ['#12303a', '#1e5560', '#2f8a88', '#5ec0b0'],
    'coralb':   ['#2a1440', '#48246a', '#6e3a98', '#9c5cc4'],
    'puff':     ['#2a2040', '#4a3a68', '#74609a', '#a890c8'],
    # ice and the wreck
    'icex':     ['#1d3b5c', '#3a6f9a', '#6fb0d2', '#c2ecf8'],
    'icex2':    ['#2a3e6a', '#4a70a8', '#86b0dc', '#d8ecfc'],
    'foil':     ['#5a3a12', '#9a6a22', '#d8a844', '#ffe28a'],
    # a base without power
    'darkwin':  ['#121020', '#1f1c34', '#343652', '#5e6888'],
    'deadbulb': ['#2a2430', '#45404f', '#6a6374', '#9e96a6'],
    'shard':    ['#2c5868', '#6aa6b6', '#bce6ec', '#f2feff'],
    'tglass':   ['#0e2a38', '#1d5566', '#3f8f98', '#a6e0d4'],
    'white':    ['#6e6a86', '#a9a7bd', '#dddce8', '#fbfbff'],
    'char':     ['#0e0c10', '#1c181c', '#2e2826', '#463c36'],
    'void':     ['#000000'] * 4,
}
O_NAMES = list(O_RAMPS)
OID = {n: i for i, n in enumerate(O_NAMES)}
O_RGB = [hexa(*O_RAMPS[n]) for n in O_NAMES]
EMISSIVE = {OID[n] for n in ('glow', 'window', 'screen', 'beacon', 'gill', 'pod', 'pod2', 'orb')}
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
    """(dome unit, direction) for every path end that meets a dome. A path ends at its dome's
    centre; the airlock sits where the path leaves the unit (room) holding that centre."""
    out = []
    for pts in PATHS:
        for end, nxt in ((pts[0], pts[1]), (pts[-1], pts[-2])):
            for name, d in DOMES.items():
                if math.hypot(end[0] - d['X'], end[1] - d['Y']) >= 1:
                    continue
                e = np.array(end, float)
                dirv = np.array(nxt, float) - e
                dirv /= np.linalg.norm(dirv)
                for u in dome_units():
                    c = np.array([u['X'], u['Y']])
                    if u['owner'] == name and np.linalg.norm(e - c) < u['R']:
                        k = dirv @ (c - e)
                        t = k + math.sqrt(max(k * k - (e - c) @ (e - c) + u['R'] ** 2, 0.0))
                        out.append((u, (e + dirv * t - c) / u['R']))
                        break
    return out


def trail_thinning(species, path_d, u, v):
    """How likely a plant may grow at grid point (u, v), given the distance to the trails. The
    forest thins out gradually and unevenly toward a trail, so the way through reads as a natural
    clearing rather than a cut corridor. Trees keep furthest back, and keep out of the strip just
    in front of a trail (from this camera a tall tree hides the ground behind it); low plants
    creep closer. The middle stays clear so the trail can be walked."""
    n = path_d.shape[0]
    d = float(path_d[int(u), int(v)])
    wobble = 0.5 + 0.3 * math.sin(u * 0.021 + 1.3) + 0.2 * math.sin(v * 0.017 + 0.4)   # 0..1 along the way
    clear = PATH_HALF + 1.5 + 6.0 * wobble                     # nothing at all inside this
    tall = species in ('tree', 'ice')
    band = 34.0 if tall else 14.0                             # then thinner and thinner over this
    if d < clear:
        return 0.0
    k = min(1.0, (d - clear) / band)
    keep = k * k * (3 - 2 * k)
    if tall:                                                  # the ground this tree would hide
        for ahead in (16.0, 32.0, 48.0):
            a = ahead / SQ2
            ua, va = min(n - 1, int(u + a)), min(n - 1, int(v + a))
            if path_d[ua, va] < clear + 4.0:
                keep *= 0.18 + 0.5 * (ahead / 48.0) * wobble
                break
    return keep


def path_lamps(curves=None):
    """Lamps along the paths (alternating sides, clear of the domes), and which of them are dead
    because the base has no power."""
    if curves is None:
        curves = [catmull(pts) for pts in PATHS]
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
            lamps.append((float(X), float(Y)))
    bd = DOMES['base']
    dead = set() if bd['powered'] else {i for i, (X, Y) in enumerate(lamps)
                                          if math.hypot(X - bd['X'], Y - bd['Y']) < bd['R'] + 280}
    return lamps, dead


def solar_panels():
    """Grid positions (u, v) of the solar panels."""
    su, sv = to_grid(SOLAR['X'], SOLAR['Y'])
    return [(su + (-48 + col * 24) * SOLAR_SCALE, sv + (-24 + row * 24) * SOLAR_SCALE)
            for row in range(3) for col in range(5)]


# ================================================================== world
def poly_sdist(X, Y, poly):
    """Signed distance to a polygon (negative inside)."""
    P = np.array(poly, np.float32)
    d = np.full(X.shape, np.inf, np.float32)
    inside = np.zeros(X.shape, bool)
    for k in range(len(P)):
        (ax, ay), (bx, by) = P[k], P[(k + 1) % len(P)]
        ex, ey = bx - ax, by - ay
        t = np.clip(((X - ax) * ex + (Y - ay) * ey) / (ex * ex + ey * ey), 0, 1)
        d = np.minimum(d, np.hypot(X - ax - t * ex, Y - ay - t * ey))
        cross = ((ay > Y) != (by > Y)) & (X < (bx - ax) * (Y - ay) / (by - ay + 1e-9) + ax)
        inside ^= cross
    return np.where(inside, -d, d)


def massif_tiers(Xg, Yg):
    """Signed distance to the edge of each massif tier (negative inside), outermost first.
    The edges are warped into craggy bays and spurs."""
    d = DOMES['comms']
    wx = 38.0 * fbm(260, 3, 70) + 9.0 * fbm(50, 2, 71)
    wy = 38.0 * fbm(260, 3, 72) + 9.0 * fbm(50, 2, 73)
    jag = 2.5 * fbm(12, 2, 74)
    return [(np.hypot(Xg + wx - d['X'] - ox, Yg + wy - d['Y'] - oy) + jag - r).astype(np.float32)
            for r, _, (ox, oy) in MASSIF]


def road_profile(height, cp, name):
    """Height of a road along its curve. Where it meets a dome it is level with the dome floor;
    in between it follows the ground it crosses, graded so it never climbs steeper than
    ROAD_SLOPE: half embankment over the low side of each cliff, half cutting into the high side."""
    pu, pv = to_grid(cp[:, 0], cp[:, 1])
    raw = sample(height, pu, pv).astype(np.float64)
    n = len(raw)
    step = np.r_[0.0, np.linalg.norm(np.diff(cp, axis=0), axis=1)] * ROAD_SLOPE   # allowed rise per sample
    pins = []
    for d in DOMES.values():
        near = np.hypot(cp[:, 0] - d['X'], cp[:, 1] - d['Y']) < d['R'] + 45
        if near.any():
            raw[near] = d['Z']
            pins.append((near, d['Z']))

    def envelope(h, up):
        h = h.copy()
        for i in range(1, n):
            h[i] = min(h[i], h[i - 1] + step[i]) if up else max(h[i], h[i - 1] - step[i])
        for i in range(n - 2, -1, -1):
            h[i] = min(h[i], h[i + 1] + step[i + 1]) if up else max(h[i], h[i + 1] - step[i + 1])
        return h

    prof = 0.5 * (envelope(raw, True) + envelope(raw, False))
    for near, z in pins:                       # exactly level at the domes, still within the slope
        dist = np.where(near, 0.0, np.inf)
        for i in range(1, n):
            dist[i] = min(dist[i], dist[i - 1] + step[i])
        for i in range(n - 2, -1, -1):
            dist[i] = min(dist[i], dist[i + 1] + step[i + 1])
        prof = np.clip(prof, z - dist, z + dist)
    slope = float(np.max(np.abs(np.diff(prof)) / np.maximum(step[1:] / ROAD_SLOPE, 1e-6)))
    if raw.max() - raw.min() > 1:
        print(f'  road {name}: climbs {raw.max() - raw.min():.0f} units, steepest {slope:.2f}')
    return prof.astype(np.float32)


def biome_weights(Xg, Yg):
    """Forest around the nursery, ice around the comms dome, red everywhere else. The edges are
    domain-warped so the lands bleed into each other in lobes and fingers, never in circles."""
    wx = 170.0 * fbm(380, 3, 40) + 40.0 * fbm(90, 2, 42)
    wy = 170.0 * fbm(380, 3, 41) + 40.0 * fbm(90, 2, 43)
    out = []
    for (cx_, cy_), (r0, r1) in ((FOREST_C, FOREST_R), (ICE_C, ICE_R)):
        out.append(1.0 - smoothstep(r0, r1, np.hypot(Xg + wx - cx_, Yg + wy - cy_)))
    i_poly = 1.0 - smoothstep(-110.0, 110.0, poly_sdist(Xg + 0.35 * wx, Yg + 0.35 * wy, ICE_POLY))
    out[1] = np.maximum(out[1], i_poly)
    del wx, wy, i_poly
    f, i = out
    over = np.maximum(f + i, 1.0)
    return (f / over).astype(np.float32), (i / over).astype(np.float32)


def crash_field(Xg, Yg):
    """Distance to the crash site (crater + trench), and the along/lateral trench coordinates."""
    cf = CRASH['came_from']
    rx_, ry_ = Xg - CRASH['X'], Yg - CRASH['Y']
    along = rx_ * cf[0] + ry_ * cf[1]
    lat = -rx_ * cf[1] + ry_ * cf[0]
    L = CRASH['trench']
    seg = np.hypot(np.clip(along, 0, L) - along, lat)
    return np.minimum(np.hypot(rx_, ry_) - CRASH['R'], seg - 16.0), along, lat


def crash_relief(along, lat, r):
    """Height change the crash made: a fresh bowl, a ploughed trench with berms, ejecta."""
    D, L = CRASH['depth'], CRASH['trench']
    bowl = np.where(r < 1, -D * np.cos(np.clip(r, 0, 1) * math.pi / 2) ** 2, 0.0)
    ahead = np.clip(-along / CRASH['R'], 0, 1)                         # ejecta thrown forward
    rim = (0.22 + 0.25 * ahead) * D * np.exp(-((r - 1.05) / (0.28 + 0.2 * ahead)) ** 2)
    wob = lat + 2.5 * np.sin(along / 23.0) + 1.2 * np.sin(along / 7.0)
    hw = 11.0 - 4.0 * np.clip(along / L, 0, 1)
    depth = 4.6 * np.clip(1 - along / L, 0, 1) ** 0.7 * (along > 0)
    q = np.clip(np.abs(wob) / hw, 0, 1)
    trench = -depth * np.cos(q * math.pi / 2) ** 2
    fade = smoothstep(0.75, 1.15, r) * smoothstep(-5.0, 5.0, along) * (1 - smoothstep(L - 15, L + 5, along))
    berm = 1.7 * (depth / 4.6 + 0.25) * np.exp(-((np.abs(wob) - hw * 1.1) / (hw * 0.38)) ** 2) * fade
    return (np.minimum(bowl, trench) + rim + berm).astype(np.float32)


def build_world():
    t0 = time.time()
    c = np.arange(N, dtype=np.float32) + 0.5
    U, V = np.meshgrid(c, c, indexing='ij')
    Xg, Yg = (U - V) / SQ2, (U + V) / SQ2
    rs = np.random.default_rng(SEED + 7)
    bio_f, bio_i = biome_weights(Xg, Yg)

    dome_r = {k: np.hypot(Xg - d['X'], Yg - d['Y']) for k, d in DOMES.items()}
    units = dome_units()
    unit_r = [np.hypot(Xg - u['X'], Yg - u['Y']) for u in units]
    rim_d = np.minimum.reduce([r - u['R'] for r, u in zip(unit_r, units)])
    crash_d, c_along, c_lat = crash_field(Xg, Yg)
    su, sv = to_grid(SOLAR['X'], SOLAR['Y'])
    # Preserve the original terrain and random-placement stream for either solar design.
    solar_d = np.maximum(np.abs(U - su) - 62 * SOLAR_SCALE, np.abs(V - sv) - 42 * SOLAR_SCALE)

    # the ice massif under the comms dome
    tiers = massif_tiers(Xg, Yg)
    tier_m = [smoothstep(0.2, 0.8, ndi.gaussian_filter((t < 0).astype(np.float32), 1.1)) for t in tiers]
    massif = np.zeros((N, N), np.float32)
    for (r, top, _), m_ in zip(MASSIF, tier_m):
        massif = np.maximum(massif, top * m_)
    massif += 5.0 * ndi.gaussian_filter((tiers[0] < 0).astype(np.float32), 6) * (1 - tier_m[0])   # scree at its foot
    massif_d = tiers[0]
    del tiers, tier_m

    def raster_d(polylines, height=None):
        raster = np.zeros((N, N), bool)
        hgrid = np.zeros((N, N), np.float32) if height is not None else None
        cps = []
        for k, pts in enumerate(polylines):
            cp = catmull(pts)
            cps.append(cp)
            pu, pv = to_grid(cp[:, 0], cp[:, 1])
            ok = (pu >= 0) & (pu < N) & (pv >= 0) & (pv < N)
            raster[pu[ok].astype(int), pv[ok].astype(int)] = True
            if height is not None:
                hgrid[pu[ok].astype(int), pv[ok].astype(int)] = road_profile(height, cp, k)[ok]
        if height is None:
            return ndi.distance_transform_edt(~raster).astype(np.float32), cps
        dist, ind = ndi.distance_transform_edt(~raster, return_indices=True)
        road = hgrid[ind[0], ind[1]]
        del ind
        return dist.astype(np.float32), cps, road

    path_d, curves, road_h = raster_d(PATHS, massif)
    lane_d, _ = raster_d([CRASH_LANE])

    crater_keep = np.minimum.reduce([np.hypot(Xg - x, Yg - y) - r * 1.35 for x, y, r, *_ in CRATERS])
    struct_d = np.minimum.reduce([rim_d, path_d - PATH_HALF, crash_d, solar_d])
    keep = np.minimum.reduce([rim_d - 80, path_d - 30, crash_d - 45, solar_d - 30, crater_keep, lane_d - 22,
                              massif_d - 45])
    free = smoothstep(0, 70, keep)
    del crater_keep, keep

    def soft(mask, sigma=1.1):
        return smoothstep(0.2, 0.8, ndi.gaussian_filter(mask.astype(np.float32), sigma))

    # --- mesas: a ridge of them along the back and the far edges, a few loners in between.
    # The forest is open woodland (fewer cliffs); the ice lands are cut by charcoal steeps.
    m = (fbm(240, 5, 1) + 1.0 * smoothstep(1.4 * HALF, 1.95 * HALF, Yg) + 0.75 * smoothstep(0.68 * HALF, 0.95 * HALF, np.abs(Xg))
         - 0.55 * bio_f + 0.35 * bio_i)
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
    del m, s1, s2

    # --- stepped pits (glowing pools in the forest, frozen lakes in the ice), never next to a mesa
    mesa_zone = ndi.binary_dilation(tier1, iterations=30)
    p = fbm(220, 5, 4) + 0.3 * fbm(26, 3, 5) - 4.0 * (1 - free) - 4.0 * mesa_zone + 0.25 * bio_f
    q1, q2 = np.quantile(p, [0.935, 0.975])
    pit1 = ndi.binary_opening(p > q1, iterations=3)
    pit2 = ndi.binary_opening(p > q2, iterations=2) & ndi.binary_erosion(pit1, iterations=6)
    pits = -22.0 * soft(pit1) - 20.0 * soft(pit2)
    del p

    # --- craters (hand placed + scattered small ones)
    craters = list(CRATERS)
    tries = 0
    while len(craters) < 52 and tries < 6000:
        tries += 1
        X, Y = rs.uniform(-HALF * 0.9, HALF * 0.9), rs.uniform(150, 2 * HALF - 150)
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

    # --- spiky mountains: star-shaped cones with concave flanks and gullies. Ice peaks are
    # narrower and sharper; forest spires are slim crystal needles.
    spike_h = np.zeros((N, N), np.float32)
    spike_rel = np.zeros((N, N), np.float32)
    jag = fbm(18, 2, 14)
    peaks = []
    for cx_, cy_, count, spread, hmin, hmax in SPIKE_RANGES:
        placed = 0
        for _ in range(count * 30):
            if placed >= count:
                break
            X = cx_ + rs.normal(0, spread * 0.6)
            Y = cy_ + rs.normal(0, spread * 0.6)
            Hs = float(rs.uniform(hmin, hmax))
            if abs(X) + abs(Y - HALF) > HALF - 20:
                continue
            u0, v0 = to_grid(X, Y)
            iu, iv = int(u0), int(v0)
            if not (0 <= iu < N and 0 <= iv < N):
                continue
            bf, bi = float(bio_f[iu, iv]), float(bio_i[iu, iv])
            Rs = Hs * float(rs.uniform(0.38, 0.55)) * (1 - 0.3 * bf - 0.12 * bi)
            if struct_d[iu, iv] < Rs * 1.1 + 30:
                continue
            win = int(Rs * 1.15) + 2
            a0, a1 = max(0, iu - win), min(N, iu + win)
            b0, b1 = max(0, iv - win), min(N, iv + win)
            du_, dv_ = U[a0:a1, b0:b1] - u0, V[a0:a1, b0:b1] - v0
            th = np.arctan2(dv_, du_)
            sides = int(rs.integers(4, 7)) if bf < 0.5 else int(rs.integers(5, 8))
            sector = 2 * math.pi / sides
            rel = np.mod(th - rs.uniform(0, sector), sector) - sector / 2
            edge = math.cos(sector / 2) / np.cos(rel)            # regular polygon footprint: flat facets
            rr = np.hypot(du_, dv_) / (Rs * edge) * (1 + 0.035 * jag[a0:a1, b0:b1])
            prof = (Hs * np.clip(1 - rr, 0, 1) ** (1.45 + 0.35 * bi)).astype(np.float32)
            better = prof > spike_h[a0:a1, b0:b1]
            spike_h[a0:a1, b0:b1] = np.where(better, prof, spike_h[a0:a1, b0:b1])
            spike_rel[a0:a1, b0:b1] = np.where(better, prof / Hs, spike_rel[a0:a1, b0:b1])
            placed += 1
            peaks.append((float(X), float(Y), Hs, bf, bi))

    # --- base dunes + wind ripples; snow carves sharp sastrugi, moss grows in soft hummocks
    dunes = (2.4 - 0.9 * bio_f) * fbm(170, 4, 6) + 0.6 * fbm(36, 2, 7)
    bio_r = 1.0 - bio_f - bio_i
    ripples = 0.28 * bio_r * np.sin((U * 0.83 + V * 0.55) / 2.6 + 2.6 * fbm(90, 2, 8))
    ripples += bio_i * (0.5 * np.abs(np.sin((U * 0.35 - V * 0.94) / 3.6 + 2.2 * fbm(60, 2, 15))) - 0.25)
    ripples += bio_f * 0.55 * np.clip(fbm(13, 2, 16), 0, None)
    Hf = dunes + ripples + mesa + talus + pits + crater_h + spike_h + massif
    del ripples, crater_h, talus
    ground_ok = (free > 0.3) & ~ndi.binary_dilation(pit1, iterations=3) & (spike_h < 1) & (path_d > PATH_HALF + 6)
    before = Hf.copy()
    drifts = carve_drifts(Hf, U, V, tier1, tier2, pit1, pit2, ground_ok, rs, jag)
    drifted = Hf > before + 0.5
    del before, ground_ok

    # --- level the ground around the domes, the crash site and the solar field, then lay the
    # roads (graded ramps where they climb)
    for k, d in DOMES.items():
        Hf = d['Z'] + (Hf - d['Z']) * smoothstep(d['R'] + 15, d['R'] + 100, dome_r[k])
    Hf *= 0.3 + 0.7 * smoothstep(0, 60, crash_d)
    Hf *= smoothstep(0, 30, solar_d)
    w = smoothstep(PATH_HALF - 2, PATH_HALF + 9, path_d)
    Hf = Hf * w + (road_h + ndi.gaussian_filter(dunes, 6) * 0.35) * (1 - w)
    del road_h, w

    # --- the crash: bowl, trench, berms (kept apart so the game can show the ground before it)
    cu, cv = to_grid(CRASH['X'], CRASH['Y'])
    cwin = int(CRASH['trench'] + CRASH['R'] * 2 + 30)
    ca0, ca1 = max(0, int(cu) - cwin), min(N, int(cu) + cwin)
    cb0, cb1 = max(0, int(cv) - cwin), min(N, int(cv) + cwin)
    sl = (slice(ca0, ca1), slice(cb0, cb1))
    r_c = np.hypot(Xg[sl] - CRASH['X'], Yg[sl] - CRASH['Y']) / CRASH['R']
    crash_h = crash_relief(c_along[sl], c_lat[sl], r_c)
    Hf[sl] += crash_h
    del r_c

    # --- boulders, crowding at cliff feet and crater rims, plus a few big ones (fewer in the moss)
    near_cliff = np.clip(ndi.gaussian_filter((tier1 | pit1).astype(np.float32), 9) * 3.0, 0, 1)
    drift_zone = ndi.binary_dilation(drifted, iterations=6)          # keep the way up clear
    rock = np.zeros((N, N), np.float32)
    placed, tries = 0, 0
    while placed < 1750 and tries < 80000:
        tries += 1
        u, v = rs.uniform(14, N - 14, 2)
        iu, iv = int(u), int(v)
        big = placed < 70
        if free[iu, iv] < 0.9 or drift_zone[iu, iv] or crash_d[iu, iv] < 30:
            continue
        if not big and rs.random() > (0.08 + 0.9 * near_cliff[iu, iv]) * (1 - 0.7 * bio_f[iu, iv]):
            continue
        r = float(rs.uniform(6, 11)) if big else float(np.clip(1.3 + rs.gamma(1.4, 0.9), 1.3, 5.5))
        win = int(r) + 2
        a0, a1, b0, b1 = iu - win, iu + win + 1, iv - win, iv + win + 1
        d = np.hypot(U[a0:a1, b0:b1] - u, V[a0:a1, b0:b1] - v) / r
        bump = r * (0.7 if big else 0.8) * np.sqrt(np.clip(1 - d * d, 0, 1))
        rock[a0:a1, b0:b1] = np.maximum(rock[a0:a1, b0:b1], bump)
        placed += 1
    Hf = Hf + rock
    del near_cliff, drift_zone

    for r, u in zip(unit_r, units):                 # dome floors: a low plinth
        Hf[r < u['R']] = u['Z'] + 0.6 * DOME_SCALE
    Hf = Hf.astype(np.float32)

    # --- materials
    mat = np.zeros((N, N), np.uint8)                # 0 ground
    mat[(mesa > 16) | (massif > 16)] = 1            # mesa and massif tops
    mat[(pits < -10)] = 2                           # pit floors
    mat[rock > 0.35] = 4
    mat[spike_h > 4] = 6                            # spires
    mat[drifted] = 0                                # sand drifts read as ground
    for r, u in zip(unit_r, units):
        mat[r < u['R']] = 5
    del mesa, pits, rock, drifted, massif, massif_d

    # --- interior walkways: from each airlock straight to the dome centre
    walk_d = np.full((N, N), np.inf, np.float32)
    for d, dirv in airlock_ends():
        ui = next(i for i, u in enumerate(units) if u is d)
        rel_x, rel_y = Xg - d['X'], Yg - d['Y']
        t = np.clip(rel_x * dirv[0] + rel_y * dirv[1], 0, d['R'])
        dist = np.hypot(rel_x - t * dirv[0], rel_y - t * dirv[1])
        walk_d = np.minimum(walk_d, np.where(unit_r[ui] < d['R'], dist, np.inf))
        del rel_x, rel_y, t, dist
    if BASE_DOME == 'rooms':                        # and from room to room, out through the corridors
        rooms = [i for i, u in enumerate(units) if u['owner'] == 'base']
        for a_, b_ in BASE_LINKS:
            ua, ub = units[rooms[a_]], units[rooms[b_]]
            ex, ey = ub['X'] - ua['X'], ub['Y'] - ua['Y']
            t = np.clip(((Xg - ua['X']) * ex + (Yg - ua['Y']) * ey) / (ex * ex + ey * ey), 0, 1)
            dist = np.hypot(Xg - ua['X'] - t * ex, Yg - ua['Y'] - t * ey)
            inside = (unit_r[rooms[a_]] < ua['R']) | (unit_r[rooms[b_]] < ub['R'])
            walk_d = np.minimum(walk_d, np.where(inside, dist, np.inf))
            del t, dist, inside

    # --- lamps along the paths
    lamps, dead_lamps = path_lamps(curves)
    bd = DOMES['base']
    # warm light pools: path lamps + the lit dome interiors
    glow = np.zeros((N, N), np.float32)
    pool = 19.0 * LAMP_SCALE
    for li, (X, Y) in enumerate(lamps):
        if li in dead_lamps or not TRAIL_LAMPS:
            continue
        u0, v0 = to_grid(X, Y)
        r_ = int(pool) + 2
        a0, a1, b0, b1 = int(u0) - r_, int(u0) + r_ + 1, int(v0) - r_, int(v0) + r_ + 1
        d = np.hypot(U[a0:a1, b0:b1] - u0, V[a0:a1, b0:b1] - v0) / pool
        glow[a0:a1, b0:b1] = np.maximum(glow[a0:a1, b0:b1], np.clip(1 - d, 0, 1) ** 1.6)
    for r, d in zip(unit_r, units):
        if not d['powered']:
            continue
        inside = r < d['R']
        glow[inside] = np.maximum(glow[inside], 0.55 * np.clip(1 - (r[inside] / d['R']) ** 2, 0, 1))
        spill_w = 34 * 1.6
        spill = (r >= d['R']) & (r < d['R'] + spill_w)
        glow[spill] = np.maximum(glow[spill], 0.42 * np.clip(1 - (r[spill] - d['R']) / spill_w, 0, 1) ** 1.5)
    sand_in = np.zeros((N, N), np.float32)          # red sand drifted in through the breaches
    sand_noise = fbm(34, 2, 81)
    for r, u in zip(unit_r, units):
        if u['style'] != 'hex' or not unit_breaches(u):
            continue
        B = unit_breaches(u)[0][0]
        bxy = np.array([B[0], B[1]]) / math.hypot(B[0], B[1])
        reach = ((Xg - u['X']) * bxy[0] + (Yg - u['Y']) * bxy[1]) / u['R']
        sand_in = np.maximum(sand_in, smoothstep(0.05, 0.7, reach + 0.32 * sand_noise) * (r < u['R']))
        del reach
    del dome_r, rim_d, solar_d, struct_d, c_along, c_lat, unit_r, sand_noise

    # --- normals (camera frame), AO, texture fields
    Hu, Hv = np.gradient(Hf)
    dX, dY = (Hu - Hv) / SQ2, (Hu + Hv) / SQ2
    del Hu, Hv
    inv = 1.0 / np.sqrt(dX * dX + dY * dY + 1.0)
    ao = (np.clip((ndi.gaussian_filter(Hf, 4) - Hf) / 5.0, 0, 1) * 0.8
          + np.clip((ndi.gaussian_filter(Hf, 14) - Hf) / 18.0, 0, 1) * 0.6)

    G = dict(H=Hf, nX=(-dX * inv).astype(np.float32), nY=(-dY * inv).astype(np.float32),
             nZ=inv.astype(np.float32), ao=ao.astype(np.float32), mat=mat, path_d=path_d, glow=glow,
             walk_d=np.minimum(walk_d, 99).astype(np.float32), albedo=fbm(380, 3, 13),
             tex=(0.6 * fbm(30, 3, 9) + 0.4 * fbm(8, 2, 10)).astype(np.float32),
             streak=fbm(70, 3, 11, aniso=(2.2, 0.35)), strata=fbm(90, 2, 12),
             spike_rel=spike_rel, lamps=lamps, craters=craters, peaks=peaks,
             bio_f=bio_f, bio_i=bio_i, patch_f=fbm(26, 3, 50), patch_i=fbm(22, 3, 51),
             crash_h=crash_h, crash_win=(ca0, ca1, cb0, cb1), lane_d=lane_d, crash_d=crash_d,
             dead_lamps=dead_lamps, sand_in=sand_in)
    del dX, dY, inv, ao, walk_d
    G['shadow'] = shadow_map(Hf)
    place_flora(G, U, V, rs)
    if SOLAR_DESIGN == 'field':
        # Do this after scattering: adding hardware cannot reroll the planet's forest.
        apply_terrain(G['H'], G['mat'], Xg, Yg)
        for plant in G['flora']:
            plant['z'] = height_at(G, plant['X'], plant['Y'])
        Hu, Hv = np.gradient(G['H'])
        dx, dy = (Hu - Hv) / SQ2, (Hu + Hv) / SQ2
        inv = 1 / np.sqrt(dx * dx + dy * dy + 1)
        for key, values in [('nX', -dx * inv), ('nY', -dy * inv), ('nZ', inv)]:
            G[key] = values.astype(np.float32)
        G['ao'] = (np.clip((ndi.gaussian_filter(G['H'], 4) - G['H']) / 5, 0, 1) * .8
                   + np.clip((ndi.gaussian_filter(G['H'], 14) - G['H']) / 18, 0, 1) * .6).astype(np.float32)
        G['shadow'] = shadow_map(G['H'])
        stamp_plant_shadows(G, U, V)
    print(f'sand drifts: {drifts}')
    print(f'world built in {time.time() - t0:.1f}s ({len(craters)} craters, {len(peaks)} peaks, '
          f'{placed} boulders, {len(lamps)} lamps, {len(G["flora"])} plants and crystals)')
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


def flora_variants():
    """Every plant / crystal model at design time, built once at the origin (t = 0)."""
    out = {}
    for name in SPECIES:
        out[name] = [variant_parts(name, v, 0.0) for v in range(variant_count(name))]
    return out


def variant_count(name):
    return ICE_VARIANTS if name == 'ice' else FLORA[name]['variants']


def variant_seed(name, v):
    return SEED * 100 + SPECIES.index(name) * 20 + v


def variant_parts(name, v, t):
    if name == 'ice':
        return ice_cluster(np.zeros(3), variant_seed(name, v))[0]
    return FLORA[name]['fn'](np.zeros(3), variant_seed(name, v), t)


def part_samples(sdf):
    """A few (centre, radius) blobs covering one part, for stamping its shadow."""
    if isinstance(sdf, TurnZ):
        return [(sdf.fwd(c), r) for c, r in part_samples(sdf.inner)]
    if isinstance(sdf, A.RoundCone):
        n = max(2, int(math.sqrt(sdf.l2) / 1.5))
        return [(sdf.a + sdf.ba * t, sdf.r1 + (sdf.r2 - sdf.r1) * t) for t in np.linspace(0, 1, n)]
    if isinstance(sdf, A.Ellipsoid):
        return [(sdf.c, float(max(sdf.rad[0], sdf.rad[1])))]
    c, r = part_bound(sdf)
    return [(c, r)]


SUN_RUN = -np.array([SUN[0], SUN[1]]) / SUN[2]        # ground shift of a shadow per unit of height


def place_flora(G, U, V, rs):
    """Scatter the forest (clumped groves, glades between) and the ice crystals, on gentle
    ground only, thinning out through the biome edges. Each plant stamps its shadow."""
    t0 = time.time()
    Hf = G['H']
    variants = flora_variants()
    G['flora_variants'] = variants
    groves = fbm(150, 3, 60)
    taken = np.zeros((N, N), bool)
    G['bglow'] = np.zeros((N, N), np.float32)        # soft light the glowing plants throw on the moss
    lamp_xy = np.array(G['lamps'])
    plants = []
    rules = {  # species: biome field, min weight, grove preference, spacing, tries
        'tree':  ('f', 0.42, 1.25, 20.0, 9000),
        'bulbs': ('f', 0.28, 0.3, 9.0, 9000),
        'coral': ('f', 0.16, -0.2, 7.0, 9000),
        'puff':  ('f', 0.12, 0.0, 7.0, 6000),
        'curl':  ('f', 0.22, 0.25, 9.0, 6000),
        'ice':   ('i', 0.3, 0.0, 13.0, 9000),
    }
    want = dict(tree=420, bulbs=520, coral=560, puff=260, curl=260, ice=300)
    for name, (field, wmin, grove, spacing, tries) in rules.items():
        bio = G['bio_f'] if field == 'f' else G['bio_i']
        count = 0
        for _ in range(tries * 3):
            if count >= want[name]:
                break
            u, v = rs.uniform(30, N - 30, 2)
            iu, iv = int(u), int(v)
            b = float(bio[iu, iv])
            if b < 0.12:
                continue
            w = b * (1.0 + 0.3 * float(G['patch_f' if field == 'f' else 'patch_i'][iu, iv]) + grove * 0.45 * float(groves[iu, iv]))
            if w < wmin + rs.uniform(0, 0.35):
                continue
            if G['nZ'][iu, iv] < 0.93 or G['mat'][iu, iv] in (2, 4, 5, 6) or taken[iu, iv]:
                continue
            if G['lane_d'][iu, iv] < 10 or G['crash_d'][iu, iv] < 40:
                continue
            if rs.uniform() > trail_thinning(name, G['path_d'], u, v):
                continue
            X, Y = to_cam(u, v)
            if min(math.hypot(X - d['X'], Y - d['Y']) - d['R'] for d in DOMES.values()) < 40:
                continue
            if len(lamp_xy) and np.min(np.hypot(lamp_xy[:, 0] - X, lamp_xy[:, 1] - Y)) < 14:
                continue
            if name == 'tree' and abs(float(Hf[iu, iv]) - float(ndi.map_coordinates(Hf, [[u - 4, u + 4], [v, v]], order=1).mean())) > 1.2:
                continue
            r = int(spacing) + 1
            a0, a1, b0, b1 = max(0, iu - r), min(N, iu + r + 1), max(0, iv - r), min(N, iv + r + 1)
            taken[a0:a1, b0:b1] |= np.hypot(U[a0:a1, b0:b1] - u, V[a0:a1, b0:b1] - v) < spacing
            z = float(ndi.map_coordinates(Hf, [[u - 0.5], [v - 0.5]], order=1)[0])
            var = int(rs.integers(variant_count(name)))
            plants.append(dict(species=name, variant=var, X=float(X), Y=float(Y), z=z))
            count += 1
            if name in ('tree', 'bulbs'):
                lr = 26.0 if name == 'tree' else 12.0
                w_ = int(lr) + 2
                a0, a1, b0, b1 = max(0, iu - w_), min(N, iu + w_ + 1), max(0, iv - w_), min(N, iv + w_ + 1)
                fall = np.clip(1 - np.hypot(U[a0:a1, b0:b1] - u, V[a0:a1, b0:b1] - v) / lr, 0, 1) ** 1.5
                G['bglow'][a0:a1, b0:b1] = np.maximum(G['bglow'][a0:a1, b0:b1], fall * (1.0 if name == 'tree' else 0.7))
    G['flora'] = plants
    stamp_plant_shadows(G, U, V)
    counts = {k: sum(1 for p in plants if p['species'] == k) for k in rules}
    print(f'flora placed in {time.time() - t0:.1f}s: {counts}')


def stamp_plant_shadows(G, U, V, k=0):
    """Every plant's shadow on the ground (G's plants are where view k sees them; their models
    are in view 0's frame, so turn them)."""
    variants = G['flora_variants']
    for pl in G['flora']:
        X, Y = pl['X'], pl['Y']
        for part in variants[pl['species']][pl['variant']]:
            for c, rad in part_samples(part.sdf):
                c = vrot(c, k)
                sx, sy = X + c[0] + c[2] * SUN_RUN[0], Y + c[1] + c[2] * SUN_RUN[1]
                gu, gv = to_grid(sx, sy)
                rr = rad * 0.9 + 0.3
                w_ = int(rr) + 2
                a0, a1 = max(0, int(gu) - w_), min(N, int(gu) + w_ + 1)
                b0, b1 = max(0, int(gv) - w_), min(N, int(gv) + w_ + 1)
                if a1 <= a0 or b1 <= b0:
                    continue
                blob = np.hypot(U[a0:a1, b0:b1] - gu, V[a0:a1, b0:b1] - gv) < rr
                G['shadow'][a0:a1, b0:b1] = np.maximum(G['shadow'][a0:a1, b0:b1], 0.85 * blob)


def view_world(G0, k):
    """The world as view k sees it: every grid turned with it (and the vectors in them), all that
    is placed moved, and the sun's shadows cast afresh, since the sun stays put on screen."""
    if k % 4 == 0:
        return dict(G0)                                  # a copy: rendering drops grids it is done with
    t0 = time.time()
    G = {}
    for key, val in G0.items():
        if isinstance(val, np.ndarray) and val.shape == (N, N):
            G[key] = rot_grid(val, k)
        else:
            G[key] = val
    R = _turn2(k)
    nx, ny = G0['nX'], G0['nY']
    G['nX'] = rot_grid((R[0, 0] * nx + R[0, 1] * ny).astype(np.float32), k)
    G['nY'] = rot_grid((R[1, 0] * nx + R[1, 1] * ny).astype(np.float32), k)
    G['lamps'] = [tuple(float(v) for v in to_view(q, k)) for q in G0['lamps']]
    G['peaks'] = [(*to_view(pk[:2], k), *pk[2:]) for pk in G0['peaks']]
    G['flora'] = [dict(pl, X=float(xy[0]), Y=float(xy[1])) for pl in G0['flora']
                  for xy in [to_view([pl['X'], pl['Y']], k)]]
    G['crash_win'] = rot_window(G0['crash_win'], k)
    G['crash_h'] = np.ascontiguousarray(np.rot90(G0['crash_h'], -(k % 4)))
    G['shadow'] = shadow_map(G['H'])
    c = np.arange(N, dtype=np.float32) + 0.5
    U, V = np.meshgrid(c, c, indexing='ij')
    stamp_plant_shadows(G, U, V, k)
    print(f'view {k}: world turned and its shadows cast in {time.time() - t0:.1f}s')
    return G


def shadow_map(Hf, win=None):
    """1 = in shadow. March every cell toward the sun through the heightfield, plus props.
    With win = (u0, u1, v0, v1) only that window is computed (terrain only) and returned."""
    du, dv = to_grid(SUN[0], SUN[1])
    u0, u1, v0, v1 = win or (0, N, 0, N)
    iu, iv = np.meshgrid(np.arange(u0, u1, dtype=np.float32), np.arange(v0, v1, dtype=np.float32), indexing='ij')
    occ = np.zeros(iu.shape, bool)
    base = Hf[u0:u1, v0:v1] + 0.3
    t = 1.0
    while t < 330:
        hs = ndi.map_coordinates(Hf, [iu + du * t, iv + dv * t], order=1, mode='nearest')
        occ |= hs > base + SUN[2] * t
        t += 1.0 if t < 24 else (2.0 if t < 90 else 4.0)
    sh = occ.astype(np.float32)
    if win is not None:
        return sh
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
    z = Hf[a0:a1, b0:b1] + s * SUN[2] / lh - c['Z']
    rad = (7.5 - 4.5 * np.clip(z / (TOWER_TOP * DOME_SCALE), 0, 1)) * DOME_SCALE
    tower = (s > 0) & (perp < rad) & (z > 0) & (z < top)
    sh[a0:a1, b0:b1] = np.maximum(sh[a0:a1, b0:b1], tower)

    # glass domes cast a faint shadow outside their footprint
    Lg = np.array([du, dv, SUN[2]])
    for d in dome_units():
        du0, dv0 = to_grid(d['X'], d['Y'])
        R = d['R']
        a0, a1 = max(0, int(du0 - R * 2.4)), min(N, int(du0 + R * 2.4))
        b0, b1 = max(0, int(dv0 - R * 2.4)), min(N, int(dv0 + R * 2.4))
        if d['style'] in ('hex', 'band'):
            sh[a0:a1, b0:b1] = np.maximum(sh[a0:a1, b0:b1], hex_shadow(Hf, a0, a1, b0, b1, d))
            continue
        P = np.stack([iu[a0:a1, b0:b1] + 0.5 - du0, iv[a0:a1, b0:b1] + 0.5 - dv0, Hf[a0:a1, b0:b1] - d['Z']], -1)
        b = P @ Lg
        cc = (P * P).sum(-1) - R * R
        hit = (b * b - cc > 0) & (-b + np.sqrt(np.maximum(b * b - cc, 0)) > 0) & (cc > 0)
        sh[a0:a1, b0:b1] = np.maximum(sh[a0:a1, b0:b1], 0.45 * hit)
    return sh


# ================================================================== terrain render
def bottom_profile(X):
    rs = np.random.default_rng(SEED + 3)
    knots = np.arange(-2400, 2401, 37.0)
    vals = rs.standard_normal(len(knots))
    n1 = np.interp(X, knots, vals)
    knots2 = np.arange(-2400, 2401, 11.0)
    n2 = np.interp(X, knots2, rs.standard_normal(len(knots2)))
    return -74.0 - 10.0 * n1 - 4.0 * np.abs(n2)


def render_terrain(G, x_range=None, y_range=None):
    """Ray hits for the whole image, or for a window of it (x_range / y_range in image pixels)."""
    t0 = time.time()
    Hm = G['H']
    xa, xb = x_range or (0, W)
    ya, yb = y_range or (0, H)
    dYs = 0.25
    Ys = (np.arange(0, 2 * HALF, dYs) + dYs / 2).astype(np.float32)
    rows = ((AY - (np.arange(ya, yb) + 0.5)) / PX).astype(np.float32)
    hitY = np.full((yb - ya, xb - xa), np.inf, np.float32)
    hitZ = np.zeros((yb - ya, xb - xa), np.float32)
    kind = np.zeros((yb - ya, xb - xa), np.uint8)          # 1 terrain, 2 crust wall
    for i0 in range(xa, xb, 32):
        i1 = min(xb, i0 + 32)
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
            hitY[j, i0 - xa + c] = Yh
            hitZ[j, i0 - xa + c] = Zh
            kind[j, i0 - xa + c] = np.where(wall, 2, 1)
    print(f'terrain ray hits in {time.time() - t0:.1f}s')
    return hitY, hitZ, kind


def shade_terrain(G, hitY, hitZ, kind, y_off=0, x_off=0, scorch=True):
    """Shade every terrain pixel. Works on the whole image or on a window of it (the offsets
    give the window's place in the image). Also returns each pixel's biome (0 red, 1 forest, 2 ice)."""
    t0 = time.time()
    h, w = kind.shape
    img = np.zeros((h, w, 3), np.uint8)
    dark = np.zeros((h, w, 3), np.uint8)
    bio = np.zeros((h, w), np.uint8)
    fx = np.zeros((h, w), np.uint8)
    steep_map = np.zeros((h, w), bool)
    level_top = np.zeros((h, w, 3), np.uint8)       # lightest colour of each pixel's ramp (rim light)
    no_lip = np.zeros((h, w), bool)
    for r0 in range(0, h, 320):                     # bands keep memory low
        r1 = min(h, r0 + 320)
        jj, ii = np.nonzero(kind[r0:r1] > 0)
        if jj.size == 0:
            continue
        jj = jj + r0
        rgb, drk, top, steep, spire, b, f, lt = _shade_pixels(G, jj + y_off, ii + x_off, hitY[jj, ii], hitZ[jj, ii],
                                                            kind[jj, ii] == 2, scorch)
        if EMIT is not None and EMIT.shape == kind.shape:
            EMIT[jj, ii] = lt
        img[jj, ii] = rgb
        dark[jj, ii] = drk
        level_top[jj, ii] = top
        steep_map[jj, ii] = steep
        no_lip[jj, ii] = spire
        bio[jj, ii] = b
        fx[jj, ii] = f

    # rim light: the lip pixel above a cliff face catches the sun
    below_steep = np.zeros_like(steep_map)
    below_steep[:-1] = steep_map[1:] & (kind[1:] > 0)
    dy = np.full((h, w), np.inf, np.float32)
    dy[:-1] = np.abs(hitY[:-1] - hitY[1:])
    lip = (kind > 0) & ~steep_map & below_steep & (dy < 4.0) & ~no_lip
    img[lip] = level_top[lip]
    print(f'terrain shaded in {time.time() - t0:.1f}s')
    return img, dark, bio, fx


def _hash(a, b):
    return (np.sin(a * 12.9898 + b * 78.233) * 43758.5453) % 1.0


def _ramp_px(ramp, I, bay, dith):
    n = len(ramp)
    return ramp[np.clip(np.round(I * (n - 1) + bay * dith), 0, n - 1).astype(int)]


SNOW_LEDGE = 0.4                  # ice cliffs: snow clings wherever the face eases off this much
EMBER = hexa('#ff9a48', '#ffd27a')
BGLOW = np.array(A.hex2rgb('#5fe8d0'), np.float32)


def _shade_pixels(G, jj, ii, Y, Z, wall, scorch=True):
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
    walk_d = sample(G['walk_d'], u, v)
    albedo = sample(G['albedo'], u, v)
    spike_rel = sample(G['spike_rel'], u, v)
    bf, bi = sample(G['bio_f'], u, v), sample(G['bio_i'], u, v)
    bay = BAYER[jj % 4, ii % 4]

    # which land each pixel belongs to: the strongest wins, with patchy edges (snow patches on
    # the red dust, moss creeping over it) and a fine dither right at the seam
    score = np.stack([1.0 - bf - bi,
                      bf + 0.17 * sample(G['patch_f'], u, v) + 0.045 * bay,
                      bi + 0.17 * sample(G['patch_i'], u, v) + 0.045 * bay])
    bio = np.argmax(score, axis=0).astype(np.uint8)
    del score
    is_f, is_i = bio == 1, bio == 2

    I = 0.18 + 0.78 * np.maximum(ndl, 0.0)
    I = I * (1.0 - 0.52 * shadow) - 0.34 * ao
    steep = (nZ < 0.55) | wall
    flat = ~steep
    # dust: soft patches, fine grit and bright wind streaks (snow: brighter, smoother)
    grit = _hash(np.floor(u * 2), np.floor(v * 2))
    I += np.where(flat, 0.04 * tex + 0.05 * np.clip(streak - 0.6, 0, 2) + 0.05 * albedo + 0.05 * (grit - 0.5)
                  - 0.07 * np.clip(-albedo - 0.9, 0, 1.5), 0.0)
    I -= np.where(wall, 0.3 * np.clip(-Z / 90.0, 0, 1), 0.0)
    I += np.where(is_i & flat, 0.12, 0.0) - np.where(is_f, 0.03, 0.0)

    rgb = np.zeros((len(jj), 3), np.uint8)
    drk = np.zeros((len(jj), 3), np.uint8)
    top = np.zeros((len(jj), 3), np.uint8)
    fx = np.zeros(len(jj), np.uint8)

    # flat materials (trails are not drawn: they are just where nothing grows)
    floor = flat & (mat == 5)
    sandy = floor & (sample(G['sand_in'], u, v) > 0.45 + bay * 0.3)       # red sand drifted in through the breach
    floor &= ~sandy
    walk_w = 5.5 * DOME_SCALE
    walkway = floor & (walk_d < walk_w)
    sel_mat = np.where(walkway, 7, np.where(floor, 9, np.where(sandy, 0, mat)))
    # 0 ground 1 mesa 2 pit 3 path 4 rock 6 spire 7 walkway 9 floor; -1 cliff -2 spire face -3 tips
    sel_mat = np.where(steep, -1, sel_mat)
    sel_mat = np.where(mat == 4, 4, sel_mat)                  # boulders keep rock colours even when steep
    spire = (mat == 6) & (sel_mat == -1)
    tip_at = np.choose(bio, [BIOMES[0]['tip_at'], BIOMES[1]['tip_at'], BIOMES[2]['tip_at']])
    frost = (mat == 6) & (spike_rel > tip_at + bay * np.where(bio == 2, 0.018, 0.06))
    sel_mat = np.where(spire, -2, sel_mat)
    sel_mat = np.where(frost, -3, sel_mat)
    sel_mat = np.where((mat == 6) & (sel_mat == 6), 1, sel_mat)   # gentle spire feet read as mesa rock
    # ice: snow clings to every ledge of the charcoal cliffs
    snowy = is_i & ((sel_mat == -1) | (sel_mat == -2)) & ~wall & (nZ > SNOW_LEDGE + 0.14 * tex + bay * 0.018)
    sel_mat = np.where(snowy, 1, sel_mat)
    names = {0: 'ground', 1: 'mesa', 2: 'pit', 3: 'path', 4: 'rock', 9: 'floor', 7: 'walk'}
    # floor: tiled panels with a lit centre
    if floor.any():
        tile = 9.0 * DOME_SCALE
        fu, fv = u[floor], v[floor]
        seam = (np.mod(fu, tile) < 0.7) | (np.mod(fv, tile) < 0.7)
        small = (np.mod(fu, tile / 2) < 0.6) | (np.mod(fv, tile / 2) < 0.6)
        wk = walk_d[floor] < walk_w
        I[floor] = 0.6 + 0.24 * glow[floor] - np.where(wk, 0.13 * small, 0.15 * seam) + 0.025 * tex[floor]
    # forest pools glow from below: ripple bands, no sun needed
    pool = is_f & (sel_mat == 2)
    fx[pool] = 1
    if pool.any():
        rip = np.sin(u[pool] * 0.45 + v[pool] * 0.3 + 2.4 * tex[pool]) + 0.6 * np.sin(np.hypot(u[pool], v[pool]) * 0.21)
        I[pool] = 0.5 + 0.17 * rip + 0.1 * albedo[pool]
    # ice lakes: glossy, with long cracks and a cold sheen
    lake = is_i & (sel_mat == 2)
    if lake.any():
        cr = np.abs(np.sin(u[lake] * 0.21 + 1.7 * tex[lake]) + np.sin(v[lake] * 0.19 - 1.3 * streak[lake]))
        sheen = np.mod(u[lake] * 0.7 + v[lake] * 0.3 + 9 * albedo[lake], 46.0) < 5.0
        I[lake] = I[lake] + 0.08 + 0.22 * (cr < 0.07) + 0.12 * sheen
    for b, bdef in enumerate(BIOMES):
        inb = bio == b
        if not inb.any():
            continue
        for m, name in names.items():
            sel = inb & (sel_mat == m)
            if not sel.any():
                continue
            ramp = bdef['ramps'][name]
            dith = 0.55 if name in ('pit', 'rock') else 0.38
            rgb[sel] = _ramp_px(ramp, I[sel], bay[sel], dith)
            drk[sel] = ramp[1]
            top[sel] = ramp[min(len(ramp) - 1, 6)]

        # cliff faces, crust walls and spires: strata bands
        table = band_table()
        for code, ramps in ((-1, bdef['strata']), (-2, bdef['spike'])):
            cl = inb & (sel_mat == code)
            if not cl.any():
                continue
            zb = Z[cl] + 2.2 * sample(G['strata'], u[cl], v[cl]) + 160
            if code == -2:
                zb = zb / 2.5 + 100
            band = table[np.clip(zb.astype(int), 0, len(table) - 1)] % len(ramps)
            Ic = I[cl]
            idx_all = np.nonzero(cl)[0]
            for k, ramp in enumerate(ramps):
                sb = band == k
                lv = np.clip(np.round(Ic[sb] * (len(ramp) - 1) + bay[cl][sb] * 0.5), 0, len(ramp) - 1).astype(int)
                idx = idx_all[sb]
                rgb[idx] = ramp[lv]
                drk[idx] = ramp[0]
                top[idx] = ramp[-1]
        fr = inb & (sel_mat == -3)
        if fr.any():
            tips = bdef['tips']
            if b == 1:   # crystal tips glow from inside, brightest at the very point
                q = (spike_rel[fr] - tip_at[fr]) / (1 - tip_at[fr])
                lv = np.clip(np.floor(1 + q * 3.6 + bay[fr] * 0.8 + 0.15 * np.maximum(ndl[fr], 0)), 0, len(tips) - 1).astype(int)
            else:
                lv = np.clip(np.round((I[fr] + 0.12) * (len(tips) - 1) + bay[fr] * 0.5), 0, len(tips) - 1).astype(int)
            rgb[fr] = tips[lv]
            drk[fr] = tips[0]
            top[fr] = tips[-1]

    # cool bounce light on faces turned away from the sun (sky + ringed planet fill)
    cool = (sel_mat <= -1) & (nX > 0.35)
    coolc = np.array(A.hex2rgb('#6b6aa6'), np.float32)
    cq = np.where(bay[cool] > -0.1, 0.16, 0.08)
    rgb[cool] = (rgb[cool] * (1 - cq[:, None]) + coolc * cq[:, None]).astype(np.uint8)

    # the crash: scorched ground around the crater and along the trench, with embers
    if scorch:
        cf = CRASH['came_from']
        rx_, ry_ = X - CRASH['X'], Y - CRASH['Y']
        near = np.abs(rx_) + np.abs(ry_) < CRASH['trench'] + CRASH['R'] * 2.2
        if near.any():
            rx_, ry_ = rx_[near], ry_[near]
            along, lat = rx_ * cf[0] + ry_ * cf[1], -rx_ * cf[1] + ry_ * cf[0]
            rc = np.hypot(rx_, ry_) / CRASH['R']
            sc = np.clip(1.55 - rc, 0, 1)
            in_tr = (along > 0) & (along < CRASH['trench'])
            sc = np.maximum(sc, in_tr * np.clip(1.25 - np.abs(lat) / 15.0, 0, 1)
                            * (0.45 + 0.55 * np.clip(1 - along / CRASH['trench'], 0, 1)))
            sc = sc + 0.22 * tex[near] + 0.1 * bay[near]
            idx = np.nonzero(near)[0]
            q = np.clip(np.floor((sc - 0.3) * 3.0) / 3.0, 0, 0.75)[:, None]
            rgb[idx] = (rgb[idx] * (1 - q) + SCORCH * q).astype(np.uint8)
            ember = (sc > 0.85) & (_hash(np.floor(u[near] * 1.5), np.floor(v[near] * 1.5)) > 0.994)
            rgb[idx[ember]] = EMBER[(_hash(u[near][ember], 1.0) > 0.5).astype(int)]
            fx[idx[ember]] = 3

    # warm lamp light pooling on the ground; teal light under the glowing plants
    gl = np.clip(glow, 0, 1)
    gq = np.floor(gl * 3 + bay * 0.9 + 0.5) / 3.0
    warm = np.array([255, 196, 130], np.float32)
    rgb = np.clip(rgb * (1 - 0.32 * gq[:, None]) + warm * 0.32 * gq[:, None], 0, 255).astype(np.uint8)
    bg = np.where(is_f & ~steep, sample(G['bglow'], u, v), 0.0)
    bq = np.clip(np.floor(np.clip(bg, 0, 1) * 3 + bay * 0.9 + 0.2) / 3.0, 0, 1)
    rgb = np.clip(rgb * (1 - 0.2 * bq[:, None]) + BGLOW * 0.2 * bq[:, None], 0, 255).astype(np.uint8)
    fx[is_i & flat & ((sel_mat == 0) | (sel_mat == 1)) & (shadow < 0.3) & (I > 0.72)] = 2
    lt = np.maximum(np.round(gq * 230), np.round(bq * 200))
    lt = np.where((fx == 1) | (fx == 3) | ((sel_mat == -3) & is_f), 255, lt).astype(np.uint8)
    return rgb, drk, top, steep, mat == 6, bio, fx, lt


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
    out[win] = OID['window'] if BASE_POWERED else OID['darkwin']
    return out


def decal_module(part, P):
    q = part.sdf.local(P)
    hx, hy, hz = part.sdf.half
    out = np.full(len(P), OID['metal'])
    side = np.abs(q[:, 1]) > hy - 1.2
    win = side & (q[:, 2] > -0.5) & (q[:, 2] < 3.2) & (np.abs(q[:, 0]) < hx - 3) & (np.mod(q[:, 0], 6.0) < 3.6)
    out[win] = OID['window'] if BASE_POWERED else OID['darkwin']
    out[(q[:, 2] < -hz + 1.6)] = OID['pack']
    out[q[:, 2] > hz - 1.0] = OID['pack']
    return out


def decal_tunnel(part, P):
    s = part.sdf.local(P)
    out = np.full(len(P), OID['pack'])
    out[(np.abs(s - 0.12) < 0.05) | (np.abs(s - 0.88) < 0.05)] = OID['coral']
    return out


def decal_tunnel_white(part, P):
    out = decal_tunnel(part, P)
    out[out == OID['pack']] = OID['white']
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
    if not getattr(part, 'powered', True):
        return out
    front = np.abs(q[:, 1]) > part.sdf.half[1] - 0.6
    dots = front & (np.mod(q[:, 2], 2.4) < 0.9) & (np.abs(q[:, 0]) < 2.6)
    out[dots & (np.mod(np.floor(q[:, 2] / 2.4), 2) == 0)] = OID['screen']
    out[dots & (np.mod(np.floor(q[:, 2] / 2.4), 2) == 1)] = OID['coral']
    return out


# --- models, all built at design size around their anchor -----------------------
DOOR_FRAMES = 12                  # base airlock door: frames of its opening, closed -> open


def decal_tube_white(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['white'])
    end = part.sdf.half - np.abs(q[:, 0])
    out[(end > 1.6) & (end < 2.9)] = OID['coral']                       # coral rings near both ends
    return out


def decal_door_half(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['coral'])
    out[np.abs(q[:, 2] - 2.6) < 0.55] = OID['white']                    # a white band across the door
    out[(q[:, 2] < -5.2)] = OID['dark']                                  # kick plate
    return out


def airlock(d, dirv, open_=0.0):
    """The airlock tunnel out of a dome and its door. The base's airlocks (white rooms) have a
    portal frame and a door of two halves that slide away into side pockets (open_ 0..1),
    showing the dark lock chamber and its amber light behind."""
    C = cam(d['X'], d['Y'], d['Z'])
    dirv = np.array([dirv[0], dirv[1], 0.0])
    a = C + dirv * (d['R0'] - 8) + np.array([0, 0, 6.0])
    b = C + dirv * (d['R0'] + 13) + np.array([0, 0, 6.0])
    Ry = yaw_to(dirv)
    white = d.get('style') == 'band'
    if not white:
        return [P_('tunnel', A.RoundCone(a, b, 6.6, 6.2), 'pack', 'airlock', decal_tunnel),
                P_('door', A.RoundBox(b + dirv * 1.2, (1.6, 7.0, 7.2), 1.2, Ry), 'coral', 'door'),
                P_('doorwin', A.RoundBox(b + dirv * 2.4 + np.array([0, 0, 2.5]), (0.6, 2.4, 1.6), 0.5, Ry),
                   'window' if d['powered'] else 'darkwin', 'door')]
    side = np.array([-dirv[1], dirv[0], 0.0])
    up = np.array([0.0, 0.0, 1.0])
    f = b + dirv * 0.9                                   # the door plane, just off the tube's flat end
    e = open_ * open_ * (3 - 2 * open_)
    parts = [P_('tunnel', A.Disc((a + b) / 2, 6.5, float(np.linalg.norm(b - a)) / 2, 1.2, Ry), 'white', 'airlock',
                decal_tube_white),
             P_('portal', A.RoundBox(f + dirv * 0.5 + up * 7.9, (1.3, 8.4, 1.1), 0.5, Ry), 'white', 'portal'),
             P_('portal', A.RoundBox(f + dirv * 0.5 - up * 6.9, (1.3, 8.4, 0.6), 0.3, Ry), 'dark', 'portal'),
             P_('lamp', A.Sphere(f + dirv * 1.4 + up * 7.9, 0.9), 'deadbulb', 'portal'),
             P_('chamber', A.RoundBox(f - dirv * 0.6, (0.4, 6.4, 6.9), 0.3, Ry), 'darkwin', 'chamber'),
             P_('chamberlight', A.RoundBox(f - dirv * 0.4 + up * 5.7, (0.3, 5.4, 0.75), 0.3, Ry), 'window', 'chamber')]
    for sgn in (1, -1):
        parts.append(P_('portal', A.RoundBox(f + dirv * 0.5 + side * sgn * 7.45, (1.3, 1.0, 7.9), 0.5, Ry), 'white', 'portal'))
        hw = 3.2 * (1 - 0.9 * e)                         # each half telescopes into its pocket
        parts.append(P_('half', A.RoundBox(f - dirv * 0.35 * e + side * sgn * (6.4 - hw), (0.75, hw, 6.9), 0.35, Ry),
                        'coral', f'half{sgn}', decal_door_half))
    return parts


def dome_ring(d):
    C = cam(d['X'], d['Y'], d['Z'] + 1.4)
    return [P_('ring', A.Torus(C, d['R0'], 2.6), 'dark', 'ring', decal_ring if d['powered'] else None)]


def lamp(X, Y, z, on=True):
    base = cam(X, Y, z)
    return [P_('post', A.RoundCone(base, base + np.array([0, 0, 13.0]), 0.8, 0.6), 'dark', 'lamp'),
            P_('head', A.Sphere(base + np.array([0, 0, 14.4]), 1.7), 'glow' if on else 'deadbulb', 'lamp')], \
        base + np.array([0, 0, 14.4])


def base_interior(d):
    C = cam(d['X'], d['Y'], d['Z'] + 0.6)
    parts = []
    hub_c = C + np.array([0, 0, 11.0])
    parts.append(P_('hub', A.Disc(hub_c, 30.0, 11.0, 3.0, UPAX), 'metal', 'hub', decal_hub))
    parts.append(P_('roof', A.Ellipsoid(C + np.array([0, 0, 21.0]), (27.0, 27.0, 9.0)), 'pack', 'hub'))
    parts.append(P_('vent', A.Disc(C + np.array([0, 0, 31.0]), 5.0, 2.2, 1.0, UPAX), 'coral', 'hub'))
    parts.append(P_('mast', A.RoundCone(C + np.array([6, 4, 28.0]), C + np.array([6, 4, 40.0]), 0.7, 0.5), 'dark', 'hubmast'))
    parts.append(P_('mastlight', A.Sphere(C + np.array([6, 4, 41.0]), 1.4), 'glow' if d['powered'] else 'deadbulb', 'hubmast'))
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
        lp, head = lamp(C[0] + X, C[1] + Y, C[2], on=d['powered'])
        parts += [P_(p.name, p.sdf, p.ramp, f'lamp{k}') for p in lp]
        lights.append(head)
    return parts, lights


def command_room(d):
    """The command room: the round hub with its roof vent and mast, crates stacked by the wall."""
    C = cam(d['X'], d['Y'], d['Z'] + 0.6)
    on = d['powered']
    parts = [P_('hub', A.Disc(C + np.array([0, 0, 10.0]), 24.0, 10.0, 3.0, UPAX), 'metal', 'hub', decal_hub),
             P_('roof', A.Ellipsoid(C + np.array([0, 0, 19.0]), (21.5, 21.5, 7.5)), 'pack', 'hub'),
             P_('vent', A.Disc(C + np.array([0, 0, 27.0]), 4.5, 2.0, 1.0, UPAX), 'coral', 'hub'),
             P_('mast', A.RoundCone(C + np.array([5, 3, 24.0]), C + np.array([5, 3, 35.0]), 0.7, 0.5), 'dark', 'hubmast'),
             P_('mastlight', A.Sphere(C + np.array([5, 3, 36.0]), 1.3), 'glow' if on else 'deadbulb', 'hubmast')]
    for k, (du, dv_, z, ramp) in enumerate(((-36, 14, 3.0, 'mustard'), (-31, 21, 3.0, 'coral'), (-34, 17, 8.6, 'mustard'))):
        X, Y = to_cam(du, dv_)
        parts.append(P_('crate', A.RoundBox(C + np.array([X, Y, z]), (3.2, 3.2, 2.8), 0.8, A.rz(math.pi / 4)), ramp, f'crate{k}'))
    X, Y = to_cam(30, -28)
    lp, head = lamp(C[0] + X, C[1] + Y, C[2], on=on)
    parts += [P_(p.name, p.sdf, p.ramp, 'lamp0') for p in lp]
    return parts, [head]


def habitat_room(d):
    """The habitat: a living module, a little garden of bushes and a potted tree."""
    C = cam(d['X'], d['Y'], d['Z'] + 0.6)
    on = d['powered']
    dv = grid_dir(math.radians(-20))
    mc = C + grid_dir(math.radians(110)) * 9 + np.array([0, 0, 7.6])
    parts = [P_('module', A.RoundBox(mc, (15.0, 9.5, 7.6), 4.0, yaw_to(dv)), 'metal', 'mod', decal_module)]
    g = C + grid_dir(math.radians(-60)) * 19
    for k in range(6):
        ang = k * 1.05 + 0.4
        X, Y = to_cam(5 * math.cos(ang), 5 * math.sin(ang))
        parts.append(P_('bush', A.Sphere(g + np.array([X, Y, 2.6]), 3.0 if k % 2 else 2.4), 'leaf' if k % 2 else 'leaf2', 'garden'))
    b = C + grid_dir(math.radians(200)) * 22
    parts += [P_('pot', A.Disc(b + np.array([0, 0, 1.8]), 4.2, 1.8, 0.8, UPAX), 'wood', 'tree'),
              P_('trunk', A.RoundCone(b + np.array([0, 0, 3.0]), b + np.array([0, 0, 9.5]), 1.0, 0.8), 'wood', 'tree'),
              P_('crown', A.Sphere(b + np.array([0, 0, 12.0]), 4.4), 'leaf', 'tree'),
              P_('crown', A.Sphere(b + np.array([1.6, -1.4, 10.2]), 3.0), 'leaf2', 'tree')]
    lp, head = lamp(*(C + grid_dir(math.radians(30)) * 24)[:2], C[2], on=on)
    parts += [P_(p.name, p.sdf, p.ramp, 'lamp0') for p in lp]
    return parts, [head]


def garage_room(d):
    """The garage: the rover parked by a workbench and a rack of tools, crates of spares."""
    C = cam(d['X'], d['Y'], d['Z'] + 0.6)
    on = d['powered']
    rv = C + grid_dir(math.radians(160)) * 8
    Rr = A.rz(math.pi / 4 + 0.35)
    parts = [P_('rover', A.RoundBox(rv + np.array([0, 0, 4.4]), (7.0, 4.2, 2.0), 1.0, Rr), 'mustard', 'rover'),
             P_('cab', A.RoundBox(rv + Rr @ np.array([-1.8, 0, 7.6]), (3.0, 3.4, 1.8), 1.0, Rr), 'metal', 'rover'),
             P_('glass', A.RoundBox(rv + Rr @ np.array([1.0, 0, 7.8]), (0.6, 3.0, 1.3), 0.4, Rr), 'teal', 'rover')]
    for sx in (-4.6, 4.6):
        for sy in (-4.0, 4.0):
            parts.append(P_('wheel', A.Disc(rv + Rr @ np.array([sx, sy, 2.4]), 2.4, 1.0, 0.5, Rr @ A.rz(math.pi / 2)),
                            'tire', 'rover'))
    wb = C + grid_dir(math.radians(-50)) * 20
    parts += [P_('bench', A.RoundBox(wb + np.array([0, 0, 3.2]), (7.0, 3.0, 0.8), 0.4, yaw_to(grid_dir(math.radians(40)))),
                 'wood', 'bench'),
              P_('benchleg', A.RoundBox(wb + np.array([0, 0, 1.4]), (6.0, 2.4, 1.4), 0.4, yaw_to(grid_dir(math.radians(40)))),
                 'dark', 'bench')]
    rack = P_('rack', A.RoundBox(C + grid_dir(math.radians(60)) * 26 + np.array([0, 0, 7.0]), (3.0, 3.0, 7.0), 0.8,
                                 yaw_to(grid_dir(math.radians(60)))), 'dark', 'rack', decal_rack)
    rack.powered = on
    parts.append(rack)
    for k, (du, dv_, z, ramp) in enumerate(((22, 14, 3.0, 'coral'), (26, 9, 3.0, 'mustard'), (24, 12, 8.6, 'coral'))):
        X, Y = to_cam(du, dv_)
        parts.append(P_('crate', A.RoundBox(C + np.array([X, Y, z]), (3.0, 3.0, 2.6), 0.8, A.rz(math.pi / 4)), ramp, f'crate{k}'))
    lp, head = lamp(*(C + grid_dir(math.radians(250)) * 24)[:2], C[2], on=on)
    parts += [P_(p.name, p.sdf, p.ramp, 'lamp0') for p in lp]
    return parts, [head]


def base_corridors():
    """Covered corridors joining the base's rooms: ribbed tubes resting on low footings."""
    rooms = [u for u in dome_units() if u['owner'] == 'base']
    parts = []
    for k, (a, b) in enumerate(BASE_LINKS):
        ua, ub = rooms[a], rooms[b]
        ca, cb = np.array([ua['X'], ua['Y']]), np.array([ub['X'], ub['Y']])
        dirv = (cb - ca) / np.linalg.norm(cb - ca)
        p0, p1 = ca + dirv * (ua['R'] - 18), cb - dirv * (ub['R'] - 18)
        d3 = np.array([dirv[0], dirv[1], 0.0])
        z = ua['Z'] + 17.0
        a3, b3 = cam(p0[0], p0[1], z), cam(p1[0], p1[1], z)
        L = float(np.linalg.norm(p1 - p0))
        if BASE_DESIGN == 'v3':          # smooth white tubes, a seam ring at each end
            parts.append(P_('tube', A.RoundCone(a3, b3, 13.0, 13.0), 'white', f'corr{k}'))
            for t in (14.0, L - 14.0):
                parts.append(P_('rib', A.Torus(a3 + d3 * t, 13.1, 0.9, frame_z(d3)), 'coral', f'corr{k}rib'))
            mid = (a3 + b3) / 2
            parts.append(P_('footing', A.RoundBox(np.array([mid[0], mid[1], ua['Z'] + 2.4]), (L / 2, 7.0, 2.4), 0.8,
                                                  yaw_to(d3)), 'concrete', f'corr{k}foot'))
            continue
        parts.append(P_('tube', A.RoundCone(a3, b3, 13.0, 13.0), 'pack', f'corr{k}', decal_tunnel))
        for t in np.arange(12.0, L - 6, 15.0):
            parts.append(P_('rib', A.Torus(a3 + d3 * t, 13.3, 1.5, frame_z(d3)), 'dark', f'corr{k}rib'))
        mid = (a3 + b3) / 2
        parts.append(P_('footing', A.RoundBox(np.array([mid[0], mid[1], ua['Z'] + 2.4]), (L / 2, 7.0, 2.4), 0.8, yaw_to(d3)),
                        'concrete', f'corr{k}foot'))
    return parts


def nursery_interior(d):
    C = cam(d['X'], d['Y'], d['Z'] + 0.6)
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
    C = cam(d['X'], d['Y'], d['Z'] + 0.6)
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
    C = cam(d['X'], d['Y'], d['Z'] + 0.0)
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
    C = cam(d['X'], d['Y'], d['Z'] + 0.0)
    return ([P_('tower', A.RoundCone(C, C + np.array([0, 0, TOWER_TOP]), 7.5, 3.0), 'red', 'tower', decal_tower),
             P_('deck', A.Disc(C + np.array([0, 0, 112.0]), 11.0, 1.3, 0.6, UPAX), 'metal', 'deck')]
            + tower_dish_parts(C, theta))


def apex_radar(d, theta):
    """Radar on a short mast at the top of a dome."""
    C = cam(d['X'], d['Y'], d['Z'] + 0.0)
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
    C = cam(d['X'], d['Y'], d['Z'] + 0.0)
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


def solar_field():
    if SOLAR_DESIGN == 'field':
        from solar_field_gen import static_models
        return static_models(sys.modules[__name__], lambda X, Y: 0.0)
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


# --- alien flora (world units, built around a ground point; t = animation phase 0..1) ---
def decal_cap(part, P):
    q = part.sdf.local(P) / part.sdf.rad
    out = np.full(len(P), OID[part.ramp])
    out[q[:, 2] < -0.42] = OID[getattr(part, 'gill', 'gill')]             # glowing gills underneath
    spots = (q[:, 2] > 0.05) & (np.sin(q[:, 0] * 9.0 + 1.3) * np.sin(q[:, 1] * 9.0) > 0.72)
    out[spots] = OID['capspot']
    return out


def decal_puff(part, P):
    q = part.sdf.local(P) / max(part.sdf.r, 1e-6)
    out = np.full(len(P), OID['puff'])
    out[np.sin(q[:, 0] * 11.0) * np.sin(q[:, 1] * 11.0 + 0.7) * np.sin(q[:, 2] * 9.0) > 0.42] = OID['pod2']
    return out


def lantern_tree(base, seed, t=0.0):
    """Tall alien mushroom tree: curved stalk, a cap (wide parasol, low dome or a brimmed hat with
    a pointed crown) rimmed with glowing gills, sometimes a glowing veil ring or a second cap on
    a side shoot, and glowing pods hanging from the brim."""
    rs = np.random.default_rng(seed)
    Ht = rs.uniform(44, 72)
    capr = Ht * rs.uniform(0.27, 0.35)
    lean = rs.uniform(-1, 1, 2) * 0.14
    sw = math.sin(TAU * t) * Ht * 0.03
    sw2 = math.sin(TAU * t - 0.9) * 1.3
    p1 = base + np.array([lean[0] * Ht * 0.3 + sw * 0.25, lean[1] * Ht * 0.3, Ht * 0.45])
    p2 = base + np.array([lean[0] * Ht * 0.55 + sw, lean[1] * Ht * 0.55, Ht * 0.86])
    style = int(rs.integers(3))                      # 0 parasol, 1 dome, 2 tiered
    rad = [(capr, capr, capr * 0.3), (capr * 0.9, capr * 0.9, capr * 0.42), (capr, capr, capr * 0.24)][style]
    tilt = frame_z(A.nz([lean[0] * 1.4 + sw / Ht * 0.6, lean[1] * 1.4, 1.0]))
    capc = p2 + np.array([sw * 0.3, 0, rad[2] * 0.55])
    roll = rs.random()
    cap_ramp = 'cap' if roll < 0.45 else ('cap2' if roll < 0.75 else 'cap3')
    gill = 'pod2' if cap_ramp == 'cap3' else 'gill'
    cap = P_('cap', A.Ellipsoid(capc, rad, tilt), cap_ramp, 'cap', decal_cap)
    cap.gill = gill
    parts = [P_('trunk', A.RoundCone(base, p1, Ht * 0.06, Ht * 0.045), 'stem', 'trunk'),
             P_('trunk', A.RoundCone(p1, p2, Ht * 0.045, Ht * 0.03), 'stem', 'trunk'), cap]
    if style == 2:                                   # a second, smaller tier stacked on the cap
        up = tilt[:, 2]
        top = P_('cap', A.Ellipsoid(capc + up * capr * 0.42, (capr * 0.56, capr * 0.56, capr * 0.3), tilt),
                 cap_ramp, 'tier', decal_cap)
        top.gill = gill
        parts += [P_('trunk', A.RoundCone(capc, capc + up * capr * 0.4, capr * 0.12, capr * 0.1), 'stem', 'tier'), top]
    if rs.random() < 0.35:                           # glowing veil ring under the cap
        parts.append(P_('veil', A.Torus(capc - tilt[:, 2] * rad[2] * 0.6, rad[0] * 0.62, max(0.7, capr * 0.07), tilt),
                        gill, 'veil'))
    if rs.random() < 0.35:                           # a smaller cap on a side shoot
        d = grid_dir(rs.uniform(0, TAU))
        q0 = p1 + (p2 - p1) * 0.3
        q1 = q0 + d * Ht * 0.22 + np.array([sw * 0.4, 0, Ht * 0.16])
        r2 = capr * 0.45
        side = P_('cap', A.Ellipsoid(q1 + np.array([0, 0, r2 * 0.2]), (r2, r2, r2 * 0.36), frame_z(A.nz([d[0] * 0.5, d[1] * 0.5, 1.0]))),
                  cap_ramp, 'cap2', decal_cap)
        side.gill = gill
        parts += [P_('trunk', A.RoundCone(q0, q1, Ht * 0.03, Ht * 0.022), 'stem', 'trunk'), side]
    for k in range(3):
        d = grid_dir(rs.uniform(0, TAU))
        parts.append(P_('root', A.RoundCone(base + np.array([0, 0, Ht * 0.05]), base + d * Ht * 0.14 - np.array([0, 0, 0.6]),
                                            Ht * 0.028, Ht * 0.012), 'stem', 'trunk'))
    pod_ramp = 'pod' if rs.random() < 0.5 else 'pod2'
    for k in range(int(rs.integers(3, 6))):
        a = rs.uniform(0, TAU)
        rim = capc + tilt @ np.array([math.cos(a) * rad[0] * 0.72, math.sin(a) * rad[1] * 0.72, -rad[2] * 0.45])
        pod = rim + np.array([sw2, 0, -rs.uniform(4, 10)])
        parts += [P_('strand', A.RoundCone(rim, pod, 0.3, 0.25), 'stem', 'pods'),
                  P_('pod', A.Sphere(pod, rs.uniform(1.3, 2.1)), pod_ramp, 'pods')]
    return parts


def bulb_stalks(base, seed, t=0.0):
    """A clump of thin stalks, each holding up a glowing orb."""
    rs = np.random.default_rng(seed)
    H0 = rs.uniform(14, 28)
    parts = []
    for k in range(3):
        d = grid_dir(rs.uniform(0, TAU))
        parts.append(P_('leaf', A.Ellipsoid(base + d * 2.5 + np.array([0, 0, 0.8]), (4.2, 1.8, 0.9), yaw_to(d)), 'leafa', 'leaves'))
    orb_ramp = ['orb', 'pod', 'pod2'][int(rs.integers(3))]
    for k in range(int(rs.integers(3, 7))):
        d = grid_dir(rs.uniform(0, TAU))
        h = H0 * rs.uniform(0.6, 1.0)
        tilt = rs.uniform(0.05, 0.35)
        sw = math.sin(TAU * t + rs.uniform(0, TAU)) * h * 0.07
        mid = base + d * h * tilt * 0.4 + np.array([sw * 0.4, 0, h * 0.55])
        tip = base + d * h * tilt + np.array([sw, 0, h])
        parts += [P_('stalk', A.RoundCone(base + np.array([0, 0, 1.0]), mid, 0.9, 0.7), 'stem', 'bulbs'),
                  P_('stalk', A.RoundCone(mid, tip, 0.7, 0.5), 'stem', 'bulbs'),
                  P_('orb', A.Sphere(tip + np.array([0, 0, 1.3]), rs.uniform(1.8, 2.8)), orb_ramp, 'bulbs')]
    return parts


def coral_fan(base, seed, t=0.0):
    rs = np.random.default_rng(seed)
    ramp = 'corala' if rs.random() < 0.55 else 'coralb'
    yaw = rs.uniform(0, TAU)
    parts = []
    for k in range(int(rs.integers(5, 10))):
        spread = rs.uniform(-0.9, 0.9)
        d = grid_dir(yaw) * math.sin(spread) * 0.8
        h = rs.uniform(6, 16)
        sw = math.sin(TAU * t + k * 0.7) * h * 0.06
        tip = base + d * h + np.array([sw, 0, h * math.cos(spread * 0.6)])
        parts.append(P_('frond', A.RoundCone(base, tip, 1.4, 0.35), ramp, 'coral'))
        if rs.random() < 0.4:
            parts.append(P_('tip', A.Sphere(tip, 0.9), 'orb' if ramp == 'corala' else 'pod2', 'coral'))
    return parts


def puffball(base, seed, t=0.0):
    rs = np.random.default_rng(seed)
    parts = []
    for k in range(int(rs.integers(2, 5))):
        r = rs.uniform(2.4, 5.0) * (1 + 0.06 * math.sin(TAU * t + k * 1.9))      # breathing
        off = grid_dir(rs.uniform(0, TAU)) * rs.uniform(0, 4.5)
        parts.append(P_('puff', A.Sphere(base + off + np.array([0, 0, r * 0.8]), r), 'puff', 'puff', decal_puff))
    return parts


def curl_fern(base, seed, t=0.0):
    """Fiddlehead tendrils: thick stalks rising and rolling over into tight spirals, glowing at the tip."""
    rs = np.random.default_rng(seed)
    parts = []
    ramp = 'corala' if rs.random() < 0.5 else 'leafa'
    for k in range(int(rs.integers(2, 5))):
        d = grid_dir(rs.uniform(0, TAU))
        h = rs.uniform(9, 19)
        r0 = rs.uniform(1.1, 1.7)
        top = base + d * 1.5 + np.array([math.sin(TAU * t + k) * 0.5, 0, h * 0.7])
        rr0 = h * 0.24 * (1 + 0.07 * math.sin(TAU * t + k * 0.9))                 # coiling and uncoiling
        centre = top + d * rr0
        pts = [base + d * 0.4, base + d * 0.9 + np.array([0, 0, h * 0.35]), top]
        for a in np.linspace(math.pi, math.pi - 1.75 * TAU, 18)[1:]:
            f = (math.pi - a) / (1.75 * TAU)
            rr = rr0 * (1 - 0.82 * f)
            pts.append(centre + rr * (math.cos(a) * d + np.array([0, 0, math.sin(a)])))
        n = len(pts)
        for j in range(n - 1):
            ra = r0 * (1 - 0.7 * j / n)
            rb = r0 * (1 - 0.7 * (j + 1) / n)
            parts.append(P_('frond', A.RoundCone(pts[j], pts[j + 1], ra, rb), ramp, f'curl{k}'))
        parts.append(P_('tip', A.Sphere(pts[-1], r0 * 0.55), 'orb' if ramp == 'leafa' else 'pod2', f'curl{k}'))
    return parts


FLORA = {  # species: builder, variants, animation speed (all of them sway, breathe or coil)
    'tree':  dict(fn=lantern_tree, variants=12, fps=6, animated=True),
    'bulbs': dict(fn=bulb_stalks, variants=8, fps=7, animated=True),
    'coral': dict(fn=coral_fan, variants=8, fps=6, animated=True),
    'puff':  dict(fn=puffball, variants=8, fps=4, animated=True),
    'curl':  dict(fn=curl_fern, variants=8, fps=4, animated=True),
}
ICE_VARIANTS = 8
FLORA_FRAMES = 8
SPECIES = list(FLORA) + ['ice']


def ice_cluster(base, seed, t=0.0):
    """A burst of ice crystals: thick columns with sharp points leaning out from one root,
    a tall one in the middle. A few are huge."""
    rs = np.random.default_rng(seed)
    parts, tips = [], []
    big = 1.7 if seed % 4 == 0 else 1.0
    for k in range(int(rs.integers(4, 8))):
        d = grid_dir(rs.uniform(0, TAU))
        tilt = rs.uniform(0.0, 0.16) if k == 0 else rs.uniform(0.38, 0.9)
        L = (rs.uniform(15, 24) if k == 0 else rs.uniform(6, 14)) * big
        r = L * rs.uniform(0.15, 0.2)
        axis = d * math.sin(tilt) + np.array([0, 0, math.cos(tilt)])
        root = base + d * r * 0.5 - np.array([0, 0, 1.2])
        mid = root + axis * L * 0.7
        tip = root + axis * L
        ramp = 'icex' if rs.random() < 0.6 else 'icex2'
        parts += [P_('shard', A.RoundCone(root, mid, r, r * 0.9), ramp, f'ice{k}'),
                  P_('point', A.RoundCone(mid, tip, r * 0.9, 0.2), ramp, f'ice{k}')]
        tips.append(tip)
    return parts, tips


# --- the crashed satellite -----------------------------------------------------------------
WRECK_SCALE = 1.9


def decal_foil(part, P):
    q = part.sdf.local(P)
    k = WRECK_SCALE
    out = np.full(len(P), OID['foil'])
    seam = (np.mod(q[:, 0] + 0.5, 5.5 * k) < 0.9) | (np.mod(q[:, 2] + 0.4, 4.6 * k) < 0.8)
    out[seam] = OID['metal']
    out[q[:, 0] > part.sdf.half[0] - 2.2 * k] = OID['char']               # the nose took the heat
    return out


def decal_foil_hot(part, P):
    out = decal_foil(part, P)
    out[part.sdf.local(P)[:, 0] > part.sdf.half[0] - 2.6 * WRECK_SCALE] = OID['window']   # glowing re-entry nose
    return out


def satellite_parts(C, Rb, wings, hot=False, tag='sat'):
    """Satellite bus built in its own frame (Rb columns: forward, side, up): gold-foil box, engine
    bell, docking cap, dish, antenna and beacon. wings: list of (side sign, lift angle) still attached."""
    k = WRECK_SCALE
    f, sd, up = Rb[:, 0], Rb[:, 1], Rb[:, 2]
    parts = [P_('body', A.RoundBox(C, np.array([11.0, 7.5, 6.5]) * k, 1.6 * k, Rb), 'foil', f'{tag}body',
                decal_foil_hot if hot else decal_foil),
             P_('cap', A.Disc(C - f * 11.3 * k, 6.0 * k, 1.1 * k, 0.5 * k, Rb), 'metal', f'{tag}body'),
             P_('nozzle', A.RoundCone(C - f * 12.4 * k, C - f * 17.5 * k, 3.0 * k, 4.4 * k), 'char', f'{tag}nozzle')]
    for sgn, lift in wings:
        wd = A.nz(sd * sgn * math.cos(lift) + up * math.sin(lift))
        root = C + sd * sgn * 7.6 * k
        nrm = np.cross(f, wd)
        Rw = np.stack([f, wd, nrm if nrm[2] >= 0 else -nrm], axis=1)       # panel face to the sky
        parts += [P_('strut', A.RoundCone(root, root + wd * 4.0 * k, 0.9 * k, 0.8 * k), 'dark', f'{tag}wing{sgn}'),
                  P_('wing', A.RoundBox(root + wd * 14.0 * k, np.array([8.5, 10.0, 0.6]) * k, 0.4 * k, Rw), 'panel',
                     f'{tag}wing{sgn}', decal_panel)]
    dish_c = C + up * 7.4 * k + f * 4.0 * k
    rod0 = C + up * 6.0 * k - f * 5.0 * k
    parts += [P_('dish', A.Ellipsoid(dish_c, np.array([4.6, 4.6, 1.1]) * k, frame_z(A.nz(up + f * 0.5))), 'metal', f'{tag}dish'),
              P_('rod', A.RoundCone(rod0, rod0 + up * 7.0 * k - f * 2.0 * k, 0.5 * k, 0.4 * k), 'dark', f'{tag}rod'),
              P_('beacon', A.Sphere(rod0 + up * 7.4 * k - f * 2.1 * k, 1.1 * k), 'beacon', f'{tag}rod')]
    return parts, rod0 + up * 7.4 * k - f * 2.1 * k


def satellite_intact(C, roll):
    """Coming in: nose down along the trench, tumbling slowly, nose glowing from re-entry."""
    cf = np.array([*CRASH['came_from'], 0.0])
    Rb = yaw_to(-cf) @ A.ry(math.radians(16)) @ A.rx(roll)
    parts, _ = satellite_parts(C, Rb, [(1, 0.0), (-1, 0.0)], hot=True)
    return parts


def satellite_wreck(ground):
    """Gold-foil satellite nosed into its crater, one solar wing bent up, the other torn off and
    lying back along the trench. Returns parts, the points the game animates, and debris spots."""
    k = WRECK_SCALE
    cf = np.array([*CRASH['came_from'], 0.0])
    fwd = -cf
    side = np.array([-fwd[1], fwd[0], 0.0])
    C = cam(CRASH['X'], CRASH['Y'], ground(CRASH['X'], CRASH['Y']))
    Rb = yaw_to(fwd) @ A.ry(math.radians(22)) @ A.rx(math.radians(-14))   # nose dug in, rolled over
    body_c = C + np.array([0, 0, 5.0 * k])
    parts, beacon = satellite_parts(body_c, Rb, [(-1, math.radians(34))], tag='w')
    # the torn-off wing, flat in the trench, and a bent strut stub where it was
    wx, wy = CRASH['X'] + cf[0] * 92, CRASH['Y'] + cf[1] * 92
    Rl = yaw_to(side) @ A.rx(math.radians(7)) @ A.rz(0.45)
    parts.append(P_('lostwing', A.RoundBox(cam(wx, wy, ground(wx, wy) + 0.9 * k), np.array([8.5, 10.0, 0.6]) * k, 0.4 * k, Rl),
                    'panel', 'lostwing', decal_panel))
    stub = body_c + Rb[:, 1] * 7.6 * k
    parts.append(P_('stub', A.RoundCone(stub, stub + Rb[:, 1] * 3.0 * k - Rb[:, 2] * 1.5 * k, 0.9 * k, 0.6 * k), 'dark', 'wstub'))
    rs = np.random.default_rng(SEED + 404)
    debris = []
    for j in range(18):
        s_ = rs.uniform(16, CRASH['trench'] - 8)
        lat = rs.uniform(-15, 15) * (0.5 + s_ / CRASH['trench'])
        X = CRASH['X'] + cf[0] * s_ + side[0] * lat
        Y = CRASH['Y'] + cf[1] * s_ + side[1] * lat
        size = rs.uniform(0.9, 2.8)
        R = A.rz(rs.uniform(0, TAU)) @ A.rx(rs.uniform(-0.6, 0.6))
        parts.append(P_('debris', A.RoundBox(cam(X, Y, ground(X, Y) + size * 0.35), (size * 1.6, size, size * 0.5), 0.3, R),
                        ['foil', 'metal', 'dark', 'panel', 'char'][j % 5], f'debris{j}'))
        debris.append((X, Y, size * 1.6))
    nozzle_end = body_c - Rb[:, 0] * 17.5 * k
    fx = dict(smoke=[body_c + np.array([0, 0, 9.0 * k]), nozzle_end + np.array([0, 0, 2.0]),
                     cam(wx, wy, ground(wx, wy) + 2.0)],
              sparks=[stub + Rb[:, 1] * 3.0 * k, beacon - Rb[:, 2] * 2.0],
              beacon=beacon, fire=[nozzle_end])
    return parts, fx, debris, dict(X=float(body_c[0]), Y=float(body_c[1]), z=float(body_c[2]))


# ================================================================== sprites: plants, crystals, the satellite
def sprite_box(frames_parts, pad=3):
    """Image rect (x0, y0, w, h) that holds every frame of a model."""
    lo, hi = np.array([np.inf, np.inf]), np.array([-np.inf, -np.inf])
    for parts in frames_parts:
        for p in parts:
            c, r = part_bound(p.sdf)
            px, py = project(*c)
            lo = np.minimum(lo, [px - r / S, py - r / S])
            hi = np.maximum(hi, [px + r / S, py + r / S])
    x0, y0 = int(math.floor(lo[0])) - pad, int(math.floor(lo[1])) - pad
    return x0, y0, int(math.ceil(hi[0])) + pad - x0, int(math.ceil(hi[1])) + pad - y0


def render_sprite(parts, box):
    global EMIT
    x0, y0, w, h = box
    img = np.zeros((h, w, 3), np.uint8)
    Dc = np.full((h, w), np.inf, np.float32)
    kind = np.zeros((h, w), np.uint8)
    gid = np.zeros((h, w), np.int32)
    outer, EMIT = EMIT, np.zeros((h, w), np.uint8)
    try:
        render_groups(parts, img, Dc, kind, gid, 1, x0, y0)
        emit = EMIT
    finally:
        EMIT = outer
    depth_lines(img, img, Dc, kind, gid)
    filled = kind > 0
    pad = np.pad(filled, 1)
    ring = (pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]) & ~filled
    return dict(rgb=img, D=Dc, gid=gid, filled=filled, ring=ring, emit=np.where(filled, emit, 0).astype(np.uint8))


def sprite_rgba(fr, haze=None, amount=0.0):
    rgb = fr['rgb'].astype(np.float32)
    if haze is not None:
        rgb = rgb * (1 - amount) + haze * amount
    rgb = rgb.astype(np.uint8)
    rgb[fr['ring']] = OUTLINE
    return np.dstack([rgb, np.where(fr['filled'] | fr['ring'], 255, 0).astype(np.uint8)])


def _clip_rect(gx, gy, h, w):
    ya, yb, xa, xb = max(0, gy), min(H, gy + h), max(0, gx), min(W, gx + w)
    if yb <= ya or xb <= xa:
        return None
    return (slice(ya, yb), slice(xa, xb)), (slice(ya - gy, yb - gy), slice(xa - gx, xb - gx))


def bake_sprite(fr, gx, gy, dY, img, D, kind, gid, gid_base):
    rr = _clip_rect(gx, gy, *fr['filled'].shape)
    if rr is None:
        return
    g, l = rr
    depth = fr['D'][l] + dY
    m = fr['filled'][l] & (depth < D[g])
    img[g][m] = fr['rgb'][l][m]
    D[g][m] = depth[m]
    kind[g][m] = 3
    gid[g][m] = gid_base + fr['gid'][l][m]
    if EMIT is not None:
        EMIT[g][m] = fr['emit'][l][m]


def glass_front(gx, gy, h, w):
    """Depth of the nearest dome glass over an image rect (inf where there is none)."""
    out = np.full((h, w), np.inf, np.float32)
    for d in dome_units():
        cx, cy = project(d['X'], d['Y'], d['Z'])
        rp = d['R'] / S
        if gx > cx + rp or gx + w < cx - rp or gy > cy + rp or gy + h < cy - rp:
            continue
        jj, ii = np.mgrid[gy:gy + h, gx:gx + w]
        sx = ((ii + 0.5 - AX) * S).ravel()
        sy = ((AY - (jj + 0.5)) * S).ravel()
        O = sx[:, None] * CR + sy[:, None] * CU - F * 6000.0
        oc = O - cam(d['X'], d['Y'], d['Z'] + 0.0)
        b = oc @ F
        disc = b * b - (np.einsum('ij,ij->i', oc, oc) - d['R'] ** 2)
        P1 = O + (-b - np.sqrt(np.maximum(disc, 0)))[:, None] * F
        hit = (disc > 0) & (P1[:, 2] >= d['Z'])
        out = np.minimum(out, np.where(hit, P1[:, 1], np.inf).reshape(h, w).astype(np.float32))
    return out


def paint_live(final, live, sprites):
    """Swaying plants on top of a finished image (for the minimap and the previews)."""
    for pl in live:
        fr = sprites[(pl['species'], pl['variant'])]['frames'][0]
        rgba = sprite_rgba(fr, HAZES[1], 0.09)
        rr = _clip_rect(pl['gx'], pl['gy'], *fr['filled'].shape)
        if rr is None:
            continue
        g, l = rr
        m = rgba[l][..., 3] > 0
        final[g][m] = rgba[l][..., :3][m]


HALO_SIZES = [2, 3, 5, 8, 12, 18]             # halo radii in map px (anim/halos.png)
GLOW_COLORS = ['#5fe8d0', '#f070e0', '#c0f060', '#60d8f8', '#ff9a48', '#e8f6ff', '#d070f0', '#ff5a4a']
GLOW_OF = {'gill': 0, 'pod2': 1, 'pod': 2, 'orb': 3}


def halo_index(r_px):
    return int(np.argmin([abs(h - r_px) for h in HALO_SIZES]))


def sprite_glows(parts, fr, box):
    """Glow points of one frame, relative to the sprite corner: [x, y, halo, colour, strength]."""
    x0, y0, w, h = box
    out = []
    for p in parts:
        sdf, fwd = (p.sdf.inner, p.sdf.fwd) if isinstance(p.sdf, TurnZ) else (p.sdf, lambda q: q)
        if p.ramp in ('pod', 'pod2', 'orb') and isinstance(sdf, A.Sphere):
            c, r = fwd(sdf.c), sdf.r
            px, py = project(*c)
            ix, iy = int(px) - x0, int(py) - y0
            if 0 <= ix < w and 0 <= iy < h and fr['D'][iy, ix] > c[1] - r - 0.8:
                out.append([ix, iy, halo_index(r / S * 2.6), GLOW_OF[p.ramp], 230])
        elif p.name == 'cap':
            c = fwd(sdf.c - np.array([0, 0, sdf.rad[2] * 0.7]))
            px, py = project(*c)
            out.append([int(px) - x0, int(py) - y0, halo_index(sdf.rad[0] / S * 0.75),
                        GLOW_OF[getattr(p, 'gill', 'gill')], 110])
    return out


def flora_offset(X, Y, z):
    """Whole-pixel shift from the model's origin render to its spot on the map."""
    return int(round(X / S)), int(round(-(KY * Y + z) * PX))


PLANT_DEPTH_B = 96                 # depth png blue for pixels of a live plant (glass is 255)


def depth_row(fr):
    """A frame's depth (world Y relative to the plant's foot) in red: v = (d + 64) * 2, 0 = empty.
    Outline pixels take the depth of the plant pixel next to them. Green is 255 where the plant
    glows on its own (it stays lit at night)."""
    d = fr['D']
    pad = np.pad(d, 1, constant_values=np.inf)
    nb = np.minimum.reduce([pad[:-2, 1:-1], pad[2:, 1:-1], pad[1:-1, :-2], pad[1:-1, 2:]])
    d = np.where(fr['ring'], nb, d)
    v = np.where(np.isfinite(d), np.clip(np.round((d + 64) * 2), 1, 255), 0).astype(np.uint8)
    return np.dstack([v, fr['emit'], v, np.full(v.shape, 255, np.uint8)])


def behind_glass(fr, gx, gy, dY, tol=3.0):
    h, w = fr['filled'].shape
    return (fr['filled'] & (fr['D'] + dY > glass_front(gx, gy, h, w) + tol)).sum() > 4


def render_flora(G, img, D, kind, gid, gb):
    """Render every species once (several variants, 8 frames each for the forest), then put each
    plant on the map. Forest plants become game sprites: they sway, and the game hides whatever
    part of them the map covers (each sheet carries a depth row under its colour row). Ice
    crystals are baked into the picture. Returns the next free group id and the game data."""
    t0 = time.time()
    fdir = os.path.join(OUT, 'flora')
    os.makedirs(fdir, exist_ok=True)
    sheets, sheet_of = [], {}
    sprites = {}
    for name in SPECIES:
        spec = FLORA.get(name, dict(animated=False))
        for v in range(variant_count(name)):
            nf = FLORA_FRAMES if spec['animated'] else 1
            frames_parts = [turned(variant_parts(name, v, f / nf), about=np.zeros(3)) for f in range(nf)]
            box = sprite_box(frames_parts)
            frs = [render_sprite(fp, box) for fp in frames_parts]
            glows = [sprite_glows(fp, fr, box) for fp, fr in zip(frames_parts, frs)]
            tips = [vrot(t) for t in ice_cluster(np.zeros(3), variant_seed(name, v))[1]] if name == 'ice' else []
            sprites[(name, v)] = dict(frames=frs, box=box, glows=glows, tips=tips)
            if spec['animated']:
                colour = np.concatenate([sprite_rgba(fr, HAZES[1], 0.09) for fr in frs], axis=1)
                depth = np.concatenate([depth_row(fr) for fr in frs], axis=1)
                fn = f'flora/{name}_{v}{SFX}.png'
                save_png(Image.fromarray(np.vstack([colour, depth])), os.path.join(OUT, fn))
                sheet_of[(name, v)] = len(sheets)
                sheets.append(dict(file=fn, frames=nf, fps=spec['fps'], frame_size=[box[2], box[3]], glows=glows,
                                   anchor=[round(AX - box[0], 1), round(AY - box[1], 1)]))
    print(f'flora sprites rendered in {time.time() - t0:.1f}s')

    baked, live = [], []
    for pl in G['flora']:
        dx, dy = flora_offset(pl['X'], pl['Y'], pl['z'])
        sp = sprites[(pl['species'], pl['variant'])]
        pl['gx'], pl['gy'] = sp['box'][0] + dx, sp['box'][1] + dy
        inside = pl['gx'] >= 0 and pl['gy'] >= 0 and pl['gx'] + sp['box'][2] <= W and pl['gy'] + sp['box'][3] <= H
        if not inside:
            continue
        if pl['species'] == 'ice' or behind_glass(sp['frames'][0], pl['gx'], pl['gy'], pl['Y']):
            bake_sprite(sp['frames'][0], pl['gx'], pl['gy'], pl['Y'], img, D, kind, gid, gb)   # glass goes over it
            gb += 8
            baked.append(pl)
        else:
            live.append(pl)
    live.sort(key=lambda pl: -pl['Y'])                               # far ones first
    instances = []
    for pl in live:
        phase = (pl['X'] * 0.0021 + pl['Y'] * 0.0013 + (hash((pl['variant'], int(pl['X']))) % 97) / 97 * 0.35) % 1.0
        instances.append([sheet_of[(pl['species'], pl['variant'])], pl['gx'], pl['gy'], round(phase, 3),
                          int(round(pl['Y'] * 16))])
    print(f'flora: {len(live)} swaying sprites, {len(baked)} baked in (crystals, plants behind glass) ({time.time() - t0:.1f}s)')
    return gb, dict(sheets=sheets, instances=instances, depth_scale=16), live, baked, sprites


def live_glow_flags(flora_out, live, sprites, D):
    """1 if a plant's lights are not hidden behind scenery (so their halos may be drawn)."""
    for inst, pl in zip(flora_out['instances'], live):
        sp = sprites[(pl['species'], pl['variant'])]
        fr = sp['frames'][0]
        ok = 1
        for x, y, *_ in sp['glows'][0]:
            gx, gy = pl['gx'] + x, pl['gy'] + y
            if not (0 <= y < fr['D'].shape[0] and 0 <= x < fr['D'].shape[1] and 0 <= gx < W and 0 <= gy < H):
                continue
            if np.isfinite(fr['D'][y, x]) and D[gy, gx] < fr['D'][y, x] + pl['Y'] - 2.0:
                ok = 0
                break
        inst.append(ok)


def flora_depth(live, sprites, D, kind):
    """The swaying plants are left out of the picture, but the astronaut still walks behind them:
    put their depth into the depth map, tagged so the plant shader knows to ignore it."""
    for pl in live:
        fr = sprites[(pl['species'], pl['variant'])]['frames'][0]
        rr = _clip_rect(pl['gx'], pl['gy'], *fr['filled'].shape)
        if rr is None:
            continue
        g, l = rr
        depth = fr['D'][l] + pl['Y']
        m = fr['filled'][l] & (depth < D[g])
        D[g][m] = depth[m]
        kind[g][m] = 5


def static_glows(baked, sprites, D):
    """Glow points of the baked plants that are still visible: [x, y, halo, colour, strength, kind, phase]."""
    out = []
    for pl in baked:
        sp = sprites[(pl['species'], pl['variant'])]
        fr = sp['frames'][0]
        for x, y, hi, ci, st in sp['glows'][0]:
            gx, gy = pl['gx'] + x, pl['gy'] + y
            if not (0 <= y < fr['D'].shape[0] and 0 <= x < fr['D'].shape[1] and 0 <= gx < W and 0 <= gy < H):
                continue
            if np.isfinite(fr['D'][y, x]) and D[gy, gx] > fr['D'][y, x] + pl['Y'] - 1.0:
                out.append([gx, gy, hi, ci, st, 0])
        for tip in sp['tips']:
            px, py = project(pl['X'] + tip[0], pl['Y'] + tip[1], pl['z'] + tip[2])
            ix, iy = int(px), int(py)
            if 0 <= ix < W and 0 <= iy < H and D[iy, ix] > pl['Y'] + tip[1] - 2.0:
                out.append([ix, iy, 0, 5, 255, 3])
    return out


def export_halos():
    """Soft pixel-art halos (white, dithered alpha) in a strip, one per HALO_SIZES radius."""
    size = 2 * HALO_SIZES[-1] + 3
    strip = np.zeros((size, size * len(HALO_SIZES), 4), np.uint8)
    yy, xx = np.mgrid[0:size, 0:size]
    bay = BAYER[yy % 4, xx % 4]
    for k, r in enumerate(HALO_SIZES):
        d = np.hypot(xx + 0.5 - size / 2, (yy + 0.5 - size / 2) * 1.12) / max(r, 1)
        a = np.clip(1 - d, 0, 1) ** 1.6
        lv = np.clip(np.floor(a * 4 + bay * 0.9 + 0.35), 0, 4) / 4.0
        if r <= 2:
            lv = np.where(d < 0.55, 1.0, np.where(d < 1.05, 0.5, 0.0))
        strip[:, k * size:(k + 1) * size, :3] = 255
        strip[:, k * size:(k + 1) * size, 3] = (lv * 255).astype(np.uint8)
    os.makedirs(os.path.join(OUT, 'anim'), exist_ok=True)
    save_png(Image.fromarray(strip), os.path.join(OUT, 'anim', 'halos.png'))
    return dict(file='anim/halos.png', cell=size, radii=HALO_SIZES)


# ================================================================== the crash, before and during
def crash_window():
    """Image rect (x0, y0, x1, y1) around everything the crash changed."""
    cf = CRASH['came_from']
    pts = []
    for s_ in np.linspace(-CRASH['R'] * 1.6, CRASH['trench'] + 24, 14):
        for lat in (-CRASH['R'] * 1.6, 0.0, CRASH['R'] * 1.6):
            X = CRASH['X'] + cf[0] * s_ - cf[1] * lat
            Y = CRASH['Y'] + cf[1] * s_ + cf[0] * lat
            for z in (-CRASH['depth'] - 4, 60.0):
                pts.append(project(X, Y, z))
    pts = np.array(pts)
    return (max(0, int(pts[:, 0].min()) - 8), max(0, int(pts[:, 1].min()) - 8),
            min(W, int(pts[:, 0].max()) + 8), min(H, int(pts[:, 1].max()) + 8))


def render_precrash(G, img, kind, gid, g0, g1):
    """The ground as it was before the satellite came down, as an overlay for the crash scene.
    Only pixels the crash changed are kept; alpha holds when each one gets uncovered."""
    t0 = time.time()
    x0, y0, x1, y1 = crash_window()
    ca0, ca1, cb0, cb1 = G['crash_win']
    H0 = G['H'].copy()
    H0[ca0:ca1, cb0:cb1] -= G['crash_h']
    m = 45
    a0, a1, b0, b1 = max(0, ca0 - m), min(N, ca1 + m), max(0, cb0 - m), min(N, cb1 + m)
    sub = H0[a0:a1, b0:b1]
    Hu, Hv = np.gradient(sub)
    dX, dY = (Hu - Hv) / SQ2, (Hu + Hv) / SQ2
    inv = 1.0 / np.sqrt(dX * dX + dY * dY + 1.0)
    ao = (np.clip((ndi.gaussian_filter(sub, 4) - sub) / 5.0, 0, 1) * 0.8
          + np.clip((ndi.gaussian_filter(sub, 14) - sub) / 18.0, 0, 1) * 0.6)
    inner = (slice(ca0, ca1), slice(cb0, cb1))
    local = (slice(ca0 - a0, ca1 - a0), slice(cb0 - b0, cb1 - b0))
    G0 = dict(G, H=H0)
    for key, val in (('nX', -dX * inv), ('nY', -dY * inv), ('nZ', inv), ('ao', ao)):
        arr = G[key].copy()
        arr[inner] = val[local]
        G0[key] = arr
    sh = G['shadow'].copy()
    sh[inner] = shadow_map(H0, (ca0, ca1, cb0, cb1))
    G0['shadow'] = sh
    hitY, hitZ, kind0 = render_terrain(G0, (x0, x1), (y0, y1))
    img0, dark0, bio0, _ = shade_terrain(G0, hitY, hitZ, kind0, y0, x0, scorch=False)
    depth_lines(img0, dark0, hitY, kind0, np.zeros(kind0.shape, np.int32))
    del G0, H0, sh
    win = (slice(y0, y1), slice(x0, x1))
    wreck = (kind[win] == 3) & (gid[win] >= g0) & (gid[win] < g1)
    diff = ((img[win] != img0).any(axis=-1) & (kind[win] != 3)) | wreck
    diff &= kind0 > 0
    # uncover order: along the trench, from where it touched down to where it stopped
    cf = CRASH['came_from']
    Xw = (np.arange(x0, x1) + 0.5 - AX)[None, :] * S
    along = (Xw - CRASH['X']) * cf[0] + (hitY - CRASH['Y']) * cf[1]
    r = np.clip(along / CRASH['trench'], 0, 1)
    r[wreck] = 0.0
    rgba = np.zeros((y1 - y0, x1 - x0, 4), np.uint8)
    rgba[..., :3] = apply_haze(img0, y0, x0, bio0)
    rgba[..., 3] = np.where(diff, 1 + np.round(r * 254), 0).astype(np.uint8)
    print(f'pre-crash ground: {int(diff.sum())} px in {time.time() - t0:.1f}s')
    return dict(rgba=rgba, x0=x0, y0=y0)


def export_crash(G, pre, wreck_fx, body, kind):
    """Sprites and points for the crash scene and the smoking wreck."""
    adir = os.path.join(OUT, 'anim')
    rgba = pre['rgba']
    h, w = rgba.shape[:2]
    rgba[..., 3] = np.where(kind[pre['y0']:pre['y0'] + h, pre['x0']:pre['x0'] + w] == 4, 0, rgba[..., 3])
    save_png(Image.fromarray(rgba), os.path.join(adir, f'crash_before{SFX}.png'))
    # the satellite coming in, tumbling: rendered high above the origin, nothing under it
    C = cam(0.0, 0.0, 80.0)
    with canonical():
        frames_parts = [satellite_intact(C, f / 8 * TAU) for f in range(8)]
    frames_parts = [turned(fp, about=C) for fp in frames_parts]
    box = sprite_box(frames_parts)
    strip = np.concatenate([sprite_rgba(render_sprite(fp, box)) for fp in frames_parts], axis=1)
    save_png(Image.fromarray(strip), os.path.join(adir, f'satellite{SFX}.png'))
    ox, oy = project(*C)
    cf = np.array(CRASH['came_from'])
    gz = lambda X, Y: height_at(G, X, Y)  # noqa: E731
    td = np.array([CRASH['X'], CRASH['Y']]) + cf * CRASH['trench']
    sky = np.array([CRASH['X'], CRASH['Y']]) + cf * (CRASH['trench'] + 520)

    def px(P):
        x, y = project(*P)
        return [round(float(x), 1), round(float(y), 1)]

    rest = to_view([body['X'], body['Y'], body['z']])
    return dict(
        before=dict(file=f'anim/crash_before{SFX}.png', position=[pre['x0'], pre['y0']]),
        satellite=dict(file=f'anim/satellite{SFX}.png', frames=8, frame_size=[box[2], box[3]],
                       origin=[round(ox - box[0], 1), round(oy - box[1], 1)]),
        sky=px([sky[0], sky[1], gz(*td) + 420]), touchdown=px([td[0], td[1], gz(*td) + 7.0]), rest=px(rest),
        smoke=[px(p) for p in wreck_fx['smoke']], sparks=[px(p) for p in wreck_fx['sparks']],
        fire=[px(p) for p in wreck_fx['fire']], beacon=px(wreck_fx['beacon']),
        focus=px([CRASH['X'] + cf[0] * CRASH['trench'] * 0.45, CRASH['Y'] + cf[1] * CRASH['trench'] * 0.45,
                  gz(CRASH['X'], CRASH['Y'])]),
        world=[round(float(v), 2) for v in to_canon([CRASH['X'], CRASH['Y']])])


def height_at(G, X, Y):
    u, v = to_grid(X, Y)
    return float(ndi.map_coordinates(G['H'], [[u - 0.5], [v - 0.5]], order=1)[0])


# --- ray-marched compositing --------------------------------------------------------
def part_bound(sdf):
    if isinstance(sdf, TurnZ):
        c, r = part_bound(sdf.inner)
        return sdf.fwd(c), r
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
                if isinstance(p.sdf, TurnZ):                   # decals work in the model's own frame
                    q = A.Part(p.name, p.sdf.inner, p.ramp, p.group, decal=p.decal)
                    ramp[sel] = p.decal(q, p.sdf.back(P[sel]))
                else:
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
    if EMIT is not None and EMIT.shape == img.shape[:2]:
        EMIT[yy, xx] = np.where(emis[front], 255, 0)
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
    C = cam(d['X'], d['Y'], d['Z'] + 0.0)
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
    mb = ok & (P2[:, 2] >= d['Z']) & (P2[:, 1] < Dv) & holed(P2)
    n2 = (P2 - C) / R
    col[mb] = col[mb] * 0.9 + GLASS * 0.1
    rb = mb & ribs(P2, n2)
    col[rb] = col[rb] * 0.55 + RIB[1] * 0.45

    # front shell
    mf = ok & (P1[:, 2] >= d['Z']) & (P1[:, 1] < Dv) & holed(P1)
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


# ================================================================== the main base: a honeycomb dome
HEX_FREQ = 6                      # geodesic frequency of the honeycomb shell
STRUT_W = 2.2                     # half-width of a frame bar, world units
# where the shell was smashed in: direction from the dome centre, angular radius, share of panes gone
BREACHES = [(A.nz([0.653, -0.600, 0.469]), math.radians(23.0), 0.92),
            (A.nz([-0.50, 0.62, 0.60]), math.radians(12.0), 0.8)]
ROOM_BREACHES = {
    'base':    BREACHES,                                                   # the single-dome version
    'command': [(A.nz([0.70, -0.62, 0.42]), math.radians(22.0), 0.9)],    # its glass smashed in, facing the way out
    'garage':  [(A.nz([-0.22, -0.90, 0.36]), math.radians(15.0), 0.85)],  # its metal skin torn open
    'habitat': [(A.nz([-0.55, 0.55, 0.62]), math.radians(11.0), 0.7)],
}


BAND_BREACHES = {   # v3: where each room's ring of glass was smashed (the metal held)
    'command': [(A.nz([0.72, -0.60, 0.55]), math.radians(20.0), 0.75), (A.nz([-0.9, 0.2, 0.55]), math.radians(9.0), 0.6)],
    'garage':  [(A.nz([-0.25, -0.86, 0.56]), math.radians(16.0), 0.7)],
    'habitat': [(A.nz([-0.60, 0.48, 0.58]), math.radians(12.0), 0.6)],
}


def unit_breaches(u):
    if u['owner'] != 'base':
        return []
    return (BAND_BREACHES if BASE_DESIGN == 'v3' else ROOM_BREACHES).get(u['name'], [])
SKY_REF = hexa('#100e24', '#1c1a3e', '#2b2f60', '#424c88', '#6676b0', '#a2b6de').astype(np.float32)
HOR_REF = hexa('#3a1f36', '#683246', '#a5585c', '#e19478').astype(np.float32)
GND_REF = hexa('#1c1120', '#341a26', '#55262f', '#7d3a37').astype(np.float32)
PLANET_REF = hexa('#2a2c56', '#4f5689', '#8f97c4').astype(np.float32)
CHROME = hexa('#454d63', '#7a839a', '#b6bed0', '#e8edf6').astype(np.float32)
PANEL_BASE = np.array(A.hex2rgb('#161a2e'), np.float32)
PANEL_BACK = hexa('#17141f', '#221e2e', '#2f2a3e').astype(np.float32)
IRIS = hexa('#37d0c0', '#9a6ae0', '#f0b860').astype(np.float32)
GLASS_DUST = np.array(A.hex2rgb('#8a5a4a'), np.float32)
GLINT = np.array(A.hex2rgb('#fffbf2'), np.float32)
PLANET_DIR = A.nz([0.62, 0.55, 0.56])
_HEX = {}


def hex_cells(u):
    """Cells of the honeycomb shell: a Goldberg polyhedron (the dual of a geodesic icosphere),
    a five-sided cell at the very top. Each cell gets its make-up - glass, mirror panel, cracked
    glass or smashed - and its own crack pattern."""
    if u['name'] in _HEX:
        return _HEX[u['name']]
    from scipy.spatial import cKDTree
    phi = (1 + 5 ** 0.5) / 2
    V = np.array([(-1, phi, 0), (1, phi, 0), (-1, -phi, 0), (1, -phi, 0), (0, -1, phi), (0, 1, phi),
                  (0, -1, -phi), (0, 1, -phi), (phi, 0, -1), (phi, 0, 1), (-phi, 0, -1), (-phi, 0, 1)], float)
    V /= np.linalg.norm(V, axis=1)[:, None]
    faces = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
             (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
             (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    a, up = V[0], np.array([0.0, 0.0, 1.0])
    v = np.cross(a, up)
    sn, cs = np.linalg.norm(v), a @ up
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    V = V @ (A.rz(0.3) @ (np.eye(3) + vx + vx @ vx * ((1 - cs) / sn ** 2))).T
    f = u['freq']
    pts = []
    for i0, i1, i2 in faces:
        for i in range(f + 1):
            for j in range(f + 1 - i):
                q = (V[i0] * i + V[i1] * j + V[i2] * (f - i - j)) / f
                pts.append(q / np.linalg.norm(q))
    pts = np.array(pts)
    _, first = np.unique(np.round(pts, 5), axis=0, return_index=True)
    Cc = pts[np.sort(first)]
    Cc = Cc[Cc[:, 2] > -0.3]
    n = len(Cc)
    rs = np.random.default_rng(SEED + 515 + sum(map(ord, u['name'])))
    el = np.degrees(np.arcsin(Cc[:, 2]))
    breaches = unit_breaches(u)
    # 0 glass, 1 mirror panel, 2 smashed glass, 3 cracked glass, 4 torn-open panel
    if BASE_DOME == 'rooms':
        glassy = (el > GLASS_BAND[0]) & (el < GLASS_BAND[1])
        kind = np.where(glassy, 0, 1).astype(np.uint8)
        kind[glassy & (rs.random(n) < 0.18)] = 3
        for B, rad, share in breaches:
            ang = np.arccos(np.clip(Cc @ B, -1, 1))
            kind[glassy & (ang < rad * 1.7) & (rs.random(n) < 0.7)] = 3
            hit = (ang < rad) & (rs.random(n) < share)
            kind[hit & glassy] = 2
            kind[hit & ~glassy & (el > 6)] = 4
        kind[glassy & (rs.random(n) < 0.05)] = 2
    else:
        kind = np.zeros(n, np.uint8)
        kind[rs.random(n) < 0.12] = 3
        for B, rad, share in breaches:
            ang = np.arccos(np.clip(Cc @ B, -1, 1))
            kind[(ang < rad * 1.7) & (rs.random(n) < 0.7)] = 3
            kind[(ang < rad) & (rs.random(n) < share)] = 2
        kind[(rs.random(n) < 0.05) & (el > 18) & (el < 68)] = 2      # single panes knocked out here and there
        kind[(el < 13) | (el > 74) | ((rs.random(n) < 0.14) & (kind != 2))] = 1
    soot = np.zeros(n, bool)                                     # mirror panels blackened around the impact
    for B, rad, share in breaches:
        soot |= np.arccos(np.clip(Cc @ B, -1, 1)) < rad * 2.1
    e1 = np.cross(up, Cc)
    e1[np.linalg.norm(e1, axis=1) < 1e-6] = (1.0, 0.0, 0.0)
    e1 /= np.linalg.norm(e1, axis=1)[:, None]
    _HEX[u['name']] = dict(C=Cc, tree=cKDTree(Cc), kind=kind, e1=e1, e2=np.cross(Cc, e1),
                imp=rs.uniform(-7, 7, (n, 2)), rad_a=rs.uniform(0, TAU, (n, 7)), rad_l=rs.uniform(9, 30, (n, 7)),
                rings=rs.uniform([3.5, 9.0], [7.0, 15.0], (n, 2)), ph=rs.uniform(0, TAU, (n, 3)),
                hue=rs.integers(0, 3, n), soot=soot)
    print(f"honeycomb {u['name']}: {n} cells, {int((kind == 2).sum())} smashed panes, {int((kind == 4).sum())} torn panels, "
          f"{int((kind == 3).sum())} cracked, {int((kind == 0).sum() + (kind == 3).sum())} glass")
    return _HEX[u['name']]


def hex_shell(Q, C0, R, H):
    """Where points Q on the dome sphere fall on the shell: their cell, the neighbouring cell, the
    distance to the cell's edge and to the nearest frame joint (world units), and the point in
    the cell's own plane (x along the ground, y up the shell)."""
    u = (Q - C0) / R
    u /= np.maximum(np.linalg.norm(u, axis=1), 1e-9)[:, None]
    dd, ii = H['tree'].query(u, k=3)
    C = H['C']
    c1 = C[ii[:, 0]]
    b = (dd[:, 1] ** 2 - dd[:, 0] ** 2) / (2 * np.linalg.norm(C[ii[:, 1]] - c1, axis=1)) * R
    b3 = (dd[:, 2] ** 2 - dd[:, 0] ** 2) / (2 * np.linalg.norm(C[ii[:, 2]] - c1, axis=1)) * R
    cell = ii[:, 0]
    rel = (u - c1) * R
    return (cell, ii[:, 1:3], b, b3, np.einsum('ij,ij->i', rel, H['e1'][cell]),
            np.einsum('ij,ij->i', rel, H['e2'][cell]))


def crack_lines(cell, lx, ly, H, w=0.34):
    """Spider-web cracks around each pane's impact point: zig-zag rays and broken rings."""
    dx, dy = lx - H['imp'][cell, 0], ly - H['imp'][cell, 1]
    r = np.hypot(dx, dy)
    th = np.arctan2(dy, dx)
    m = r < 1.3
    for k in range(7):
        dt = th - H['rad_a'][cell, k]
        along = r * np.cos(dt)
        perp = r * np.sin(dt) - 0.22 * np.sin(along * 0.6 + k * 1.7)
        m |= (along > 0) & (along < H['rad_l'][cell, k]) & (np.abs(perp) < w)
    for j in range(2):
        ring = H['rings'][cell, j] * (1 + 0.14 * np.sin(th * 5 + H['ph'][cell, j]))
        m |= (np.abs(r - ring) < w) & (np.sin(th * 3 + H['ph'][cell, 2] + j) > -0.25)
    return m


def hex_layers(cell, other, b, b3, lx, ly, H):
    """What the shell is at each point: frame bar, nothing (smashed out), glass, mirror panel,
    plus crack lines and the bright torn edges of broken glass and ripped metal."""
    kk = H['kind']
    k1, k2, k3 = kk[cell], kk[other[:, 0]], kk[other[:, 1]]
    s1, s2, s3 = (k1 == 2) | (k1 == 4), (k2 == 2) | (k2 == 4), (k3 == 2) | (k3 == 4)
    th = np.arctan2(ly, lx)
    jag = 1.4 + 4.8 * np.abs(np.sin(th * 3 + H['ph'][cell, 0]) * np.sin(th * 7 + H['ph'][cell, 1]))
    # a bar between two broken cells is torn away, all but a jagged stub at a joint that still
    # holds something; joints with nothing left around them are gone completely
    gone = s1 & s2 & (s3 | (b3 > STRUT_W * 2.4 + 3.0 * np.abs(np.sin(b3 * 0.7 + H['ph'][cell, 2]))))
    frame = (b < STRUT_W) & ~gone
    fringe = s1 & ~frame & ~gone & (b < STRUT_W + jag)
    hole = (s1 & ~frame & ~fringe) | ((b < STRUT_W) & gone)
    panel = ((k1 == 1) | ((k1 == 4) & fringe)) & ~frame
    glass = ~frame & ~panel & ~hole
    crack = glass & ((k1 == 3) | ((k1 == 2) & fringe)) & crack_lines(cell, lx, ly, H)
    torn = fringe & (b > STRUT_W + jag - 0.8)
    return frame, hole, glass, panel, crack, torn


def env_reflect(n, bay, glint_at=0.993):
    """What a mirror with normal n shows the camera: banded sky, a rose horizon, the rust ground,
    the ringed planet, and the sun as a hard glint (returned as a mask)."""
    r = F[None, :] - 2 * (n @ F)[:, None] * n
    rz = r[:, 2]
    out = np.zeros((len(n), 3), np.float32)
    sky = rz > 0.14
    gnd = rz <= -0.08
    hor = ~sky & ~gnd
    t = np.clip(1 - rz, 0, 1)
    out[sky] = SKY_REF[np.clip(np.floor(t[sky] * 5.6 + bay[sky] * 0.8), 0, 5).astype(int)]
    hl = 1 - np.abs(rz[hor] - 0.03) / 0.12
    out[hor] = HOR_REF[np.clip(np.floor(hl * 3.8 + bay[hor] * 0.8), 0, 3).astype(int)]
    out[gnd] = GND_REF[np.clip(np.floor((rz[gnd] + 1) / 0.92 * 3.9 + bay[gnd] * 0.8), 0, 3).astype(int)]
    pl = r @ PLANET_DIR
    pm = pl > 0.975
    out[pm] = PLANET_REF[np.clip(np.floor((pl[pm] - 0.975) / 0.025 * 3 + bay[pm] * 0.5), 0, 2).astype(int)]
    sun = r @ SUN
    glint = sun > glint_at
    warm = (sun > glint_at - 0.021) & ~glint
    out[warm] = out[warm] * 0.45 + np.array(A.hex2rgb('#ffe2c4'), np.float32) * 0.55
    out[glint] = GLINT
    return out, glint


def hex_dome(img, D, kind, gid, d, gid_val):
    """The main base: a honeycomb dome of mirror-bright metal bars and iridescent mirror panels
    holding panes of glass - dusty, cracked, and smashed in where something hit it. Drawn band by
    band; returns the image pixels where the sun glints off it."""
    C = cam(d['X'], d['Y'], d['Z'])
    R = d['R']
    HX = hex_cells(d)
    cx, cy = project(*C)
    rp = R / S + 2
    x0, x1 = max(0, int(cx - rp)), min(W, int(cx + rp + 1))
    y0, y1 = max(0, int(cy - rp)), min(H, int(cy + rp + 1))
    front_all = np.zeros((y1 - y0, x1 - x0), bool)
    glints = []
    for r0 in range(y0, y1, 192):
        r1 = min(y1, r0 + 192)
        jj, ii = np.mgrid[r0:r1, x0:x1]
        jj, ii = jj.ravel(), ii.ravel()
        sx = (ii + 0.5 - AX) * S
        sy = (AY - (jj + 0.5)) * S
        O = sx[:, None] * CR + sy[:, None] * CU - F * 6000.0
        oc = O - C
        b_ = oc @ F
        disc = b_ * b_ - (np.einsum('ij,ij->i', oc, oc) - R * R)
        ok = disc > 0
        sq = np.sqrt(np.maximum(disc, 0))
        Dv = D[jj, ii]
        col = img[jj, ii].astype(np.float32)
        kv = kind[jj, ii]
        dv = Dv.copy()
        gv = gid[jj, ii]
        bay = BAYER[jj % 4, ii % 4]
        # --- back of the shell (seen through the glass and the holes)
        P2 = O + (-b_ + sq)[:, None] * F
        mb = np.nonzero(ok & (P2[:, 2] >= C[2]) & (P2[:, 1] < Dv))[0]
        if mb.size:
            cell, oth, bb, b3, lx, ly = hex_shell(P2[mb], C, R, HX)
            frame, hole, glass, panel, crack, torn = hex_layers(cell, oth, bb, b3, lx, ly, HX)
            c = col[mb]
            c[glass] = c[glass] * 0.88 + GLASS * 0.12
            lvb = np.clip(np.floor((bb / STRUT_W) * 2 + bay[mb] * 0.6), 0, 2).astype(int)
            c[panel] = PANEL_BACK[np.clip(1 + (ly[panel] > 0), 0, 2)]
            c[frame] = CHROME[np.clip(lvb[frame], 0, 1)] * 0.7 + c[frame] * 0.3
            col[mb] = c
            solid = frame | panel
            dv[mb[solid]] = P2[mb[solid], 1]
            kv[mb[solid]] = 3
            dv[mb[glass]] = np.minimum(dv[mb[glass]], P2[mb[glass], 1])
            kv[mb[glass]] = np.where(kv[mb[glass]] == 3, 3, 4)
        # --- front of the shell
        P1 = O + (-b_ - sq)[:, None] * F
        fm = ok & (P1[:, 2] >= C[2]) & (P1[:, 1] < Dv)
        mf = np.nonzero(fm)[0]
        front_all[(jj - y0)[mf], (ii - x0)[mf]] = True
        if mf.size:
            Q = P1[mf]
            cell, oth, bb, b3, lx, ly = hex_shell(Q, C, R, HX)
            frame, hole, glass, panel, crack, torn = hex_layers(cell, oth, bb, b3, lx, ly, HX)
            n_s = (Q - C) / R
            n_f = HX['C'][cell]
            by = bay[mf]
            c = col[mf]
            # glass: tinted by angle, a mirror sheen per pane, dust settled along the bottom, cracks
            fres = 1 - np.abs(n_s @ F)
            a = 0.10 + 0.13 * (fres + by * 0.08 > 0.5) + 0.17 * (fres + by * 0.08 > 0.8)
            g = glass
            c[g] = c[g] * (1 - a[g, None]) + GLASS * a[g, None]
            env_f, glint_f = env_reflect(n_f, by)
            c[g] = c[g] * 0.84 + env_f[g] * 0.16
            dusty = g & (ly < -8.0 + 3.0 * np.sin(lx * 0.35 + HX['ph'][cell, 0]) + by * 2.0)
            c[dusty] = c[dusty] * 0.86 + GLASS_DUST * 0.14
            glare = g & (np.mod(lx * 0.7 + ly * 0.7 + HX['ph'][cell, 1] * 6, 26.0) < 1.6) & (HX['hue'][cell] == 0)
            c[glare] = c[glare] * 0.62 + SHINE * 0.38
            c[crack] = c[crack] * 0.42 + SHINE * 0.58
            c[torn] = SHINE
            # mirror panels: flat iridescent facets, an inset seam along the frame
            pn = panel
            if pn.any():
                npn = n_f[pn] * 0.6 + n_s[pn] * 0.4
                npn /= np.linalg.norm(npn, axis=1)[:, None]
                env_p, glint_p = env_reflect(npn, by[pn], 0.9985)
                fr = np.floor((1 - np.abs(npn @ F)) * 3 + by[pn] * 0.7) / 3.0
                tint = IRIS[HX['hue'][cell[pn]]]
                cp = env_p * 0.72 + PANEL_BASE * 0.28
                cp = cp * (1 - 0.24 * fr[:, None]) + tint * 0.24 * fr[:, None]
                streak = np.mod(lx[pn] * 0.55 + ly[pn] * 0.85 + HX['ph'][cell[pn], 1] * 5, 34.0)
                band = (streak < 3.0) | ((streak > 4.8) & (streak < 5.9))
                cp[band] = cp[band] * 0.62 + GLINT * 0.38
                sooty = HX['soot'][cell[pn]] & (np.sin(lx[pn] * 0.21 + ly[pn] * 0.13 + HX['ph'][cell[pn], 2]) + by[pn] * 0.5 > -0.3)
                cp[sooty] = cp[sooty] * 0.45 + np.array(A.hex2rgb('#1a1418'), np.float32) * 0.55
                inset = bb[pn] < STRUT_W + 0.9
                cp[inset] = cp[inset] * 0.5
                cp[glint_p] = GLINT
                cp[torn[pn]] = CHROME[3]                            # bright ripped edges of the metal skin
                c[pn] = cp
            # frame bars: chrome - a bevelled bar mixing the reflected world with polished metal
            fb = frame
            if fb.any():
                env_s, glint_s = env_reflect(n_s[fb], by[fb])
                bev = np.clip(1 - (bb[fb] / STRUT_W) ** 2, 0, 1)
                lv = np.clip(np.floor(bev * 2.4 + 0.3 + by[fb] * 0.6 + 0.8 * np.maximum(n_s[fb] @ SUN, 0)), 0, 3).astype(int)
                cf = env_s * 0.5 + CHROME[lv] * 0.5
                cf[glint_s] = GLINT
                cf[bb[fb] > STRUT_W - 0.55] = OUTLINE
                c[fb] = cf
                gl = np.nonzero(glint_s)[0]
                if gl.size:
                    glints += list(zip((ii[mf][fb][gl]).tolist(), (jj[mf][fb][gl]).tolist()))
            col[mf] = c
            solid = frame | panel
            dv[mf[solid | glass]] = Q[solid | glass, 1]
            kv[mf[solid]] = 3
            kv[mf[glass]] = 4
            gv[mf[solid | glass]] = gid_val
        img[jj, ii] = np.clip(col, 0, 255).astype(np.uint8)
        D[jj, ii] = dv
        kind[jj, ii] = kv
        gid[jj, ii] = gv
    # a crisp outline around the dome
    edge = front_all & ~ndi.binary_erosion(front_all)
    ey, ex = np.nonzero(edge)
    img[ey + y0, ex + x0] = OUTLINE
    rs = np.random.default_rng(SEED + 717)
    if len(glints) > 60:
        glints = [glints[i] for i in rs.choice(len(glints), 60, replace=False)]
    return glints


# ------------------------------------------------------------------ v3: white rooms, a band of glass panes
GLASS_MID = math.radians(31.0)    # elevation of the middle of the glass band
GLASS_FILL = 0.36                 # band height as a fraction of the room radius
PANE_FRAME = 0.24                 # thin metal lines between the panes (half width, world units)
RING_TRIM = 1.7                   # bright trims along the straight top and bottom of the band
TRIM_LIP = 0.45                   # dark lip where a trim meets the glass
WHITE = hexa('#474360', '#75718d', '#a4a2b9', '#cecddb', '#ebeaf2', '#ffffff').astype(np.float32)
TINT = hexa('#06141f', '#0a2333', '#103548', '#174b5e', '#216676', '#33868e', '#5aaea8', '#a6e0d4').astype(np.float32)
VOID = hexa('#05060b', '#0a0c15', '#11141f', '#1a1e2c').astype(np.float32)
CORAL_RGB = hexa(*O_RAMPS['coral']).astype(np.float32)
BEVEL = np.array(A.hex2rgb('#152030'), np.float32)
COOL = np.array(A.hex2rgb('#6b6aa6'), np.float32)
# where each room's glass was smashed in: two holes per room, every one a different shape
# (shape, azimuth in degrees round the room: 0 = +X, -90 = toward the camera)
BASE_HOLES = {'command': [('burst', -48.0), ('crescent', -112.0)],
              'habitat': [('gash', -84.0), ('wedge', -32.0)],
              'garage':  [('bite', -60.0), ('zigzag', -128.0)]}


def _h(a, b, k):
    return np.mod(np.sin(a * 12.9898 + b * 78.233 + k * 37.719) * 43758.5453, 1.0)


def band_grid(d):
    """The honeycomb round a v3 room: n panes per row, two rows filling a band that is cut
    straight top and bottom through the panes' corners. Band y runs 0 .. 2.5a."""
    R = d['R']
    circ = 2 * math.pi * R * math.cos(GLASS_MID)
    a0 = GLASS_FILL * R / 2.5
    n = max(8, int(round(circ / (math.sqrt(3) * a0))))
    a = circ / (n * math.sqrt(3))
    return dict(R=R, n=n, a=a, w=math.sqrt(3) * a, h=2.5 * a)


def band_xy(u, g):
    """Band coordinates (along the ring, up from the band's bottom) of unit directions u."""
    az = np.arctan2(u[:, 1], u[:, 0])
    el = np.arcsin(np.clip(u[:, 2], -1, 1))
    return az / (2 * math.pi) * g['n'] * g['w'], (el - GLASS_MID) * g['R'] + g['h'] / 2, el, az


def band_point(d, g, x, y):
    az = x * 2 * math.pi / (g['n'] * g['w'])
    el = GLASS_MID + (y - g['h'] / 2) / g['R']
    return cam(d['X'], d['Y'], d['Z']) + d['R'] * vrot([math.cos(el) * math.cos(az), math.cos(el) * math.sin(az), math.sin(el)])


def hex_cell(x, y, a):
    """Pointy-top hex cell (q, r) holding each point, the point in the cell's frame, and its
    distance inside the cell's edge."""
    q = (math.sqrt(3) / 3 * x - y / 3) / a
    r = (2 / 3 * y) / a
    cy_ = -q - r
    rx_, ry_, rz_ = np.round(q), np.round(cy_), np.round(r)
    dx_, dy_, dz_ = np.abs(rx_ - q), np.abs(ry_ - cy_), np.abs(rz_ - r)
    fix_x = (dx_ > dy_) & (dx_ > dz_)
    fix_z = ~fix_x & (dz_ >= dy_)
    rx_ = np.where(fix_x, -ry_ - rz_, rx_)
    rz_ = np.where(fix_z, -rx_ - ry_, rz_)
    px = x - a * math.sqrt(3) * (rx_ + rz_ / 2)
    py = y - a * 1.5 * rz_
    edge = a * math.sqrt(3) / 2 - np.maximum(np.abs(px), 0.5 * np.abs(px) + 0.866 * np.abs(py))
    return rx_, rz_, px, py, edge


def _kinked(rs, start, direction, length, kinks=2, jitter=0.35):
    """A crack: a line from start along direction with a couple of kinks."""
    pts = [np.asarray(start, float)]
    d = np.asarray(direction, float) / np.linalg.norm(direction)
    for k in range(kinks + 1):
        ang = math.atan2(d[1], d[0]) + rs.uniform(-jitter, jitter)
        step = length / (kinks + 1) * rs.uniform(0.8, 1.2)
        pts.append(pts[-1] + step * np.array([math.cos(ang), math.sin(ang)]))
    return np.array(pts)


def hole_shape(kind, a, rs):
    """A smashed-in hole: its jagged outline (polygon) and the shatter cracks running out of it,
    in band units around the hole's centre. Three kinds, each a different silhouette to trace."""
    pts, cracks = [], []
    if kind == 'burst':                                  # a spiky star punched through
        n = 14
        for k in range(n):
            th = k / n * TAU + rs.uniform(-0.1, 0.1)
            r = a * (0.98 if k % 2 == 0 else 0.46) * rs.uniform(0.82, 1.12)
            pts.append((r * math.cos(th), r * math.sin(th)))
        for k in range(0, n, 2):
            tip = np.array(pts[k])
            cracks.append(_kinked(rs, tip, tip, a * rs.uniform(0.45, 0.9)))
        for k in range(5):                               # a broken ring round it
            a0 = k / 5 * TAU + rs.uniform(0, 0.5)
            arc = [(1.45 * a * math.cos(t), 1.45 * a * math.sin(t)) for t in np.linspace(a0, a0 + rs.uniform(0.5, 0.9), 5)]
            cracks.append(np.array(arc))
    elif kind == 'gash':                                 # a long diagonal tear
        n, ang = 24, math.radians(22)
        ca, sa = math.cos(ang), math.sin(ang)
        for k in range(n):
            th = k / n * TAU
            j = (1.32 if k % 2 else 0.9) * rs.uniform(0.85, 1.1)
            x, y = 1.25 * a * math.cos(th) * (0.9 + 0.1 * j), 0.3 * a * math.sin(th) * j
            pts.append((x * ca - y * sa, x * sa + y * ca))
        axis = np.array([ca, sa])
        for end in (1, -1):
            tip = axis * 1.22 * a * end
            c1 = _kinked(rs, tip, axis * end, a * 0.95, kinks=3, jitter=0.4)
            cracks.append(c1)
            cracks.append(_kinked(rs, c1[2], axis * end + np.array([-sa, ca]) * 0.9 * end, a * 0.4, kinks=1))
        for t in (-0.5, 0.15, 0.6):                      # short splits off both lips
            for side in (1, -1):
                p0 = axis * t * a + np.array([-sa, ca]) * 0.3 * a * side
                cracks.append(_kinked(rs, p0, np.array([-sa, ca]) * side + axis * rs.uniform(-0.4, 0.4), a * rs.uniform(0.3, 0.55), kinks=1))
    elif kind == 'crescent':                             # a curved moon-shaped tear
        outer = [(0.9 * a * math.cos(t), 0.9 * a * math.sin(t)) for t in np.linspace(math.radians(-115), math.radians(115), 12)]
        inner = [(0.42 * a + 0.72 * a * math.cos(t), 0.72 * a * math.sin(t)) for t in np.linspace(math.radians(108), math.radians(-108), 10)]
        for k, (x, y) in enumerate(outer + inner):
            j = (1.0 + (0.07 if k % 2 else -0.05)) * rs.uniform(0.96, 1.04)
            pts.append((x * j, y * j))
        for t in (-115, 115):                            # cracks off both horns
            d = np.array([math.cos(math.radians(t)), math.sin(math.radians(t))])
            tip = d * 0.9 * a
            cracks.append(_kinked(rs, tip, d + np.array([-0.6, 0.0]), a * 0.8, kinks=2))
        for t in (-40, 10, 55):
            d = np.array([math.cos(math.radians(t)), math.sin(math.radians(t))])
            cracks.append(_kinked(rs, d * 0.92 * a, d, a * rs.uniform(0.35, 0.6), kinks=1))
    elif kind == 'wedge':                                # a jagged triangle where a shard fell out
        corners = [np.array([0.05, 0.92]) * a, np.array([-0.82, -0.62]) * a, np.array([0.8, -0.5]) * a]
        for k in range(3):
            c0, c1 = corners[k], corners[(k + 1) % 3]
            nrm = np.array([-(c1 - c0)[1], (c1 - c0)[0]]) / np.linalg.norm(c1 - c0)
            for j in range(4):
                t = j / 4
                off = (0.0 if j == 0 else (0.13 if j % 2 else -0.08)) * a * rs.uniform(0.6, 1.2)
                pts.append(tuple(c0 + (c1 - c0) * t + nrm * off))
        for c in corners:                                # cracks running on from each corner
            d = c / np.linalg.norm(c)
            cracks.append(_kinked(rs, c, d, a * rs.uniform(0.55, 0.85), kinks=2))
            cracks.append(_kinked(rs, c, d + np.array([-d[1], d[0]]) * 0.8, a * 0.35, kinks=1))
    elif kind == 'zigzag':                               # a narrow lightning-bolt split
        cl = np.array([(-1.1, 0.32), (-0.48, 0.48), (-0.16, -0.08), (0.34, 0.16), (0.62, -0.34), (1.1, -0.2)]) * a
        half = 0.15 * a
        left, right = [], []
        for k in range(len(cl)):
            d0 = cl[min(k + 1, len(cl) - 1)] - cl[max(k - 1, 0)]
            nrm = np.array([-d0[1], d0[0]]) / np.linalg.norm(d0)
            w = half * (0.55 if k in (0, len(cl) - 1) else 1.0) * rs.uniform(0.85, 1.25)
            left.append(cl[k] + nrm * w)
            right.append(cl[k] - nrm * w)
        pts = [tuple(q) for q in left + right[::-1]]
        for end, nb in ((0, 1), (len(cl) - 1, len(cl) - 2)):
            d = cl[end] - cl[nb]
            cracks.append(_kinked(rs, cl[end], d, a * 0.6, kinks=2))
        for k in (1, 3, 4):
            d0 = cl[k + 1] - cl[k - 1]
            nrm = np.array([-d0[1], d0[0]]) / np.linalg.norm(d0) * (1 if k % 2 else -1)
            cracks.append(_kinked(rs, cl[k] + nrm * half, nrm, a * rs.uniform(0.3, 0.5), kinks=1))
    else:                                                # 'bite': a rounded hole with a chunk bitten out
        n = 20
        notch = math.radians(205)
        for k in range(n):
            th = k / n * TAU
            r = a * 0.78 * (1.0 + (0.16 if k % 2 else -0.04)) * rs.uniform(0.9, 1.06)
            dth = abs((th - notch + math.pi) % TAU - math.pi)
            if dth < 0.55:
                r *= 0.32 + 0.68 * (dth / 0.55) ** 1.5
            pts.append((r * math.cos(th), r * math.sin(th)))
        for k in range(5):                               # a fan of cracks on the far side
            th = notch + math.pi + (k - 2) * 0.42 + rs.uniform(-0.1, 0.1)
            d = np.array([math.cos(th), math.sin(th)])
            cracks.append(_kinked(rs, d * 0.8 * a, d, a * rs.uniform(0.5, 1.0)))
        arc = [(1.3 * a * math.cos(t), 1.3 * a * math.sin(t)) for t in np.linspace(notch + 2.2, notch + 4.1, 8)]
        cracks.append(np.array(arc))
    return np.array(pts), cracks


def room_holes(d):
    """Where this room's glass was smashed: for each hole its centre in band coordinates, its
    outline and its cracks."""
    if d.get('owner') != 'base' or d['name'] not in BASE_HOLES:
        return []
    g = band_grid(d)
    out = []
    for i, (kind, az_deg) in enumerate(BASE_HOLES[d['name']]):
        az = math.radians(az_deg)
        rs = np.random.default_rng(sum(map(ord, d['name'])) + 7 + 31 * i)
        outline, cracks = hole_shape(kind, g['a'], rs)
        out.append(dict(kind=kind, x=az / (2 * math.pi) * g['n'] * g['w'], y=g['h'] / 2, outline=outline,
                        cracks=cracks, grid=g, dir=np.array([math.cos(az), math.sin(az)])))
    return out


def _poly_inside(px, py, poly):
    inside = np.zeros(px.shape, bool)
    n = len(poly)
    for k in range(n):
        (x0, y0), (x1, y1) = poly[k], poly[(k + 1) % n]
        cond = ((y0 > py) != (y1 > py)) & (px < (x1 - x0) * (py - y0) / (y1 - y0 + 1e-12) + x0)
        inside ^= cond
    return inside


def _poly_dist(px, py, poly):
    d = np.full(px.shape, np.inf, np.float32)
    n = len(poly)
    for k in range(n):
        (x0, y0), (x1, y1) = poly[k], poly[(k + 1) % n]
        ex, ey = x1 - x0, y1 - y0
        t = np.clip(((px - x0) * ex + (py - y0) * ey) / max(ex * ex + ey * ey, 1e-9), 0, 1)
        d = np.minimum(d, np.hypot(px - x0 - t * ex, py - y0 - t * ey))
    return d


def _crack_dist(px, py, strokes, dy=0.0, w0=0.36, w1=0.16):
    """Distance to the cracks less their half-width there (each tapers from its start)."""
    d = np.full(px.shape, np.inf, np.float32)
    for st in strokes:
        seg = np.linalg.norm(np.diff(st, axis=0), axis=1)
        s0 = np.concatenate([[0.0], np.cumsum(seg)]) / max(seg.sum(), 1e-9)
        for k in range(len(st) - 1):
            (x0, y0), (x1, y1) = st[k], st[k + 1]
            ex, ey = x1 - x0, y1 - y0
            t = np.clip(((px - x0) * ex + (py - dy - y0) * ey) / max(ex * ex + ey * ey, 1e-9), 0, 1)
            half = w0 + (w1 - w0) * (s0[k] + (s0[k + 1] - s0[k]) * t)
            d = np.minimum(d, np.hypot(px - x0 - t * ex, py - dy - y0 - t * ey) - half)
    return d


def band_layers(Q, C0, d):
    """What a v3 room's shell is at points Q on its sphere: white metal, the straight trims and
    their dark lips, thin frame lines between the panes, tinted glass - and where it was
    smashed: the hole, its bright torn edge, the shatter cracks and the fractured glass."""
    g = band_grid(d)
    u = (Q - C0) / d['R']
    u /= np.maximum(np.linalg.norm(u, axis=1), 1e-9)[:, None]
    x, y, el, az = band_xy(crot(u), g)                   # the pattern belongs to the dome, not the view
    inband = (y >= 0) & (y <= g['h'])
    trim = ~inband & ((-y < RING_TRIM) & (y < 0) | (y - g['h'] < RING_TRIM) & (y > g['h']))
    lip = inband & ((y < TRIM_LIP) | (y > g['h'] - TRIM_LIP))
    metal = ~inband & ~trim
    qi, ri, px, py, edge = hex_cell(x, y - g['a'] / 2, g['a'])
    frame = inband & ~lip & (edge < PANE_FRAME)
    glass = inband & ~lip & ~frame
    N = len(Q)
    hole, rim, crack, shade, halo = (np.zeros(N, bool) for _ in range(5))
    which = np.full(N, -1, np.int16)
    for hi_, hd in enumerate(room_holes(d)):
        span = g['n'] * g['w']
        dx = np.mod(x - hd['x'] + span / 2, span) - span / 2
        dy = y - hd['y']
        near = inband & (np.abs(dx) < 3.2 * g['a']) & (np.abs(dy) < 3.2 * g['a'])
        if near.any():
            ix = np.nonzero(near)[0]
            lx, ly = dx[ix], dy[ix]
            inside = _poly_inside(lx, ly, hd['outline'])
            pd = _poly_dist(lx, ly, hd['outline'])
            cd = _crack_dist(lx, ly, hd['cracks'])
            sd = _crack_dist(lx, ly, hd['cracks'], dy=-0.55)
            gl = glass[ix]
            hit = inside & ~lip[ix] & ~frame[ix]                     # the thin frame lines still cross it
            hole[ix[hit]] = True
            rim[ix[gl & ~inside & (pd < 0.75)]] = True
            crack[ix[gl & ~inside & (cd < 0)]] = True
            shade[ix[gl & ~inside & (sd < 0) & (cd >= 0)]] = True
            hal = gl & ~inside & (cd < 1.1) & (cd >= 0)
            halo[ix[hal]] = True
            which[ix[hit | (gl & ~inside & ((pd < 0.75) | (cd < 1.1) | (sd < 0)))]] = hi_
            glass &= ~hole
    return dict(metal=metal, trim=trim, lip=lip, frame=frame, glass=glass, hole=hole, rim=rim, crack=crack,
                crack_shade=shade, crack_halo=halo, which=which, qi=qi, ri=ri, px=px, py=py, x=x, y=y, el=el, az=az,
                grid=g)


def band_dome(img, D, kind, gid, d, gid_val):
    """A v3 room: a smooth dome of glossy white enamel with a coral stripe near its foot and
    seams, and a band of tinted mirror glass round its middle - two rows of hexagonal panes in
    thin frames between straight bright trims. Nothing inside shows through, except darkness
    where the glass was smashed. Returns the pixels where it glints, and the damage (outline
    and cracks on the map, plus a patch of the glass as it was) if any."""
    C = cam(d['X'], d['Y'], d['Z'])
    R = d['R']
    cx, cy = project(*C)
    rp = R / S + 2
    x0, x1 = max(0, int(cx - rp)), min(W, int(cx + rp + 1))
    y0, y1 = max(0, int(cy - rp)), min(H, int(cy + rp + 1))
    front_all = np.zeros((y1 - y0, x1 - x0), bool)
    glints = []
    holes = room_holes(d)
    patch_px = [[] for _ in holes]
    patch_col = [[] for _ in holes]
    for r0 in range(y0, y1, 192):
        r1 = min(y1, r0 + 192)
        jj, ii = np.mgrid[r0:r1, x0:x1]
        jj, ii = jj.ravel(), ii.ravel()
        sx = (ii + 0.5 - AX) * S
        sy = (AY - (jj + 0.5)) * S
        O = sx[:, None] * CR + sy[:, None] * CU - F * 6000.0
        oc = O - C
        b_ = oc @ F
        disc = b_ * b_ - (np.einsum('ij,ij->i', oc, oc) - R * R)
        ok = disc > 0
        sq = np.sqrt(np.maximum(disc, 0))
        Dv = D[jj, ii]
        P1 = O + (-b_ - sq)[:, None] * F
        mf = np.nonzero(ok & (P1[:, 2] >= C[2]) & (P1[:, 1] < Dv))[0]
        if mf.size == 0:
            continue
        front_all[(jj - y0)[mf], (ii - x0)[mf]] = True
        Q = P1[mf]
        L = band_layers(Q, C, d)
        wh = L['which']
        g = L['grid']
        n_s = (Q - C) / R
        by = BAYER[jj[mf] % 4, ii[mf] % 4]
        sxp, syp = ii[mf], jj[mf]
        c = np.zeros((len(mf), 3), np.float32)
        ndl = n_s @ SUN
        env, glint = env_reflect(n_s, by, 0.996)
        # --- white enamel
        m = L['metal']
        I = 0.16 + 0.84 * np.maximum(ndl, 0) + 0.06 * n_s[:, 2]
        rsun = (F[None, :] - 2 * (n_s @ F)[:, None] * n_s) @ SUN
        I += 0.1 * (rsun > 0.9) + 0.1 * (rsun > 0.965) + 0.1 * (rsun > 0.992)
        I -= 0.12 * ((1 - np.abs(n_s @ F)) + by * 0.05 > 0.9)
        el, az = L['el'], L['az']
        seam = ((np.abs(el - math.radians(10)) * R < 0.4) | (np.abs(el - math.radians(64)) * R < 0.4)
                | (np.abs(el - math.radians(80)) * R < 0.4))
        lower = (L['y'] < 0) & (el > math.radians(10))
        seam |= lower & (np.abs(np.mod(az + 0.13, math.pi / 9) - math.pi / 18) * R * np.cos(el) > math.pi / 18 * R * np.cos(el) - 0.4)
        I -= 0.16 * seam
        lv = np.clip(np.floor(I * 5.4 + by * 0.7), 0, 5).astype(int)
        cm = WHITE[lv] * 0.86 + env * 0.14
        shadeside = ndl < 0.05
        cm[shadeside] = cm[shadeside] * 0.86 + COOL * 0.14
        stripe = (el > math.radians(4.0)) & (el < math.radians(7.0))
        cm[stripe] = CORAL_RGB[np.clip(np.floor(1 + 2.4 * np.maximum(ndl[stripe], 0) + by[stripe] * 0.6), 0, 3).astype(int)]
        cm[glint] = GLINT
        c[m] = cm[m]
        # --- the straight trims: bright rounded bands, a dark lip against the glass
        t = L['trim']
        if t.any():
            yt = L['y'][t]
            k = np.where(yt < 0, -yt, yt - g['h']) / RING_TRIM                # 0 at the glass, 1 at the metal
            roll = np.sin(np.clip(k, 0, 1) * math.pi)
            lvt = np.clip(np.floor(2.2 + 2.2 * roll + 1.4 * np.maximum(ndl[t], 0) + by[t] * 0.6), 0, 5).astype(int)
            c[t] = WHITE[lvt] * 0.7 + env[t] * 0.3
        c[L['lip']] = BEVEL
        # --- thin frame lines between the panes
        fr = L['frame']
        c[fr] = WHITE[np.clip(np.floor(2.6 + 2.0 * np.maximum(ndl[fr], 0) + by[fr] * 0.6), 0, 5).astype(int)] * 0.8 + env[fr] * 0.2
        # --- tinted mirror glass: each pane a flat facet
        gl = L['glass'] | L['rim'] | L['crack'] | L['crack_shade'] | L['crack_halo']
        if gl.any():
            qi, ri = L['qi'][gl], L['ri'][gl]
            xc = g['a'] * math.sqrt(3) * (qi + ri / 2)
            yc = g['a'] * 1.5 * ri + g['a'] / 2
            azc = xc * 2 * math.pi / (g['n'] * g['w'])
            elc = GLASS_MID + (yc - g['h'] / 2) / R
            nf = vrot(np.stack([np.cos(elc) * np.cos(azc), np.cos(elc) * np.sin(azc), np.sin(elc)], -1))
            nmix = nf * 0.7 + n_s[gl] * 0.3
            nmix /= np.linalg.norm(nmix, axis=1)[:, None]
            envg, glg = env_reflect(nmix, by[gl], 0.9975)
            lum = envg.mean(axis=1) / 255.0
            fres = 1 - np.abs(n_s[gl] @ F)
            k = np.clip(np.floor(0.6 + lum * 5.0 + fres * 2.4 + by[gl] * 0.8 + 0.4 * _h(qi, ri, 5)), 0, 7).astype(int)
            cg = TINT[k] * 0.68 + envg * 0.32
            under = L['y'][gl] > g['h'] - 1.6                    # the top trim shades the glass under it
            cg[under] = cg[under] * 0.75
            sw = np.mod(sxp[gl] * 1.0 + syp[gl] * 1.6, 150.0)     # glare sweeping across the band
            band1 = sw < 6.0
            band2 = (sw > 10.0) & (sw < 12.5)
            cg[band1] = cg[band1] * 0.5 + SHINE * 0.5
            cg[band2] = cg[band2] * 0.66 + SHINE * 0.34
            cg[glg] = GLINT
            intact = cg.copy()
            sel = lambda key: L[key][gl]  # noqa: E731
            cg[sel('crack_halo')] = cg[sel('crack_halo')] * 0.7 + TINT[7] * 0.3
            cg[sel('crack_shade')] = TINT[0]
            cg[sel('crack')] = SHINE
            cg[sel('rim')] = SHINE
            dirty = sel('crack_halo') | sel('crack_shade') | sel('crack') | sel('rim')
            for h_i in range(len(holes)):
                mine = dirty & (wh[gl] == h_i)
                if mine.any():
                    idx = np.nonzero(gl)[0][mine]
                    patch_px[h_i] += list(zip(sxp[idx].tolist(), syp[idx].tolist()))
                    patch_col[h_i].append(intact[mine])
            c[gl] = cg
            gi = np.nonzero(gl)[0][glg]
            glints += list(zip(sxp[gi].tolist(), syp[gi].tolist()))
        # --- the hole: dark inside (no power), the frame lines still crossing it
        ho = L['hole']
        if ho.any():
            dyh = L['y'][ho] - g['h'] / 2
            kv = np.clip(np.floor(1.6 - dyh / g['a'] * 1.2 + by[ho] * 0.8), 0, 3).astype(int)
            c[ho] = VOID[kv]
            # the glass that was there, for mending
            qi, ri = L['qi'][ho], L['ri'][ho]
            xc = g['a'] * math.sqrt(3) * (qi + ri / 2)
            yc = g['a'] * 1.5 * ri + g['a'] / 2
            azc = xc * 2 * math.pi / (g['n'] * g['w'])
            elc = GLASS_MID + (yc - g['h'] / 2) / R
            nf = vrot(np.stack([np.cos(elc) * np.cos(azc), np.cos(elc) * np.sin(azc), np.sin(elc)], -1))
            nmix = nf * 0.7 + n_s[ho] * 0.3
            nmix /= np.linalg.norm(nmix, axis=1)[:, None]
            envh, _ = env_reflect(nmix, by[ho], 0.9975)
            fres = 1 - np.abs(n_s[ho] @ F)
            k = np.clip(np.floor(0.6 + envh.mean(axis=1) / 255.0 * 5.0 + fres * 2.4 + by[ho] * 0.8 + 0.4 * _h(qi, ri, 5)), 0, 7).astype(int)
            idx = np.nonzero(ho)[0]
            was = TINT[k] * 0.68 + envh * 0.32
            was[L['y'][ho] > g['h'] - 1.6] *= 0.75               # as the glass round it: trim shade, glare
            sw = np.mod(sxp[ho] * 1.0 + syp[ho] * 1.6, 150.0)
            was[sw < 6.0] = was[sw < 6.0] * 0.5 + SHINE * 0.5
            b2 = (sw > 10.0) & (sw < 12.5)
            was[b2] = was[b2] * 0.66 + SHINE * 0.34
            for h_i in range(len(holes)):
                mine = wh[ho] == h_i
                if mine.any():
                    patch_px[h_i] += list(zip(sxp[idx[mine]].tolist(), syp[idx[mine]].tolist()))
                    patch_col[h_i].append(was[mine])
        gm = np.nonzero(glint & m)[0]
        glints += list(zip(sxp[gm].tolist(), syp[gm].tolist()))
        img[jj[mf], ii[mf]] = np.clip(c, 0, 255).astype(np.uint8)
        D[jj[mf], ii[mf]] = Q[:, 1]
        kind[jj[mf], ii[mf]] = 3
        gid[jj[mf], ii[mf]] = gid_val
    edge = front_all & ~ndi.binary_erosion(front_all)
    ey, ex = np.nonzero(edge)
    img[ey + y0, ex + x0] = OUTLINE
    rs = np.random.default_rng(SEED + 919 + sum(map(ord, d['name'])))
    if len(glints) > 30:
        glints = [glints[i] for i in rs.choice(len(glints), 30, replace=False)]
    damage = []
    for h_i, hd in enumerate(holes):
        if not patch_px[h_i]:
            continue
        g = hd['grid']

        def to_px(lx, ly, hd=hd):
            P = band_point(d, g, hd['x'] + lx, hd['y'] + ly)
            X_, Y_ = project(*P)
            return [round(float(X_), 1), round(float(Y_), 1)]

        pp = np.array(patch_px[h_i])
        cols = np.concatenate(patch_col[h_i], axis=0)
        px0, py0 = pp.min(axis=0)
        pw, ph = pp.max(axis=0) - pp.min(axis=0) + 1
        patch = np.zeros((ph, pw, 4), np.uint8)
        patch[pp[:, 1] - py0, pp[:, 0] - px0, :3] = np.clip(cols, 0, 255).astype(np.uint8)
        patch[pp[:, 1] - py0, pp[:, 0] - px0, 3] = 255
        P = to_canon(band_point(d, g, hd['x'], hd['y']))          # where it is in the world
        damage.append(dict(room=d['name'], id=f"{d['name']}_{h_i + 1}", shape=hd['kind'],
                           outline=[to_px(x, y) for x, y in hd['outline']],
                           cracks=[[to_px(x, y) for x, y in st] for st in hd['cracks']], center=to_px(0, 0),
                           world=[round(float(P[0]), 2), round(float(P[1]), 2), round(float(P[2]), 2)],
                           patch=patch, patch_pos=[int(px0), int(py0)]))
    return glints, damage


def band_debris(d, ground):
    """Glass that fell out of a v3 room's holes: shards on the sand below them."""
    holes = room_holes(d)
    if not holes:
        return [], []
    hd = holes[0]
    rs = np.random.default_rng(SEED + 626 + sum(map(ord, d['name'])))
    bxy = np.array([*hd['dir'], 0.0])
    side = np.array([-bxy[1], bxy[0], 0.0])
    parts, glints = [], []
    for k in range(16):
        rr = d['R'] + rs.uniform(5, 34)
        spread = rs.normal(0, 0.16)
        dirv = A.nz(bxy * math.cos(spread) + side * math.sin(spread))
        X, Y = d['X'] + dirv[0] * rr, d['Y'] + dirv[1] * rr
        z = ground(X, Y)
        size = rs.uniform(0.9, 2.6)
        Rm = A.rz(rs.uniform(0, TAU)) @ A.rx(rs.uniform(-0.35, 0.35))
        parts.append(P_('shard', A.RoundBox(cam(X, Y, z + 0.3), (size, size * 0.6, 0.2), 0.12, Rm),
                        'tglass' if k % 3 else 'shard', f"{d['name']}gshard{k}"))
        if rs.random() < 0.55:
            glints.append(cam(X, Y, z + 0.5))
    return parts, glints


def hex_shadow(Hf, u0, u1, v0, v1, d):
    """Shadow the honeycomb throws on the floor inside and the ground around: bars and panels
    block the sun, glass barely, the smashed holes not at all."""
    du, dv = to_grid(SUN[0], SUN[1])
    Lg = np.array([du, dv, SUN[2]])
    cu, cv = to_grid(d['X'], d['Y'])
    iu, iv = np.meshgrid(np.arange(u0, u1, dtype=np.float32) + 0.5, np.arange(v0, v1, dtype=np.float32) + 0.5,
                         indexing='ij')
    P = np.stack([iu - cu, iv - cv, Hf[u0:u1, v0:v1] - d['Z']], -1).reshape(-1, 3)
    b = P @ Lg
    disc = b * b - ((P * P).sum(-1) - d['R'] ** 2)
    sq = np.sqrt(np.maximum(disc, 0))
    opa = np.zeros(len(P), np.float32)
    C0 = cam(d['X'], d['Y'], d['Z'])
    HX = hex_cells(d) if d['style'] == 'hex' else None
    for t in (-b - sq, -b + sq):
        m = np.nonzero((disc > 0) & (t > 0))[0]
        if m.size == 0:
            continue
        Qg = P[m] + t[m, None] * Lg
        up = Qg[:, 2] >= 0
        m, Qg = m[up], Qg[up]
        Qc = np.stack([(Qg[:, 0] - Qg[:, 1]) / SQ2, (Qg[:, 0] + Qg[:, 1]) / SQ2, Qg[:, 2]], -1) + C0
        if HX is None:
            o = np.ones(len(Qc), np.float32)
        else:
            frame, hole, glass, panel, crack, torn = hex_layers(*hex_shell(Qc, C0, d['R'], HX), HX)
            o = np.where(panel, 1.0, np.where(frame, 0.85, np.where(hole, 0.0, np.where(crack, 0.32, 0.14))))
        opa[m] = 1 - (1 - opa[m]) * (1 - o)
    return opa.reshape(u1 - u0, v1 - v0)


def glass_debris(d, ground):
    """What came down when a dome unit broke: shards of glass (or twisted scraps of mirror metal
    where the skin was torn) on the floor under the breach and out on the sand, and a few frame
    bars. Returns parts and the points where shards glint."""
    breaches = unit_breaches(d)
    if not breaches:
        return [], []
    rs = np.random.default_rng(SEED + 616 + sum(map(ord, d['name'])))
    B = breaches[0][0]
    metal = BASE_DESIGN == 'v2' and math.degrees(math.asin(B[2])) < GLASS_BAND[0]
    bxy = A.nz([B[0], B[1], 0.0])
    side = np.array([-bxy[1], bxy[0], 0.0])
    parts, glints = [], []
    R = d['R']
    count = int(120 * R / 300) + 30
    for k in range(count):
        inside = k < count // 2
        rr = rs.uniform(0.45, 0.94) * R if inside else R + rs.uniform(8, 70)
        spread = rs.normal(0, 0.34 if inside else 0.26)
        dirv = A.nz(bxy * math.cos(spread) + side * math.sin(spread))
        X, Y = d['X'] + dirv[0] * rr, d['Y'] + dirv[1] * rr
        z = d['Z'] + 0.6 * DOME_SCALE if inside else ground(X, Y)
        size = rs.uniform(0.9, 2.8) * (1.3 if metal else 1.0)
        Rm = A.rz(rs.uniform(0, TAU)) @ A.rx(rs.uniform(-0.4, 0.4)) @ A.ry(rs.uniform(-0.5, 0.5) if metal else 0.0)
        ramp = ('darkwin' if k % 3 else 'metal') if metal else 'shard'
        parts.append(P_('shard', A.RoundBox(cam(X, Y, z + 0.3), (size, size * 0.55, 0.2 if not metal else 0.3), 0.12, Rm),
                        ramp, f"{d['name']}shard{k}"))
        if rs.random() < (0.25 if metal else 0.5):
            glints.append(cam(X, Y, z + 0.5))
    for k in range(3 if R > 200 else 2):
        rr = rs.uniform(0.55, 0.85) * R
        spread = rs.normal(0, 0.25)
        dirv = A.nz(bxy * math.cos(spread) + side * math.sin(spread))
        a = cam(d['X'] + dirv[0] * rr, d['Y'] + dirv[1] * rr, d['Z'] + 0.6 * DOME_SCALE + 1.2)
        tang = A.nz(np.cross(dirv, [0, 0, 1.0]) * math.cos(k) + dirv * math.sin(k))
        L = rs.uniform(14, 30) * min(1.0, R / 200)
        parts.append(P_('bar', A.RoundCone(a, a + tang * L + np.array([0, 0, rs.uniform(0, 6)]), 1.2, 1.0),
                        'metal', f"{d['name']}bar{k}"))
    return parts, glints


def apex_radar_broken(d):
    """The radar on top of the dead base: mast knocked askew, dish hanging face-down."""
    C = cam(d['X'], d['Y'], d['Z'])
    top = C + np.array([0, 0, d['R0']])
    pivot = top + np.array([2.2, 1.0, 8.4])
    face = grid_dir(math.radians(-130))
    dish_dir = A.nz(face * 0.5 + np.array([0, 0, -0.85]))
    return [P_('collar', A.Torus(top + np.array([0, 0, -0.3]), 3.6, 1.2), 'dark', 'mast'),
            P_('mast', A.RoundCone(top - np.array([0, 0, 1.0]), pivot, 1.4, 1.0), 'pack', 'mast'),
            P_('dish', A.Ellipsoid(pivot + face * 2.2 - np.array([0, 0, 1.5]), (6.2, 6.2, 1.3), frame_z(dish_dir)),
               'metal', 'radar'),
            P_('feed', A.RoundCone(pivot + face * 2.2 - np.array([0, 0, 1.5]),
                                   pivot + face * 2.2 - np.array([0, 0, 1.5]) + dish_dir * 4.5, 0.5, 0.4), 'dark', 'radar'),
            P_('weight', A.RoundBox(pivot - face * 2.0, (1.4, 1.4, 1.1), 0.5, yaw_to(face)), 'coral', 'radar')]


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


def add_glow(img, sx, sy, radius, color, strength, light=None):
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
    if light is not None:                                  # the halo is light too
        lw = np.round(a[..., 0] / max(strength, 1e-6) * 235).astype(np.uint8)
        light[y0:y1, x0:x1] = np.maximum(light[y0:y1, x0:x1], lw)


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
HAZES = np.array([A.hex2rgb('#d39a8e'), A.hex2rgb('#8f80c4'), A.hex2rgb('#bcd2e6')], np.float32)  # red, forest, ice


def apply_haze(rgb, y0, x0, bio=None):
    """Thin air: the far side of the map softens toward a haze (rose dust, violet spores, ice fog)."""
    h, w = rgb.shape[:2]
    yy = np.arange(y0, y0 + h, dtype=np.float32)[:, None]
    far = np.clip((AY - 260 * PX - yy) / (1650 * PX), 0, 1)
    bay = BAYER[np.arange(y0, y0 + h)[:, None] % 4, np.arange(x0, x0 + w)[None, :] % 4]
    hq = (np.floor(far * 3 + bay * 0.9 + 0.5) / 3.0 * 0.12)[..., None]
    col = HAZE if bio is None else HAZES[bio]
    return (rgb * (1 - hq) + col * hq).astype(np.uint8)


# ================================================================== moving parts
def export_animated(D):
    """Sprite sheets for the parts that move on the domes, plus the light positions the
    game animates (rim chase lights, airlock blinkers, comms beacon)."""
    adir = os.path.join(OUT, 'anim')
    os.makedirs(adir, exist_ok=True)
    out = dict(sprites=[], ring_lights=[], door_lights=[], beacon=None)

    def sheet(name, builder, d, frames, fps, z_center, radius, turn=2 * math.pi):
        dname = next(n for n, v in DOMES.items() if v is d)
        with canonical():
            d0 = dict(DOMES[dname])
        C0 = cam(d0['X'], d0['Y'], d0['Z'] + 0.0)
        C = cam(d['X'], d['Y'], d['Z'] + 0.0)
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
            with canonical():
                parts = scaled(builder(d0, turn * f / frames), C0, DOME_SCALE, name)
            render_groups(turned(parts), img, Dc, kind, gid, 1, x0, y0)
            depth_lines(img, img, Dc, kind, gid)
            filled = kind > 0
            pad = np.pad(filled, 1)
            ring = (pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]) & ~filled
            img = apply_haze(img, y0, x0)
            img[ring] = OUTLINE
            alpha = np.where(filled | ring, 255, 0).astype(np.uint8)
            strip[:, f * w:(f + 1) * w, :3] = img
            strip[:, f * w:(f + 1) * w, 3] = alpha
        save_png(Image.fromarray(strip), os.path.join(adir, f'{name}{SFX}.png'))
        centre = scale_pt(C + np.array([0, 0, z_center]), C, DOME_SCALE)          # what it turns round
        out['sprites'].append(dict(name=name, file=f'anim/{name}{SFX}.png', frames=frames, fps=fps,
                                   position=[x0, y0], frame_size=[w, h],
                                   anchor=[round(float(cx - x0), 1), round(float(cy - y0), 1)],
                                   world=[round(float(v), 2) for v in to_canon(centre)]))

    if DOMES['base']['powered']:
        sheet('base_radar', apex_radar, DOMES['base'], 24, 8, DOMES['base']['R0'] + 5, 12.0)
    sheet('nursery_anemometer', apex_anemometer, DOMES['nursery'], 8, 14, DOMES['nursery']['R0'] + 4, 9.5,
          turn=2 * math.pi / 3)
    sheet('comms_dish', tower_dish_frame, DOMES['comms'], 24, 6, 121.0, 21.0)

    def visible(P):
        px, py = project(*P)
        ix, iy = int(px), int(py)
        return 0 <= ix < W and 0 <= iy < H and D[iy, ix] >= P[1] - 6, [ix, iy]

    for d in dome_units():                                # rim lights, as decal_ring places them
        name = d['owner']
        if not d['powered']:
            continue
        C = cam(d['X'], d['Y'], d['Z'] + 0.0)
        n = 40
        for k in range(n):
            a = k * 2 * math.pi / n + 0.01
            P = scale_pt(C + np.array([d['R0'] * math.cos(a), d['R0'] * math.sin(a), 1.4 + 2.5]), C, DOME_SCALE)
            ok, px = visible(P)
            if ok:
                out['ring_lights'].append(px + [round(k / n, 4), name])
    for k, (d, dirv) in enumerate(airlock_ends()):        # a warning light over every airlock door
        if not d['powered']:
            continue
        C = cam(d['X'], d['Y'], d['Z'] + 0.0)
        dv = np.array([dirv[0], dirv[1], 0.0])
        P = scale_pt(C + dv * (d['R0'] + 15.6) + np.array([0, 0, 14.6]), C, DOME_SCALE)
        ok, px = visible(P)
        if ok:
            out['door_lights'].append(px + [round(k * 0.37 % 1.0, 3)])
    cm = DOMES['comms']
    C = cam(cm['X'], cm['Y'], cm['Z'])
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
    'W': ['#...#', '#...#', '#.#.#', '##.##', '#...#'], 'K': ['#.#', '#.#', '##.', '#.#', '#.#'],
    'F': ['###', '#..', '##.', '#..', '#..'], 'I': ['###', '.#.', '.#.', '.#.', '###'],
    'G': ['.##', '#..', '#.#', '#.#', '.##'], 'X': ['#.#', '#.#', '.#.', '#.#', '#.#'], 'H': ['#.#', '#.#', '###', '#.#', '#.#'],
    'V': ['#.#', '#.#', '#.#', '#.#', '.#.'], 'Q': ['.#.', '#.#', '#.#', '##.', '.##'],
    '0': ['###', '#.#', '#.#', '#.#', '###'], '1': ['.#.', '##.', '.#.', '.#.', '###'], '2': ['##.', '..#', '.#.', '#..', '###'],
    '-': ['...', '...', '###', '...', '...'],
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
    for pts in PATHS:                                   # the trails, as a dotted route
        cp = catmull(pts, step=2.0)
        for k, (X, Y) in enumerate(cp):
            if (k // 4) % 2 or min(math.hypot(X - d['X'], Y - d['Y']) - d['R'] for d in DOMES.values()) < 0:
                continue
            mx, my = to_mm(X, Y)
            mm[int(my), int(mx)] = path_col
    ring_col = np.array(A.hex2rgb('#a8ece2'), np.uint8)
    for d in dome_units():
        for a in np.linspace(0, 2 * math.pi, 720, endpoint=False):
            mx, my = to_mm(d['X'] + d['R'] * math.cos(a), d['Y'] + d['R'] * math.sin(a), d['Z'])
            mm[int(my), int(mx)] = ring_col
    cream = A.hex2rgb('#f6ecdc')
    for name, d in DOMES.items():
        label = name.upper()
        mx, top = to_mm(d['X'], d['Y'], d['Z'] + d['R'] * (1.0 if name != 'comms' else 0.0) + 20)
        if name == 'comms':
            top = to_mm(d['X'], d['Y'], d['Z'] + (TOWER_TOP + 34) * DOME_SCALE)[1]
        draw_text(mm, int(mx - text_width(label) / 2), int(top - 9), label, cream)
    wx, wy = to_mm(CRASH['X'], CRASH['Y'] - CRASH['R'] * 1.4, 0.0)          # under the wreck, clear of the base
    draw_text(mm, int(wx - text_width('WRECK') / 2), int(wy + 2), 'WRECK', A.hex2rgb('#ffb27a'))
    draw_text(mm, 4, 4, 'RED PLANET', A.hex2rgb('#ec7a5a'))
    draw_text(mm, w - text_width('M CLOSE') - 4, h - 9, 'M CLOSE', A.hex2rgb('#a99bb4'))
    save_png(Image.fromarray(mm), os.path.join(OUT, f'red_planet_minimap{SFX}.png'))
    return dict(file=f'red_planet_minimap{SFX}.png', origin=[int(x0), int(y0)], scale=scale, size=[w, h])


# ================================================================== game data
DEPTH_SCALE = 20.0                          # depth png stores camera-depth Y * 20 in 16 bits (to 3276:
                                            # the world is 2 * HALF = 3253 deep, from every side)
HEIGHT_OFFSET, HEIGHT_SCALE = 100.0, 150.0  # walk png stores (z + 100) * 150 in 16 bits


FLORA_BLOCK = {  # species: trunk radius (the undergrowth is walked through)
    'tree': 3.6, 'ice': 5.5}


def stamp_disc(mask, X, Y, r):
    u, v = to_grid(X, Y)
    w = int(r) + 2
    a0, a1, b0, b1 = max(0, int(u) - w), min(N, int(u) + w + 1), max(0, int(v) - w), min(N, int(v) + w + 1)
    if a1 <= a0 or b1 <= b0:
        return
    uu, vv = np.meshgrid(np.arange(a0, a1) + 0.5, np.arange(b0, b1) + 0.5, indexing='ij')
    mask[a0:a1, b0:b1] |= np.hypot(uu - u, vv - v) < r


def export_biome_grid(G, cell=4):
    """Biome weights on a coarse grid (R red, G forest, B ice), same layout as the walk grid."""
    n = N // cell
    f = G['bio_f'][:n * cell, :n * cell].reshape(n, cell, n, cell).mean(axis=(1, 3))
    i = G['bio_i'][:n * cell, :n * cell].reshape(n, cell, n, cell).mean(axis=(1, 3))
    grid = np.zeros((n, n, 3), np.uint8)
    grid[..., 0] = np.clip((1 - f - i) * 255, 0, 255)
    grid[..., 1] = np.clip(f * 255, 0, 255)
    grid[..., 2] = np.clip(i * 255, 0, 255)
    save_png(Image.fromarray(grid.transpose(1, 0, 2).copy()), os.path.join(OUT, 'red_planet_biome.png'))
    return dict(png='red_planet_biome.png', grid_size=n, cell=cell, names=['red', 'forest', 'ice'])


def export_game_data(G, D, kind, debris=(), body=None, world=True):
    """Data the game needs on top of the picture: a screen-space depth map (so the
    player can be hidden by cliffs, props and glass) and a walk/height grid. The walk grid
    belongs to the world, not the view: only view 0 writes it (world=False skips it)."""
    depth = np.zeros((H, W, 4), np.uint8)
    for r0 in range(0, H, 512):
        r1 = min(H, r0 + 512)
        dq = np.where(kind[r0:r1] > 0, np.clip(D[r0:r1] * DEPTH_SCALE, 0, 65534), 65535).astype(np.uint32)
        depth[r0:r1, :, 0], depth[r0:r1, :, 1] = dq >> 8, dq & 255
        depth[r0:r1, :, 2] = np.where(kind[r0:r1] == 4, 255, np.where(kind[r0:r1] == 5, PLANT_DEPTH_B, 0))
    depth[..., 3] = 255
    save_png(Image.fromarray(depth), os.path.join(OUT, f'red_planet_depth{SFX}.png'))
    del depth
    if not world:
        return None

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
    for d in dome_units():
        solid |= np.hypot(Xg - d['X'], Yg - d['Y']) < d['R'] + 3

    def block_segment(a, b, r):
        nonlocal solid
        ab = b - a
        t = np.clip(((Xg - a[0]) * ab[0] + (Yg - a[1]) * ab[1]) / (ab @ ab), 0, 1)
        solid |= np.hypot(Xg - a[0] - t * ab[0], Yg - a[1] - t * ab[1]) < r

    for d, dirv in airlock_ends():                                    # airlock tunnels
        C = np.array([d['X'], d['Y']])
        block_segment(C + dirv * (d['R0'] - 8) * DOME_SCALE, C + dirv * (d['R0'] + 16) * DOME_SCALE, 8.0 * DOME_SCALE)
    if BASE_DOME == 'rooms':                                          # the corridors between the base's rooms
        rooms = [u for u in dome_units() if u['owner'] == 'base']
        for a_, b_ in BASE_LINKS:
            block_segment(np.array([rooms[a_]['X'], rooms[a_]['Y']]), np.array([rooms[b_]['X'], rooms[b_]['Y']]), 16.0)
    if body is not None:                                             # the wreck: hull, engine and the bent wing
        k = WRECK_SCALE
        fwd = -np.array(CRASH['came_from'])
        side = np.array([-fwd[1], fwd[0]])
        bc = np.array([body['X'], body['Y']])
        block_segment(bc - fwd * 22 * k, bc + fwd * 11 * k, 9.0 * k)
        block_segment(bc - side * 8 * k, bc - side * 26 * k, 6.0 * k)
    hop = np.zeros((N, N), bool)                                     # too steep: debris, small plants
    cf = np.array(CRASH['came_from'])
    stamp_disc(hop, CRASH['X'] + cf[0] * 92, CRASH['Y'] + cf[1] * 92, 20.0)
    for X, Y, r in debris:
        stamp_disc(hop, X, Y, max(r, 1.6))
    for pl in G.get('flora', []):
        if pl['species'] in FLORA_BLOCK:
            stamp_disc(solid, pl['X'], pl['Y'], FLORA_BLOCK[pl['species']])
    walk &= ~hop
    del hop
    if SOLAR_DESIGN == 'field':
        for X, Y, radius in footprints():
            stamp_disc(solid, X, Y, radius)
    else:
        for u, v in solar_panels():
            solid |= np.hypot(U - u, V - v) < 9.5 * SOLAR_SCALE
    for X, Y in (G['lamps'] if TRAIL_LAMPS else []):
        solid |= np.hypot(Xg - X, Yg - Y) < 2.5 * LAMP_SCALE
    solid |= (U <= 6) | (U >= N - 6) | (V <= 6) | (V >= N - 6)
    walk &= ~solid

    base = DOMES['base']
    dirv = np.array(PATHS[1][1], float) - np.array([base['X'], base['Y']])
    dirv /= np.linalg.norm(dirv)
    lamps = np.array(G['lamps'])
    door = max(airlock_ends(), key=lambda e: (e[0]['owner'] == 'base') * 2 + e[1] @ dirv)
    door = np.array([door[0]['X'], door[0]['Y']]) + door[1] * (door[0]['R0'] + 16) * DOME_SCALE
    for dist in range(30, 300, 2):                                   # first open spot on the path, clear of lamps
        spawn = door + dirv * dist
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
    save_png(Image.fromarray(grid.transpose(1, 0, 2).copy()), os.path.join(OUT, 'red_planet_walk.png'))
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
def export_doors(D, kind):
    """The base's airlock doors opening, as sprites to lay over the map: every frame of each door
    (closed -> open), where it sits, where its foot is (for sorting with the astronaut), and the
    door's place in the world (its middle on the ground, and which way it faces)."""
    adir = os.path.join(OUT, 'anim')
    out = []
    with canonical():
        ends0 = airlock_ends()
    for k, ((d, dirv), (d0, dirv0)) in enumerate(zip(airlock_ends(), ends0)):
        if d.get('owner') != 'base' or d.get('style') != 'band':
            continue
        C = cam(d['X'], d['Y'], d['Z'])
        C0 = cam(d0['X'], d0['Y'], d0['Z'])
        with canonical():
            frames_parts = [scaled(airlock(d0, dirv0, i / (DOOR_FRAMES - 1)), C0, DOME_SCALE, f'door{k}')
                            for i in range(DOOR_FRAMES)]
        frames_parts = [turned(fp) for fp in frames_parts]
        dv3 = np.array([dirv[0], dirv[1], 0.0])
        f = C + dv3 * (d['R0'] + 14.4) + np.array([0, 0, 6.0])
        door_c = scale_pt(f, C, DOME_SCALE)
        r_px = 9.5 * DOME_SCALE / S
        cx, cy = project(*door_c)
        box = (int(cx - r_px), int(cy - r_px * 1.05), int(2 * r_px), int(2.1 * r_px))
        strip = []
        for fp in frames_parts:
            fr = render_sprite(fp, box)
            rgb = apply_haze(fr['rgb'], box[1], box[0])
            fr = dict(fr, rgb=rgb)
            strip.append(sprite_rgba(fr))
        img = np.concatenate(strip, axis=1)
        fn = f'anim/door_{k}{SFX}.png'
        save_png(Image.fromarray(img), os.path.join(OUT, fn))
        foot = scale_pt(f - np.array([0, 0, 6.0]), C, DOME_SCALE)
        foot0 = to_canon(foot)                                  # the game keeps the world in view 0's frame
        lamp = scale_pt(f + dv3 * 1.4 + np.array([0, 0, 7.9]), C, DOME_SCALE)
        lx, ly = project(*lamp)
        out.append(dict(id=k, file=fn, frames=DOOR_FRAMES, position=[box[0], box[1]], frame_size=[box[2], box[3]],
                        sort_y=round(float(project(*foot)[1]), 1), world=[round(float(foot0[0]), 2), round(float(foot0[1]), 2)],
                        dir=[round(float(dirv0[0]), 4), round(float(dirv0[1]), 4)], lamp_px=[round(float(lx), 1), round(float(ly), 1)],
                        height=round(float(14.8 * DOME_SCALE), 1)))
    print(f'doors: {len(out)} animated airlock doors')
    return out


def export_cracks(cracks):
    """Where the base's glass was smashed, for the game to have it traced and mended: each hole's
    outline and its shatter cracks in map pixels, and a patch of the glass as it was (hazed like
    the map) to lay over it once mended."""
    cdir = os.path.join(OUT, 'anim', 'cracks')
    os.makedirs(cdir, exist_ok=True)
    for old in os.listdir(cdir):                         # stale patches from an earlier layout (this view's)
        stem = old[:-4] if old.endswith('.png') else ''
        if stem and (stem.endswith(SFX) if SFX else '_r' not in stem):
            os.remove(os.path.join(cdir, old))
    out = []
    for c in cracks:
        patch = c.pop('patch')
        x0, y0 = c['patch_pos']
        rgb = apply_haze(patch[..., :3], y0, x0)
        patch[..., :3] = np.where(patch[..., 3:] > 0, rgb, 0)
        fn = f"anim/cracks/{c['id']}{SFX}.png"
        save_png(Image.fromarray(patch), os.path.join(OUT, fn))
        out.append(dict(c, patch=fn))
    if out:
        print('damage: ' + ', '.join(f"{c['id']} ({c['shape']}, {len(c['outline'])}-pt outline, "
                                     f"{len(c['cracks'])} cracks)" for c in out))
    return out


def collect_glows(G, fxpx, D, baked, sprites):
    """Everything that glows on its own, for the game to pulse and twinkle:
    [x, y, halo, colour, strength, kind, phase]; kinds 0 plant, 1 pool, 2 ember, 3 ice glint, 4 crystal spire."""
    rs = np.random.default_rng(SEED + 77)
    pts = [g + [int(rs.integers(256))] for g in static_glows(baked, sprites, D)]
    for code, every, halo, colours, strength, kind_ in ((1, 70, 1, (0, 0, 3), 150, 1), (2, 240, 0, (5,), 255, 3),
                                                       (3, 1, 0, (4,), 220, 2)):
        ys, xs = np.nonzero(fxpx == code)
        if xs.size == 0:
            continue
        pick = rs.choice(xs.size, size=max(1, xs.size // every), replace=False)
        for j in pick:
            pts.append([int(xs[j]), int(ys[j]), halo + int(rs.integers(2)) * (kind_ == 1), int(rs.choice(colours)),
                        strength, kind_, int(rs.integers(256))])
    for X, Y, Hs, bf, bi in G['peaks']:
        if bf < 0.5:
            continue
        z = height_at(G, X, Y) + Hs
        px, py = project(X, Y, z - 2.0)
        ix, iy = int(px), int(py)
        if 0 <= ix < W and 0 <= iy < H and D[iy, ix] > Y - 6:
            pts.append([ix, iy, 4 if Hs > 150 else 3, 6, 200, 4, int(rs.integers(256))])
    kinds = np.bincount([p[5] for p in pts], minlength=5)
    print(f'glow points: {len(pts)} (plants {kinds[0]}, pools {kinds[1]}, embers {kinds[2]}, glints {kinds[3]}, spires {kinds[4]})')
    return pts


_GAME0 = None


def build():
    """The world once, then each view of it."""
    global VIEW, SFX
    os.makedirs(OUT, exist_ok=True)
    t_start = time.time()
    G0 = build_world()
    _snapshot()
    for k in VIEWS:
        VIEW, SFX = k, view_sfx(k)
        apply_view_constants(k)
        print(f'================ view {k} ({["front", "turned right", "from behind", "turned left"][k]})')
        G = view_world(G0, k)
        render_view(G, G0, k)
        del G
        gc.collect()
    VIEW, SFX = 0, ''
    apply_view_constants(0)
    print(f'done in {time.time() - t_start:.1f}s -> {OUT}')


def render_view(G, G0, k):
    """Render one view of the world (G: as the view sees it; G0: in view 0's frame)."""
    global EMIT, _GAME0
    t_start = time.time()
    set_frame(G)
    EMIT = np.zeros((H, W), np.uint8)
    hitY, hitZ, kind = render_terrain(G)
    img, dark, bio, fxpx = shade_terrain(G, hitY, hitZ, kind)
    del hitZ
    D = hitY
    gid = np.zeros((H, W), np.int32)
    lights = []
    gp = PX                                              # glow radii are given in world units
    ground0 = lambda X, Y: height_at(G0, X, Y)  # noqa: E731  (models are built in view 0's frame)

    # --- props: built in view 0's frame, turned into this one
    t0 = time.time()
    gb = 1
    with canonical():
        comms = DOMES['comms']
        cC = cam(comms['X'], comms['Y'], comms['Z'])
        tower_parts, beacon = comms_tower(comms)
        tower_parts = scaled(tower_parts, cC, DOME_SCALE, 'tower')
    gb = render_groups(turned(tower_parts), img, D, kind, gid, gb)
    interiors = {'base': base_interior, 'nursery': nursery_interior, 'comms': comms_interior,
                 'command': command_room, 'habitat': habitat_room, 'garage': garage_room}
    for d in dome_units():
        name = d['name']
        d0 = canon_unit(name)
        with canonical():
            C = cam(d0['X'], d0['Y'], d0['Z'])
            ring = scaled(dome_ring(d0), C, DOME_SCALE, f'{name}ring')
            parts, ilights = interiors[name](d0)
            parts = scaled(parts, C, DOME_SCALE, name)
            radar = (scaled(apex_radar_broken(d0), C, DOME_SCALE, 'radar')
                     if name in ('base', 'command') and not d0['powered'] else [])
        gb = render_groups(turned(ring), img, D, kind, gid, gb)
        gb = render_groups(turned(parts), img, D, kind, gid, gb)
        for i, hp in enumerate(ilights if d['powered'] else []):
            col = A.hex2rgb('#7fe6cf') if name == 'comms' and i == 0 else A.hex2rgb('#ffcf87')
            lights.append((to_view(scale_pt(hp, C, DOME_SCALE)), 8 * DOME_SCALE * gp * 0.6, col, 0.38))
        if radar:
            gb = render_groups(turned(radar), img, D, kind, gid, gb)
    with canonical():
        corridors = base_corridors() if BASE_DOME == 'rooms' else []
        locks = [scaled(airlock(d0, dirv0), cam(d0['X'], d0['Y'], d0['Z']), DOME_SCALE, f'airlock{i}')
                 for i, (d0, dirv0) in enumerate(airlock_ends())]
        solar = solar_field()
    if corridors:
        gb = render_groups(turned(corridors), img, D, kind, gid, gb)
    for lk in locks:
        gb = render_groups(turned(lk), img, D, kind, gid, gb)
    gb = render_groups(turned(solar), img, D, kind, gid, gb)
    for i, (X, Y) in enumerate(G0['lamps'] if TRAIL_LAMPS else []):
        u, v = to_grid(X, Y)
        z = float(G0['H'][int(u), int(v)])
        on = i not in G0['dead_lamps']
        with canonical():
            parts, head = lamp(X, Y, z, on)
            base = cam(X, Y, z)
            parts = scaled(parts, base, LAMP_SCALE, f'pathlamp{i}')
        gb = render_groups(turned(parts), img, D, kind, gid, gb)
        if on:
            lights.append((to_view(scale_pt(head, base, LAMP_SCALE)), 9 * LAMP_SCALE * gp, A.hex2rgb('#ffcf87'), 0.42))
    bC = cam(DOMES['base']['X'], DOMES['base']['Y'], DOMES['base']['Z'])
    if DOMES['base']['powered'] and BASE_DOME != 'rooms':
        lights.append((scale_pt(bC + vrot([6, 4, 41.6]), bC, DOME_SCALE), 6 * DOME_SCALE * gp * 0.6,
                       A.hex2rgb('#ffd27a'), 0.4))
    shard_glints = []
    for d in dome_units():
        if d['style'] in ('hex', 'band'):
            d0 = canon_unit(d['name'])
            with canonical():
                debris_parts, g_ = (glass_debris if d0['style'] == 'hex' else band_debris)(d0, ground0)
            shard_glints += [to_view(q) for q in g_]
            if debris_parts:
                gb = render_groups(turned(debris_parts), img, D, kind, gid, gb)
    with canonical():
        wreck_parts, wreck_fx, debris, body = satellite_wreck(ground0)
    wreck_fx = dict(smoke=[to_view(q) for q in wreck_fx['smoke']], sparks=[to_view(q) for q in wreck_fx['sparks']],
                    beacon=to_view(wreck_fx['beacon']), fire=[to_view(q) for q in wreck_fx['fire']])
    gw0 = gb
    gb = render_groups(turned(wreck_parts), img, D, kind, gid, gb)
    gw1 = gb
    print(f'props in {time.time() - t0:.1f}s')
    gb, flora_out, live, baked, sprites = render_flora(G, img, D, kind, gid, gb)

    depth_lines(img, dark, D, kind, gid)
    del dark
    pre = render_precrash(G, img, kind, gid, gw0, gw1)
    for key in ('nX', 'nY', 'nZ', 'ao', 'tex', 'streak', 'albedo', 'strata', 'spike_rel', 'glow', 'walk_d',
                'patch_f', 'patch_i', 'bglow', 'shadow', 'lane_d', 'crash_d', 'path_d'):
        G.pop(key, None)

    # --- glass
    dome_glints = []
    base_cracks = []
    for d in sorted(dome_units(), key=lambda u: -u['Y']):      # far domes first: near glass shows them
        gb += 1
        if d['style'] == 'hex':
            dome_glints += hex_dome(img, D, kind, gid, d, gb)
        elif d['style'] == 'band':
            g_, damage = band_dome(img, D, kind, gid, d, gb)
            dome_glints += g_
            base_cracks += damage
        else:
            glass_dome(img, D, kind, gid, d, gb, hole=9.0 * DOME_SCALE if d['name'] == 'comms' else 0.0)
    depth_lines(img, img, D, kind, gid, only_kind=4)
    del gid

    # props take the haze of the land they stand in
    for r0 in range(0, H, 512):
        r1 = min(H, r0 + 512)
        jj, ii = np.nonzero(kind[r0:r1] >= 3)
        if jj.size:
            u, v = to_grid((ii + 0.5 - AX) * S, D[r0 + jj, ii])
            bf, bi = sample(G['bio_f'], u, v, order=0), sample(G['bio_i'], u, v, order=0)
            bio[r0 + jj, ii] = np.argmax(np.stack([1 - bf - bi, bf, bi]), axis=0)

    # --- space + silhouette outline, haze, then glows (halos may spill into space)
    filled = kind > 0
    pad = np.pad(filled, 1)
    ring = (pad[:-2, 1:-1] | pad[2:, 1:-1] | pad[1:-1, :-2] | pad[1:-1, 2:]) & ~filled
    del pad
    final = space_backdrop()
    final[filled] = img[filled]
    del img
    final[ring] = OUTLINE
    for r0 in range(0, H, 256):                          # thin air softens the far side
        r1 = min(H, r0 + 256)
        hazed = apply_haze(final[r0:r1], r0, 0, bio[r0:r1])
        final[r0:r1] = np.where(filled[r0:r1, :, None], hazed, final[r0:r1])
    del bio
    for p, rad, colr, s_ in lights:
        sx, sy = project(*p)
        add_glow(final, sx, sy, rad, colr, s_, EMIT)
    EMIT[~filled] = 255                                   # space looks the same by day and night
    EMIT[ring] = 0
    save_png(Image.fromarray(final), os.path.join(OUT, f'red_planet_map{SFX}.png'))
    save_png(Image.fromarray(EMIT, 'L'), os.path.join(OUT, f'red_planet_light{SFX}.png'))
    print(f'light mask: {np.count_nonzero(EMIT[filled] > 127)} lit pixels on the ground')
    glows = collect_glows(G, fxpx, D, baked, sprites)
    rs_g = np.random.default_rng(SEED + 818)
    for x, y in dome_glints:                             # sunlight flashing off the dome's metal
        glows.append([int(x), int(y), 1, 5, 255, 3, int(rs_g.integers(256))])
    for P in shard_glints:                               # and off the broken glass
        px, py = project(*P)
        ix, iy = int(px), int(py)
        if 0 <= ix < W and 0 <= iy < H and D[iy, ix] > P[1] - 2.5:
            glows.append([ix, iy, 0, 5, 230, 3, int(rs_g.integers(256))])
    del fxpx
    paint_live(final, live, sprites)                     # the minimap and previews show them too

    # --- metadata + visibility check
    meta = dict(name='red_planet', image=f'red_planet_map{SFX}.png', size=[W, H],
                origin_px=[AX, AY], world_unit_px={'vertical': PX, 'horizontal': round(1 / S, 4)},
                grid_size_world=N, viewport_assumed=list(VIEWPORT), domes={}, lamps=len(G['lamps']),
                view=k, views=[f'red_planet_map{view_sfx(i)}.json' for i in range(4)])
    boxes = {}
    for name, d in DOMES.items():
        cx, cy = project(d['X'], d['Y'], d['Z'])
        top = max(d['R'] / S, (TOWER_TOP + 31) * DOME_SCALE * PX if name == 'comms' else 0)
        box = [cx - d['R'] / S, cy - top, cx + d['R'] / S, cy + d['R'] * KY * PX]
        boxes[name] = box
        meta['domes'][name] = dict(center_px=[round(cx, 1), round(cy, 1)], radius_world=d['R'],
                                   bbox_px=[round(b, 1) for b in box])
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
    live_glow_flags(flora_out, live, sprites, D)
    flora_depth(live, sprites, D, kind)                  # the player can walk behind the swaying plants
    game = export_game_data(G, D, kind, debris, body, world=(k == 0))
    if game is None:                                     # the world's data comes from view 0
        game = dict(_GAME0 or json.load(open(os.path.join(OUT, 'red_planet_map.json')))['game'])
    else:
        _GAME0 = dict(game)
    game.update(depth_png=f'red_planet_depth{SFX}.png', light_png=f'red_planet_light{SFX}.png', heading=k,
                view_center=[float(VIEW_C[0]), float(VIEW_C[1])],
                view_notes='The game keeps the world in view 0\'s frame. View k shows it turned: view point = '
                           'R_k (P - view_center) + view_center, R_k a quarter turn clockwise k times '
                           '((x, y) -> (y, -x) per turn); the screen formula above applies to the view point.')
    meta['game'] = game
    meta['biomes'] = export_biome_grid(G0)
    meta['minimap'] = export_minimap(final, filled)
    meta['animated'] = export_animated(D)
    fx = dict(flora=flora_out, halos=export_halos(), glow_colors=GLOW_COLORS, glows=glows,
              crash=export_crash(G, pre, wreck_fx, body, kind), cracks=export_cracks(base_cracks),
              doors=export_doors(D, kind))
    save_text(json.dumps(fx, separators=(',', ':')), os.path.join(OUT, f'red_planet_fx{SFX}.json'))
    meta['fx'] = f'red_planet_fx{SFX}.json'
    margin = 24
    frames = {}
    for name, b in DOMES.items():
        bx, by = project(b['X'], b['Y'], b['Z'])
        xs, ys = [bx - b['R'] / S, bx + b['R'] / S], [by - b['R'] / S, by + b['R'] * KY * PX]
        for d, dirv in airlock_ends():
            if d['owner'] == name:
                for z in (0.0, 30.0 * DOME_SCALE):
                    px_, py_ = project(*(np.array([b['X'], b['Y'], b['Z'] + z]) + np.array([*dirv, 0]) * (b['R0'] + 17) * DOME_SCALE))
                    xs.append(px_)
                    ys.append(py_)
        for sp in meta['animated']['sprites']:
            if sp['name'].startswith(name):
                ys.append(sp['position'][1])
        ys.append(project(b['X'], b['Y'], b['Z'] + (b['R0'] + 20) * DOME_SCALE)[1])   # whatever sits on top
        frames[name] = [round(min(xs) - margin), round(min(ys) - margin),
                        round(max(xs) - min(xs) + 2 * margin), round(max(ys) - min(ys) + 2 * margin)]
    meta['zoom'] = dict(max_view_px=frames['base'][2:], frames=frames,
                        note='The furthest zoom-out shows max_view_px of map: the whole main base, no more. '
                             'frames are [x, y, w, h] boxes the camera frames at that zoom.')
    print(f"zoom: furthest view {meta['zoom']['max_view_px']} map px")
    save_text(json.dumps(meta, indent=2), os.path.join(OUT, f'red_planet_map{SFX}.json'))

    # close-ups for quick review (view 0), an overview of every view
    prev = os.path.join(OUT, 'preview')
    os.makedirs(prev, exist_ok=True)
    im = Image.fromarray(final)
    save_png(im.resize((W // 4, H // 4), Image.LANCZOS), os.path.join(prev, f'overview_quarter{SFX}.png'))
    if k != 0:
        print(f'view {k} rendered in {time.time() - t_start:.1f}s')
        return
    for name, box in boxes.items():
        save_png(im.crop((int(box[0] - 120), int(box[1] - 60), int(box[2] + 120), int(box[3] + 80))),
                  os.path.join(prev, f'{name}_closeup.png'))
    for name, (X, Y, w_, h_) in dict(forest=(-150, 2300, 900, 520), forest2=(520, 2700, 900, 520),
                                     ice=(950, 1500, 900, 520), ice2=(380, 800, 900, 520),
                                     seam=(-560, 2050, 900, 520), crash=(CRASH['X'] + 40, CRASH['Y'] + 60, 640, 380),
                                     massif=(980, 1420, 1100, 640), front=(260, 700, 1000, 580)).items():
        cx, cy = project(X, Y, 0.0)
        save_png(im.crop((int(cx - w_ / 2), int(cy - h_ / 2), int(cx + w_ / 2), int(cy + h_ / 2))),
                  os.path.join(prev, f'{name}_closeup.png'))
    save_png(im.resize((W // 4, H // 4), Image.LANCZOS), os.path.join(prev, 'overview_quarter.png'))

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
    save_text('<!doctype html>\n' + page, os.path.join(OUT, 'viewer.html'))
    print(f'view {k} rendered in {time.time() - t_start:.1f}s')


if __name__ == '__main__':
    np.seterr(all='ignore')
    build()
