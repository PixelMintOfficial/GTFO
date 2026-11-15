"""The opening cutscene's art: the ship's cockpit, planet Araxys from orbit, the ship in space.

Everything here is drawn through the game's own camera (2:1 pixel isometric, orthographic, 30
degree pitch) with the shared SDF renderer, ramps, outline and cel shading, at one map pixel per
game pixel, so the cutscene looks like the rest of the game (AGENTS.md section 6, section 7).
scripts/intro_cutscene.gd plays it.

  cockpit.png      384x216, the cockpit as a cut-away room turned onto the walk grid's diagonals
                   (a diamond floor, two far walls, the near walls cut low). Its windscreen and
                   everything outside the room are transparent: the script draws space, or the
                   fire of re-entry, behind it.
  planet.png       PLANET_FRAMES frames of Araxys turning: red dust, the alien forest, ice caps.
  ship_orbit.png   the ship in space, small, engines lit (the same model as the wreck).
  intro.json       sizes, and every position the script animates, in plate pixels:
                   cockpit.pilot (the astronaut's feet, facing N), radio (its LED), alarms (the
                   two red lamps), screens (console screens that flicker), sparks (where the
                   console shorts out); planet.radius / centre / frames; ship.size / engines.

Run: .venv/bin/python tools/intro_gen.py   (seconds; make intro)
The ship's model lives in mars_map_gen.py (ship_parts) so the wreck and this match.
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mars_map_gen as M  # noqa: E402

A = M.A
P_ = M.P_
OID = M.OID
OUT = os.path.join(M.ROOT, 'assets', 'intro')
PLATE = (384, 216)
PLANET_FRAMES = 24
PLANET_R = 34.0                    # world units: about 78 px across... radius in px = R / S
TAU = 2 * math.pi
R45 = A.rz(math.pi / 4)            # local x -> the grid's +u, local y -> +v: a room on the diagonals

ROOM = 31.0                        # the cockpit floor's half size along u and v
WALL_H = 34.0
WALL_T = 1.3
WIN = (13.0, 31.0)                 # the windscreen band
DOOR_V = -ROOM + 17.0              # the right-hand wall keeps its front end solid: the hatch is there


def g(u, v, z=0.0):
    """A world point from grid coordinates (u along the right-hand wall's normal, v the left's)."""
    return np.array([(u - v) / math.sqrt(2), (u + v) / math.sqrt(2), z])


# ---------------------------------------------------------------- decals
def decal_floor(part, P):
    u = (P[:, 0] + P[:, 1]) / math.sqrt(2)
    v = (P[:, 1] - P[:, 0]) / math.sqrt(2)
    out = np.full(len(P), OID['white'])
    out[(np.floor(u / 8.5) + np.floor(v / 8.5)) % 2 == 1] = OID['metal']         # glossy diamond tiles
    out[P[:, 2] < 1.8] = OID['dark']
    return out


def decal_wall(axis, door_lo=None):
    def decal(part, P):
        along = part.sdf.local(P)[:, axis]
        z = P[:, 2]
        out = np.full(len(P), OID['white'])
        out[z < 3.4] = OID['dark']                                                # the kick plate
        out[(z > 10.0) & (z < 11.6)] = OID['coral']                               # the coral strip
        win = (z > WIN[0]) & (z < WIN[1]) & (np.mod(along + 100.0, 11.0) > 1.3)
        if door_lo is not None:
            win &= along > door_lo
        out[win] = OID['void']                                                    # the windscreen: see-through
        return out
    return decal


def decal_console(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['metal'])
    out[q[:, 2] > part.sdf.half[2] - 0.9] = OID['dark']
    out[q[:, 2] < -part.sdf.half[2] + 1.6] = OID['dark']
    return out


def decal_screens(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['dark'])
    top = q[:, 2] > 0.1
    cells = top & (np.mod(q[:, 1] + 50.0, 9.0) > 1.6) & (np.abs(q[:, 0]) < part.sdf.half[0] - 0.9)
    out[cells] = OID['screen']
    return out


def decal_radio(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['pack'])
    out[(q[:, 2] > 0.4) & (np.mod(q[:, 1] + 20.0, 1.4) < 0.6)] = OID['dark']      # speaker grille
    return out


def decal_door(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['mustard'])
    hy, hz = part.sdf.half[1], part.sdf.half[2]
    out[(np.abs(q[:, 1]) > hy - 1.4) | (np.abs(q[:, 2]) > hz - 1.4)] = OID['dark']
    out[(np.abs(q[:, 2] - 1.0) < 0.9) & (np.abs(q[:, 1]) < hy * 0.55)] = OID['dark']
    return out


def decal_seat(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['coral'])
    out[np.abs(q[:, 1]) > part.sdf.half[1] - 1.0] = OID['dark']
    return out


# ---------------------------------------------------------------- the cockpit
def cockpit_parts():
    H, Wh, T = ROOM, WALL_H, WALL_T
    parts = [P_('floor', A.RoundBox(g(0, 0, 1.2), [H, H, 1.2], 0.5, R45), 'white', 'floor', decal_floor),
             P_('wallu', A.RoundBox(g(H + T, 0, Wh / 2), [T, H + 2 * T, Wh / 2], 0.5, R45), 'white', 'wallu',
                decal_wall(1, DOOR_V + 4.0)),
             P_('wallv', A.RoundBox(g(0, H + T, Wh / 2), [H + 2 * T, T, Wh / 2], 0.5, R45), 'white', 'wallv', decal_wall(0)),
             P_('lowu', A.RoundBox(g(-H - T, 0, 2.6), [T, H + 2 * T, 2.6], 0.5, R45), 'white', 'lowu', decal_wall(1)),
             P_('lowv', A.RoundBox(g(0, -H - T, 2.6), [H + 2 * T, T, 2.6], 0.5, R45), 'white', 'lowv', decal_wall(0)),
             # the hatch, in the right-hand wall's solid front end
             P_('door', A.RoundBox(g(H - 0.2, DOOR_V - 6.0, 13.0), [0.8, 5.6, 11.0], 1.0, R45), 'mustard', 'door', decal_door)]
    # the L of consoles round the far corner, screens on their sloping tops
    for name, c, half in (('consu', g(H - 5.0, 6.0, 6.0), [4.6, H - 9.0, 6.0]),
                          ('consv', g(6.0, H - 5.0, 6.0), [H - 9.0, 4.6, 6.0])):
        parts.append(P_(name, A.RoundBox(c, half, 1.2, R45), 'metal', name, decal_console))
    tilt_u = R45 @ A.ry(math.radians(28))
    tilt_v = R45 @ A.rz(math.pi / 2) @ A.ry(math.radians(28))
    parts += [P_('scru', A.RoundBox(g(H - 6.0, 8.0, 13.2), [3.6, H - 14.0, 0.5], 0.3, tilt_u), 'dark', 'consu', decal_screens),
              P_('scrv', A.RoundBox(g(8.0, H - 6.0, 13.2), [3.6, H - 14.0, 0.5], 0.3, tilt_v), 'dark', 'consv', decal_screens),
              # the radio on the right-hand console's end, its LED on top
              P_('radio', A.RoundBox(g(H - 5.5, -8.0, 15.0), [3.0, 4.2, 3.0], 0.8, R45), 'pack', 'radio', decal_radio),
              # the flight stick
              P_('stick', A.RoundCone(g(6.0, H - 9.5, 12.0), g(5.0, H - 11.5, 18.0), 0.7, 0.5), 'dark', 'consv'),
              P_('knob', A.Sphere(g(5.0, H - 11.6, 18.6), 1.3), 'coral', 'consv'),
              # alarm lamps on the walls' tops
              P_('alarm', A.Sphere(g(H + T, -2.0, Wh + 0.6), 1.6), 'beacon', 'wallu'),
              P_('alarm', A.Sphere(g(-2.0, H + T, Wh + 0.6), 1.6), 'beacon', 'wallv'),
              # the empty commander's chair, swung round
              P_('chair', A.Disc(g(-12.0, 4.0, 3.6), 2.2, 3.6, 0.4, M.UPAX), 'dark', 'chair'),
              P_('seat', A.RoundBox(g(-12.0, 4.0, 8.4), [5.2, 5.4, 1.4], 1.0, R45 @ A.rz(0.5)), 'coral', 'chair', decal_seat),
              P_('back', A.RoundBox(g(-16.4, 6.4, 14.0), [1.3, 5.4, 6.0], 1.0, R45 @ A.rz(0.5) @ A.ry(0.18)), 'coral', 'chair',
                 decal_seat),
              # pipes along the walls' tops
              P_('pipe', A.RoundCone(g(H + 2.2, -H, Wh - 3.0), g(H + 2.2, H, Wh - 3.0), 0.9, 0.9), 'metal', 'wallu'),
              P_('pipe', A.RoundCone(g(-H, H + 2.2, Wh - 3.0), g(H, H + 2.2, Wh - 3.0), 0.9, 0.9), 'metal', 'wallv')]
    return parts


def plate_box(centre_px):
    cx, cy = centre_px
    return int(round(cx - PLATE[0] / 2)), int(round(cy - PLATE[1] / 2)), PLATE[0], PLATE[1]


def render_cockpit():
    parts = cockpit_parts()
    top = M.project(*g(ROOM, ROOM, WALL_H))
    bottom = M.project(*g(-ROOM, -ROOM, 0.0))
    left, right = M.project(*g(-ROOM, ROOM, 0.0)), M.project(*g(ROOM, -ROOM, 0.0))
    # framed high: the wall tops clear the letterbox, the radio's subtitles sit over the near floor
    box = plate_box(((left[0] + right[0]) / 2, top[1] - 26 + PLATE[1] / 2))
    del bottom
    fr = M.render_sprite(parts, box)
    rgba = M.sprite_rgba(fr)
    void = (rgba[..., :3] == 0).all(axis=-1) & (rgba[..., 3] > 0)                 # the windscreen's panes
    rgba[void] = 0

    def px(P):
        x, y = M.project(*P)
        return [int(round(x - box[0])), int(round(y - box[1]))]

    data = dict(file='cockpit.png', size=list(PLATE),
                pilot=dict(feet=px(g(9.0, H_PILOT, 3.0)), facing='N'),
                radio=px(g(ROOM - 5.5, -8.0, 18.4)),
                alarms=[px(g(ROOM + WALL_T, -2.0, WALL_H + 0.6)), px(g(-2.0, ROOM + WALL_T, WALL_H + 0.6))],
                screens=[px(g(ROOM - 6.0, v, 13.6)) for v in (-2.0, 7.0, 16.0)] + [px(g(u, ROOM - 6.0, 13.6)) for u in (-2.0, 7.0, 16.0)],
                sparks=[px(g(ROOM - 6.0, 2.5, 14.5)), px(g(12.0, ROOM - 6.0, 14.5)), px(g(ROOM - 5.5, -8.0, 18.0))])
    return rgba, data


H_PILOT = ROOM - 16.0


# ---------------------------------------------------------------- the planet
def _bands(p, seeds):
    return sum(np.sin(p @ d * f + ph) * a for d, f, ph, a in seeds)


_RS = np.random.default_rng(7101)
_SEEDS = [[(M.A.nz(_RS.normal(size=3)), _RS.uniform(1.6, 4.2) * (1 + i), _RS.uniform(0, TAU), 1.0 / (1 + i))
           for i in range(4)] for _ in range(3)]


def decal_planet(phase):
    tilt = A.rx(math.radians(-24)) @ A.ry(math.radians(12))
    spin = A.rz(phase)

    def decal(part, P):
        q = part.sdf.local(P)
        q = q / np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-9)
        q = q @ tilt @ spin                                                       # the surface turns under the light
        land = _bands(q, _SEEDS[0])
        wild = _bands(q, _SEEDS[1])
        spot = _bands(q, _SEEDS[2])
        out = np.full(len(P), OID['red'])
        out[land > 0.55] = OID['coral']                                           # bright dust plains
        out[land < -0.65] = OID['soil']                                           # dark canyon country
        forest = (wild > 0.18) & (np.abs(q[:, 2]) < 0.72)
        out[forest] = OID['corala']                                               # the alien forest
        out[forest & (spot > 0.45)] = OID['coralb']
        ice = np.abs(q[:, 2]) > 0.8 + 0.08 * spot                                 # ice caps
        out[ice] = OID['white']
        out[(np.abs(q[:, 2]) > 0.6) & ~ice & (wild < -0.4)] = OID['icex2']        # snowfields round them
        return out
    return decal


def render_planet():
    C = M.cam(0.0, 0.0, 120.0)
    frames = [[P_('planet', A.Sphere(C, PLANET_R), 'red', 'planet', decal_planet(f / PLANET_FRAMES * TAU))]
              for f in range(PLANET_FRAMES)]
    box = M.sprite_box(frames, pad=2)
    strip = np.concatenate([M.sprite_rgba(M.render_sprite(fp, box)) for fp in frames], axis=1)
    cx, cy = M.project(*C)
    return strip, dict(file='planet.png', frames=PLANET_FRAMES, frame_size=[box[2], box[3]],
                       centre=[round(cx - box[0], 1), round(cy - box[1], 1)], radius=round(PLANET_R / M.S, 1))


# ---------------------------------------------------------------- the ship in space
def render_ship():
    keep = M.SHIP_SCALE
    M.SHIP_SCALE = 0.5                                     # far off: the same model, small
    try:
        C = M.cam(0.0, 0.0, 80.0)
        Rb = M.yaw_to(np.array([1.0, 0.55, 0.0])) @ A.ry(math.radians(-6))      # heading in, nose up a touch
        parts, _ = M.ship_parts(C, Rb, hot=False, lit=True, tag='orbit')
        box = M.sprite_box([parts], pad=2)
        rgba = M.sprite_rgba(M.render_sprite(parts, box))
        f = Rb[:, 0]
        engines = [M.project(*(C - f * 26.4 * M.SHIP_SCALE + Rb[:, 1] * s * 3.4 * M.SHIP_SCALE)) for s in (1, -1)]
    finally:
        M.SHIP_SCALE = keep
    return rgba, dict(file='ship_orbit.png', size=[box[2], box[3]],
                      engines=[[round(x - box[0], 1), round(y - box[1], 1)] for x, y in engines])


def main():
    os.makedirs(OUT, exist_ok=True)
    cockpit, cdata = render_cockpit()
    M.save_png(Image.fromarray(cockpit), os.path.join(OUT, 'cockpit.png'))
    planet, pdata = render_planet()
    M.save_png(Image.fromarray(planet), os.path.join(OUT, 'planet.png'))
    ship, sdata = render_ship()
    M.save_png(Image.fromarray(ship), os.path.join(OUT, 'ship_orbit.png'))
    data = dict(note='The opening cutscene\'s art, from tools/intro_gen.py. Positions are pixels in each image.',
                cockpit=cdata, planet=pdata, ship=sdata)
    M.save_text(json.dumps(data, indent=2), os.path.join(OUT, 'intro.json'))
    # a quick look at all three, as the game shows them (over the night void)
    prev = Image.new('RGBA', (PLATE[0] * 2, PLATE[1]), (11, 9, 21, 255))
    prev.alpha_composite(Image.fromarray(cockpit), (0, 0))
    pl = Image.fromarray(planet[:, :pdata['frame_size'][0]])
    prev.alpha_composite(pl, (PLATE[0] + 200 - pl.width // 2, PLATE[1] // 2 - pl.height // 2))
    prev.alpha_composite(Image.fromarray(ship), (PLATE[0] + 40, PLATE[1] - ship.shape[0] - 20))
    M.save_png(prev, os.path.join(OUT, 'preview.png'))
    print(f'intro art -> {OUT}: cockpit {PLATE}, planet {PLANET_FRAMES} x {pdata["frame_size"]}, ship {sdata["size"]}')


if __name__ == '__main__':
    main()
