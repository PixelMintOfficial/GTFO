#!/usr/bin/env python3
"""The approved nursery interior, generated through GTFO's native SDF pipeline.

Writes assets/maps/nursery_interior/: four views of the colour/depth/light/sun
layers, one canonical walk grid, metadata and two animated airlocks. The owner
approved the aligned_v12 room: no crossing boards, one central specimen and a
lower coaxial light on straight supports. No nursery minigames are implemented.
Owner QA: compact furnishings/room, an inlaid floor ring, a two-sided monitor,
and static landing pads kept out of the y-sorted door animation.
Cultivation: eight combinations of console/light/rear-rack repair, per-variant
walk/depth/light layers, crop overlays and generated interaction anchors.
NURSERY_CONDITION=restored preserves the earlier approved intact-room export.
--repair-metadata-only refreshes native repair/scanner anchors without rendering images.

Run through `make nursery`, or python tools/nursery_gen.py. NURSERY_OUT redirects
all outputs for previews; MAP_VIEWS limits renders (all four are needed in game).
The models reuse the existing primitives, palette, room shading and camera.
"""
from pathlib import Path
import json
import math
import os
import sys
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
import mars_map_gen as M
import interior_gen as I
import astronaut_sprite_gen as A

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(os.environ.get('NURSERY_OUT', ROOT / 'assets/maps/nursery_interior'))
P = M.P_
UP = np.array([0., 0., 1.])
C = np.array([0., 520., 0.])
WATER_C = C + np.array([0., -5., 0.])
LAYOUT_SCALE = float(os.environ.get('NURSERY_INTERIOR_SCALE', '.8'))
RADIUS = 185. * LAYOUT_SCALE
ENTRY_RADIUS = RADIUS - 3.
SPAWN = C[:2] + np.array([0., -145.]) * LAYOUT_SCALE
TOWERS = [(-123., 6.), (119., 86.)]
FOOTPRINTS = []
PODS = []
ENTRIES = [(i, n.copy()) for i, (d, n) in enumerate(M.airlock_ends()) if d['owner'] == 'nursery']

def at(x=0., y=0., z=0.):
    return C + np.array([x, y, z])

def box(c, half, ramp, group, rounding=1., yaw=0., decal=None):
    return P('housing', A.RoundBox(c, half, rounding, A.rz(yaw)), ramp, group, decal)

def disc(c, r, half, ramp, group, rounding=.6):
    return P('cylinder', A.Disc(c, r, half, rounding, M.UPAX), ramp, group)

def ring(c, r, width, ramp, group):
    return P('ring', A.Torus(c, r, width), ramp, group)

def foot(c, rx, ry=None):
    FOOTPRINTS.append((c[0], c[1], rx, rx if ry is None else ry))

def rosette(c, size, seed, group, flower=False):
    """Broad leaves from the nursery's existing green ramps; alien curled centre."""
    rs = np.random.default_rng(seed)
    parts = []
    phase = rs.uniform(0, math.tau)
    for j in range(7):
        a = phase + j * math.tau / 7
        d = np.array([math.cos(a), math.sin(a), 0.])
        p = c + d * size * .44 + UP * size * .25
        tilt = A.rz(a) @ A.ry(-.28 - .16 * (j % 2))
        parts.append(P('leaf', A.Ellipsoid(p, (size * .72, size * .23, size * .14), tilt),
                       'leaf2' if j % 3 else 'leaf', group))
    parts.append(P('bud', A.Ellipsoid(c + UP * size * .55, (size * .23, size * .23, size * .52)),
                   'leaf2', group))
    if flower:
        p = c + UP * size * 1.15
        parts.append(P('stalk', A.RoundCone(c, p, .55, .35), 'leafa', group))
        for j in range(5):
            a = phase + j * math.tau / 5
            q = p + np.array([math.cos(a), math.sin(a), .18]) * size * .22
            parts.append(P('blossom', A.Ellipsoid(q, (size * .24, size * .19, size * .14)), 'blossom', group))
        parts.append(P('pollen', A.Sphere(p + UP * .5, size * .12), 'mustard', group))
    return parts

def tower(c, seed, group, height=54.):
    """Three tiers of planting cups around a white irrigation column and light halo."""
    foot(c, 20.)
    parts = [disc(c + UP * 4., 19., 4., 'white', group),
             ring(c + UP * 4., 18., .8, 'teal', group),
             disc(c + UP * (height / 2 + 4), 7., height / 2, 'white', group),
             box(c + np.array([0., -18., 5.]), (4., .6, 1.5), 'dark', group),
             box(c + np.array([0., -18.7, 5.4]), (2.7, .25, .45), 'ledcyan', group)]
    for tier, z in enumerate((17., 31., 45.)):
        g = group + f'_tier{tier}'
        parts += [disc(c + UP * z, 12.5, 1.7, 'white', g),
                  ring(c + UP * (z - 2), 11.5, .65, 'teal', g)]
        for j in range(5):
            a = (j / 5 + tier * .08) * math.tau
            b = c + np.array([math.cos(a) * 10., math.sin(a) * 10., z + 2.])
            parts += rosette(b, 5.8, seed + j + tier * 8, g)
    parts += [disc(c + UP * (height + 5), 8., 2., 'white', group),
              ring(c + UP * (height + 7), 21., 1.6, 'white', group + '_halo'),
              ring(c + UP * (height + 6), 19.5, .65, 'ledcyan', group + '_halo')]
    for a in (0., math.pi):
        d = np.array([math.cos(a), math.sin(a), 0.])
        parts.append(P('light_arm', A.RoundCone(c + UP * (height + 5),
                                               c + d * 20 + UP * (height + 7), .8, .6), 'white', group + '_halo'))
    return parts

def console(c, group, wide=18.):
    foot(c, wide, 10.)
    parts = [box(c + UP * 10., (wide, 9., 10.), 'white', group, 2.),
             box(c + UP * 20.5, (wide + 1., 10., 1.5), 'teal', group, 1.),
             box(c + np.array([0., 3., 23.]), (wide - 3, 2.5, 2.), 'dark', group, .8, decal=M.decal_console)]
    # Existing screen material in a framed raised panel, with solid pixel-width readouts.
    screen = c + np.array([0., 1., 33.])
    parts += [box(screen, (wide - 2, 1.1, 8.), 'steel', group, 1.)]
    for side in (-1, 1):
        parts += [box(screen + np.array([0., side * 1.25, 0.]), (wide - 3, .3, 7.), 'screen', group, .4)]
        for j in range(4):
            parts.append(box(screen + np.array([-wide + 6 + j * 6, side * 1.65, -2. + j % 2]),
                             (1.1, .25, 2. + j % 3), 'teal', group, .1))
    return parts

def reservoir(c, group):
    foot(c, 14.)
    return [disc(c + UP * 3., 14., 3., 'white', group),
            disc(c + UP * 19., 11.5, 15., 'teal', group),
            disc(c + UP * 35., 13., 2., 'white', group),
            box(c + np.array([0., -11.6, 20.]), (3., .7, 9.), 'dark', group),
            box(c + np.array([0., -12.4, 20.]), (1., .3, 6.), 'liquid', group)]

def rod(a, b, width, ramp, group):
    return P('strut', A.RoundCone(a, b, width, width), ramp, group)

def annulus(c, radius, width, half, ramp, group, back_only=False):
    """A ring-shaped container, carved from native cylinders and a box."""
    outer = A.Disc(c, radius + width, half, .6, M.UPAX)
    inner = A.Disc(c, radius - width, half + 4, .4, M.UPAX)
    shape = I.Cut(outer, inner)
    if back_only:
        shape = I.Cut(shape, A.RoundBox(c + np.array([0., -300., 0.]), (400., 300., 300.), .1))
    return P('curved_container', shape, ramp, group)

def flowering_tree(c, scale, group):
    native, _ = M.nursery_interior(dict(X=c[0], Y=c[1], Z=c[2]))
    return M.scaled([p for p in native if p.group == 'tree'], c, scale, group)

def green_wall(c, yaw, seed, group):
    R = A.rz(yaw)
    foot(c, 23., 9.)
    parts = [box(c + UP * 42., (24., 4., 42.), 'white', group, 1.8, yaw),
             box(c + R @ np.array([0., -4.2, 42.]), (21., .7, 37.), 'leafa', group, .5, yaw)]
    for tier, z in enumerate((10., 30., 50., 70.)):
        b = c + R @ np.array([0., -11., z])
        parts += [box(b, (22., 8., 2.), 'white', group + f'_shelf{tier}', 1., yaw),
                  box(b + R @ np.array([0., -7.6, -.7]), (20., .5, .4), 'ledcyan', group + f'_shelf{tier}', .1, yaw)]
        for j, x in enumerate((-15., -5., 5., 15.)):
            p = b + R @ np.array([x, -1., 3.])
            parts += rosette(p, 8., seed + tier * 10 + j, group + f'_plant{tier}_{j}', (tier + j) % 3 == 0)
    parts += [box(c + UP * 84., (24., 7., 1.5), 'white', group, .8, yaw),
              box(c + R @ np.array([0., -6.8, 82.7]), (22., .3, .6), 'ledcyan', group, .1, yaw)]
    return parts

def entrance(normal, index, open_=0.0, landing=True):
    """The existing interior's white/coral telescoping portal, facing into this room."""
    k = I.DOOR_K
    f = at(*(normal * ENTRY_RADIUS), 6.9 * k)
    out = np.array([-normal[0], -normal[1], 0.])
    side = np.array([-out[1], out[0], 0.])
    R = M.yaw_to(out)
    group = f'entry{index}'
    # Like the cutaway wall, expose the chamber from the current camera side.
    # Otherwise a front-wall door's opaque rear chamber hides its moving leaves.
    chamber_out = out if out @ M.crot(M.F) < 0 else -out
    parts = [P('portal', A.RoundBox(f + out * .5 * k + UP * 7.9 * k,
                                   np.array([1.3, 8.4, 1.1]) * k, .5 * k, R), 'white', group),
             P('threshold', A.RoundBox(f + out * .5 * k - UP * 6.9 * k,
                                      np.array([3., 8.4, .25]) * k, .2 * k, R), 'dark', group),
             P('lamp', A.Sphere(f + out * 1.4 * k + UP * 7.9 * k, .9 * k), 'ledcyan', group),
             P('chamber', A.RoundBox(f - chamber_out * .6 * k, np.array([.4, 6.4, 6.9]) * k, .3 * k, R), 'darkwin', group)]
    openness = open_
    eased = openness * openness * (3 - 2 * openness)
    for sign in (-1, 1):
        parts += [P('portal', A.RoundBox(f + out * .5 * k + side * sign * 7.45 * k,
                                        np.array([1.3, 1., 7.9]) * k, .5 * k, R), 'white', group)]
        hw = 3.2 * (1 - .9 * eased)
        parts += [P('half', A.RoundBox(f - out * .35 * eased * k + side * sign * (6.4 - hw) * k,
                                      np.array([.75, hw, 6.9]) * k, .35 * k, R), 'coral', group, M.decal_door_half)]
    if landing:
        # A static floor inlay: including it in the door sprite puts it in front of
        # the arriving astronaut's body, regardless of the map's depth shader.
        q = at(*(normal * (ENTRY_RADIUS - 24.)))
        parts += [P('landing', A.RoundBox(q - UP * .45, (12., 20., .5), .5, R), 'white', group)]
    return parts

def water_loop():
    parts = [annulus(WATER_C - UP, 69., 8.5, 1., 'white', 'water_housing'),
             annulus(WATER_C - UP * .1, 69., 5.8, .15, 'liquid', 'circulating_water'),
             ring(WATER_C - UP * .22, 77., .3, 'teal', 'water_edge'),
             disc(WATER_C - UP * .5, 58., .5, 'white', 'island_floor')]
    foot(WATER_C, 78.)
    # Four floating propagation cups leave the shallow channel open.
    for j in range(8):
        a = (j + .5) * math.tau / 8
        if j % 2:
            continue
        b = WATER_C + np.array([math.cos(a) * 69, math.sin(a) * 69, 1.])
        parts += [disc(b, 6., 1., 'white', f'raft{j}'), disc(b + UP * 1.1, 4.7, .3, 'soil', f'raft{j}')]
        parts += rosette(b + UP * 2, 5.5, 2800 + j, f'water_seedling{j}', True)
    # Feed and return conduits make the shared irrigation system visible.
    for j, (tx, ty) in enumerate(TOWERS):
        sign = -1 if tx < 0 else 1
        pts = [WATER_C + np.array([sign * 51., 51., 1.]), at(sign * 86, 73, 1.), at(tx, ty, 1.)]
        for k in range(len(pts) - 1):
            parts += [rod(pts[k], pts[k + 1], .95, 'white', f'feed{j}_{k}'),
                      rod(pts[k] + UP * .7, pts[k + 1] + UP * .7, .4, 'teal', f'feed{j}_{k}')]
    return parts

def rear_gardens():
    parts = []
    for j, deg in enumerate((69., 90., 111.)):
        a = math.radians(deg)
        parts += green_wall(at(math.cos(a) * 155, math.sin(a) * 155), a - math.pi / 2,
                              2900 + j * 50, f'living_wall{j}')
    for j, (x, y) in enumerate(TOWERS):
        parts += tower(at(x, y), 3100 + j * 50, f'light_tower{j}')
    # Small light controls are reached from the shared outer circulation loop.
    for j, (x, y) in enumerate(((-53., 108.), (83., 102.))):
        c = at(x, y)
        parts += [box(c + UP * 9., (7., 5., 9.), 'white', f'light_pedestal{j}', 1.),
                  box(c + np.array([0., -5.4, 13.]), (5., .4, 3.), 'screen', f'light_pedestal{j}', .3)]
    return parts

def specimen_pod(c, seed, group, plant='flower'):
    radius = 24.
    foot(c, radius + 2.)
    parts = [disc(c + UP * 5., radius + 2., 5., 'white', group),
             ring(c + UP * 6., radius + 1., .65, 'teal', group),
             disc(c + UP * 10.5, radius - 1., .5, 'soil', group),
             box(c + np.array([0., -radius - 2., 6.]), (6., .8, 1.8), 'dark', group, .4),
             box(c + np.array([0., -radius - 2.9, 6.]), (3.5, .25, .5), 'ledcyan', group, .1)]
    b = c + UP * 12.
    if plant == 'flower':
        parts += flowering_tree(b, .43, group + '_specimen')
    else:
        parts += M.scaled(M.curl_fern(b, 9), b, 1., group + '_specimen')
    for j in range(5):
        a = j * math.tau / 5
        parts += rosette(b + np.array([math.cos(a) * 16, math.sin(a) * 16, 0.]),
                          5.5, seed + j, group + f'_cutting{j}', j % 2 == 0)
    PODS.append(dict(X=c[0], Y=c[1], Z=11., R=radius, ribs=6))
    return parts


def furniture():
    """The approved v12 composition, built once in canonical room coordinates."""
    FOOTPRINTS.clear()
    PODS.clear()
    parts = water_loop()
    parts += rear_gardens()
    parts += console(at(0, -127), 'central_control', 17.)
    parts += specimen_pod(at(0, 2), 3400, 'central_specimen')
    parts += reservoir(at(135, -15), 'lab_reservoir')
    for j, sign in enumerate((-1, 1)):
        b = at(sign * 34, 2)
        parts += [disc(b + UP, 2.8, 1., 'white', f'light_foot{j}'),
                  rod(b + UP, b + UP * 54., 1., 'white', f'aligned_light_leg{j}')]
    parts += [ring(at(0, 2, 54), 34., 1.4, 'white', 'aligned_light_ring'),
              ring(at(0, 2, 52.8), 32.8, .55, 'ledcyan', 'aligned_light_ring')]
    # Scale geometry, collision, AO and the glass pod together; the astronaut and
    # airlock frames keep the game's shared scale.
    FOOTPRINTS[:] = [(C[0] + (x - C[0]) * LAYOUT_SCALE, C[1] + (y - C[1]) * LAYOUT_SCALE,
                     rx * LAYOUT_SCALE, ry * LAYOUT_SCALE) for x, y, rx, ry in FOOTPRINTS]
    for pod in PODS:
        pod.update(X=C[0] + (pod['X'] - C[0]) * LAYOUT_SCALE,
                   Y=C[1] + (pod['Y'] - C[1]) * LAYOUT_SCALE,
                   Z=pod['Z'] * LAYOUT_SCALE, R=pod['R'] * LAYOUT_SCALE)
    return [P(p.name, M.Scaled(p.sdf, C, LAYOUT_SCALE), p.ramp, p.group, p.decal) for p in parts]


def setup_room():
    # Reuse the base's room shaders in a separate generator process. The base generator
    # is not run and no base art/settings are written by this module.
    M.VIEW_C = C.copy()
    M.SUN = I.SUN_IN
    I.ROOMS = {'storage': dict(X=0., Y=520., R=RADIUS, label='NURSERY'),
               'power': dict(X=10000., Y=10000., R=1., label='')}
    I.CORRIDORS, I.HOLES = [], []
    I.WALL_H, I.WALL_LOW = 77. * LAYOUT_SCALE, 4.5
    I.WIN = (35. * LAYOUT_SCALE, 71. * LAYOUT_SCALE)
    I.CORAL = (27. * LAYOUT_SCALE, 30. * LAYOUT_SCALE)
    M.W, M.H, M.AX = 1300, 900, 650.
    M.AY = 588. + M.KY * C[1] * M.PX


def wall_parts():
    shape = I.RoomWall('storage', [])
    for _, normal in ENTRIES:
        c = at(*(normal * ENTRY_RADIUS), 16.)
        shape = I.Cut(shape, A.RoundBox(c, (12., 6.4 * I.DOOR_K, 16.3), .2,
                                       M.yaw_to(np.array([-normal[0], -normal[1], 0.]))))
    return [P('wall', shape, 'white', 'wall_storage')]


def world_grid(parts, filename='nursery_walk.png', furniture_approaches=None):
    """Canonical collision from the actual low geometry, like interior_gen's walk grid.

    Water is a shallow scenery channel (the existing player has no swimming volume).
    Its low trim, cups, feed lines and door thresholds are traversable. Furniture,
    the specimen plinth and straight light supports remain solid.
    """
    n = I.N
    u, v = np.meshgrid(np.arange(n) + .5, np.arange(n) + .5, indexing='ij')
    x, y = (u - v) / M.SQ2, (u + v) / M.SQ2
    foot = np.zeros((n, n), bool)
    for p in parts:
        if p.group in ('water_housing', 'circulating_water', 'water_edge', 'island_floor') or p.group.startswith(
                ('raft', 'water_seedling', 'feed', 'entry')):
            continue
        c, radius = M.part_bound(p.sdf)
        if c[2] - radius > 9.:
            continue
        gu, gv = M.to_grid(c[0], c[1])
        w = int(radius) + 3
        a0, a1 = max(0, int(gu) - w), min(n, int(gu) + w + 1)
        b0, b1 = max(0, int(gv) - w), min(n, int(gv) + w + 1)
        if a0 >= a1 or b0 >= b1:
            continue
        xx, yy = x[a0:a1, b0:b1].ravel(), y[a0:a1, b0:b1].ravel()
        hit = np.zeros(len(xx), bool)
        for z in (.6, 3., 6., 9.):
            hit |= p.sdf(np.stack((xx, yy, np.full_like(xx, z)), axis=1)) < .3
        foot[a0:a1, b0:b1] |= hit.reshape(a1 - a0, b1 - b0)
    walk = (np.hypot(x, y - C[1]) < RADIUS - 5.) & ~ndi.binary_dilation(foot, iterations=1)
    connected, _ = ndi.label(walk)
    def component(point):
        u, v = M.to_grid(point[0], point[1])
        return connected[int(u), int(v)]
    spawn_component = component(SPAWN)
    assert spawn_component, 'Room spawn must be walkable'
    approaches = [C[:2] + normal * (ENTRY_RADIUS - 26.) for _, normal in ENTRIES]
    if furniture_approaches is None:
        furniture_approaches = [M.scale_pt(at(x, y), C, LAYOUT_SCALE)
                                for x, y in ((0, -40), (-90, 6), (102, -15), (0, 80))]
    approaches += furniture_approaches
    assert all(component(p) == spawn_component for p in approaches), 'Room approaches must connect'
    # Door approach/arrival stands are inside the wall. Ordinary movement never crosses
    # the outer shell; the existing airlock cutscene puppets through its opening.
    h = int(M.HEIGHT_OFFSET * M.HEIGHT_SCALE)
    grid = np.empty((n, n, 3), np.uint8)
    grid[..., 0], grid[..., 1], grid[..., 2] = h >> 8, h & 255, walk * 255
    M.save_png(Image.fromarray(grid.transpose(1, 0, 2).copy()), str(OUT / filename))
    return walk


def render_door(index, normal):
    frames = [M.turned(entrance(normal, index, f / (M.DOOR_FRAMES - 1), landing=False)) for f in range(M.DOOR_FRAMES)]
    bounds = M.sprite_box(frames, pad=3)
    strip = np.concatenate([M.sprite_rgba(M.render_sprite(parts, bounds)) for parts in frames], axis=1)
    filename = f'anim/door_{index}{M.SFX}.png'
    M.save_png(Image.fromarray(strip), str(OUT / filename))
    base = at(*(normal * ENTRY_RADIUS))
    inward = np.array([-normal[0], -normal[1], 0.])
    lamp = base + inward * 1.4 * I.DOOR_K + UP * 14.8 * I.DOOR_K
    return dict(id=index, file=filename, frames=M.DOOR_FRAMES, position=list(bounds[:2]),
                frame_size=list(bounds[2:]), sort_y=round(M.project(*M.to_view(base))[1]),
                world=base[:2].tolist(), dir=inward[:2].tolist(), lamp_px=list(M.project(*M.to_view(lamp))),
                height=14.8 * I.DOOR_K)


def render_view(k, parts, name_base='nursery', walk_file='nursery_walk.png', extra=None, room_name='nursery'):
    M.VIEW, M.SFX = k, M.view_sfx(k)
    M.EMIT = np.zeros((M.H, M.W), np.uint8)
    img = np.full((M.H, M.W, 3), A.hex2rgb('#0b0915'), np.uint8)
    depth = np.full((M.H, M.W), np.inf, np.float32)
    kind = np.zeros((M.H, M.W), np.uint8)
    gid = np.zeros((M.H, M.W), np.int32)
    yy, xx = np.mgrid[:M.H, :M.W]
    bay = M.BAYER[yy % 4, xx % 4]
    rays = I.view_rays(yy.ravel(), xx.ravel())
    t = -rays[:, 2] / M.F[2]
    floor = rays + t[:, None] * M.F
    canon = M.to_canon(floor)
    x, y = canon[:, 0].reshape(depth.shape), canon[:, 1].reshape(depth.shape)
    hit = np.hypot(x, y - C[1]) < RADIUS
    depth[hit], kind[hit] = floor[:, 1].reshape(depth.shape)[hit], 1
    ys, xs = np.nonzero(hit)
    ao = np.zeros(len(ys))
    for cx, cy, rx, ry in FOOTPRINTS:
        rr = np.sqrt(((x[hit] - cx) / rx) ** 2 + ((y[hit] - cy) / ry) ** 2)
        ao = np.maximum(ao, np.clip(1.2 - rr, 0, 1) * .62)
    floor_light, _ = I.shade_floor(img, depth, kind, np.ones(len(ys), np.uint8),
                                 x[hit], y[hit], ys, xs, bay[hit], ao, None)
    gb = M.render_groups(M.turned(wall_parts()), img, depth, kind, gid, 1)
    wall_ids = np.arange(1, gb)
    wall_light, _, _ = I.shade_walls(img, depth, gid, wall_ids, bay)
    wy, wx = np.nonzero(np.isin(gid, wall_ids))
    wr = I.view_rays(wy, wx)
    wt = (depth[wy, wx] - wr[:, 1]) / M.F[1]
    wz = (wr + wt[:, None] * M.F)[:, 2]
    windows = np.zeros(depth.shape, bool)
    windows[wy, wx] = (wz > I.WIN[0]) & (wz < I.WIN[1])
    gb = M.render_groups(M.turned(parts), img, depth, kind, gid, gb)
    for index, normal in ENTRIES:
        gb = M.render_groups(M.turned(entrance(normal, index)), img, depth, kind, gid, gb)
    M.depth_lines(img, (img.astype(float) * .62).astype(np.uint8), depth, kind, gid)
    for j, pod in enumerate(PODS):
        c = M.to_view([pod['X'], pod['Y'], pod['Z']])
        M.glass_dome(img, depth, kind, gid, dict(pod, X=c[0], Y=c[1]), gb + j)
    # Masks follow the final visible surface, so a hidden window never lights foreground
    # furniture at night. Window light is daylight; powered lamps/screens/water persist.
    visible_wall = np.isin(gid, wall_ids)
    light = np.maximum(floor_light * (gid == 0), wall_light * visible_wall * ~windows)
    light = np.maximum(light, M.EMIT.astype(np.float32) / 255.)
    sun = wall_light * visible_wall * windows
    glow = ndi.gaussian_filter(M.EMIT.astype(np.float32) / 255., 2.)
    img = np.clip(img.astype(float) + glow[..., None] * np.array([9., 19., 18.]), 0, 255).astype(np.uint8)
    filled = kind > 0
    border = ndi.binary_dilation(filled) & ~filled
    img[border] = M.OUTLINE
    light[~filled], sun[~filled] = 1., 0.
    light[border] = 0.
    name = f'{name_base}{M.SFX}'
    M.save_png(Image.fromarray(img), str(OUT / f'{name}.png'))
    for suffix, values in [('light', light), ('sun', sun)]:
        M.save_png(Image.fromarray(np.round(np.clip(values, 0, 1) * 255).astype(np.uint8)),
                   str(OUT / f'{name_base}_{suffix}{M.SFX}.png'))
    dq = np.where(filled, np.clip(depth * M.DEPTH_SCALE, 0, 65534), 65535).astype(np.uint32)
    dimg = np.zeros((M.H, M.W, 3), np.uint8)
    dimg[..., 0], dimg[..., 1] = dq >> 8, dq & 255
    dimg[..., 2] = np.where((kind == 4) | (visible_wall & windows), 255, 0)
    M.save_png(Image.fromarray(dimg), str(OUT / f'{name_base}_depth{M.SFX}.png'))
    doors = [render_door(index, normal) for index, normal in ENTRIES]
    meta = dict(name=f'{room_name}_interior', image=f'{name}.png', size=[M.W, M.H], origin_px=[M.AX, M.AY],
                view=k, views=[f'{name_base}{M.view_sfx(i)}.json' for i in range(4)],
                game=dict(depth_png=f'{name_base}_depth{M.SFX}.png', light_png=f'{name_base}_light{M.SFX}.png',
                          sun_png=f'{name_base}_sun{M.SFX}.png', walk_png=walk_file,
                          depth_scale=M.DEPTH_SCALE, height_offset=M.HEIGHT_OFFSET, height_scale=M.HEIGHT_SCALE,
                          world_units_per_px=M.S, depth_to_px=M.KY, px_per_unit=M.PX,
                          character_scale=.5, grid_size=I.N, spawn_world=SPAWN.tolist(), heading=k,
                          layout_scale=LAYOUT_SCALE,
                          view_center=C[:2].tolist()),
                zoom=dict(max_view_px=[M.W, M.H], frames={}), doors=doors,
                rooms={room_name: dict(label=room_name.upper(), center=C[:2].tolist(), radius=RADIUS)},
                fx=dict(shafts=[], leds=[], core=[0, 0], tanks=[], sparks=[], vapor=[]))
    if extra:
        meta.update(extra)
    M.save_text(json.dumps(meta, indent=2), str(OUT / f'{name}.json'))
    M.save_png(Image.fromarray(img), str(OUT / 'preview' / f'{name}.png'))
    print(f'{room_name} view {k}: {len(doors)} animated exits', flush=True)


def build_restored():
    setup_room()
    (OUT / 'anim').mkdir(parents=True, exist_ok=True)
    (OUT / 'preview').mkdir(exist_ok=True)
    parts = furniture()
    world_grid(parts)
    M.save_text(json.dumps(dict(sprites={}, objects=[], lamps=[])), str(OUT / 'nursery_props.json'))
    for k in M.VIEWS:
        render_view(k, parts)
    print('nursery generated ->', OUT, flush=True)


if __name__ == '__main__':
    np.seterr(all='ignore')
    if '--repair-metadata-only' in sys.argv:
        from nursery_cultivation import repair_metadata_only
        repair_metadata_only(sys.modules[__name__])
    elif os.environ.get('NURSERY_CONDITION', 'damaged') == 'restored':
        build_restored()
    else:
        from nursery_cultivation import build
        build(sys.modules[__name__])
