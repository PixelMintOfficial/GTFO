#!/usr/bin/env python3
"""Generate the comms room in broken, repaired standby and online states, in four views.

The three states share the nursery's room renderer, collision grid and airlock.
COMMS_OUT redirects output and MAP_VIEWS selects camera views.
"""

import json
import os
from pathlib import Path

import numpy as np

import nursery_gen as N

M, I, A, P = N.M, N.I, N.A, N.P
OUT = Path(os.environ.get('COMMS_OUT', N.ROOT / 'assets/maps/comms_interior'))
CONSOLE_Y = 44.
SCREEN_Y = CONSOLE_Y - 4.2
SCREEN_Z = 22.
STATES = ('broken', 'standby', 'online')


def lettering(text):
    pixels = np.zeros((7, M.text_width(text) + 2, 3), np.uint8)
    M.draw_text(pixels, 1, 1, text, (255, 255, 255), shadow=(0, 0, 0))
    return pixels[:, :, 0] > 0


EARTH_LINK = lettering('EARTH LINK')
LINK_READY = lettering('LINK READY')


def screen_material(state):
    def decal(part, points):
        q = part.sdf.local(points)
        color = np.full(len(points), M.OID['darkwin'])
        face = q[:, 1] < -.55
        u, v = q[:, 0], q[:, 2]
        if state == 'online':
            for pixels, top in ((EARTH_LINK, 7.4), (LINK_READY, -2.7)):
                x = np.floor(u / .8 + pixels.shape[1] / 2.).astype(int)
                y = np.floor((top - v) / .8).astype(int)
                ix = np.flatnonzero(face & (x >= 0) & (x < pixels.shape[1]) & (y >= 0) & (y < 7))
                color[ix[pixels[y[ix], x[ix]]]] = M.OID['ledcyan']
            planets = ((u + 12.) ** 2 + v ** 2 < 2.1 ** 2) | ((u - 12.) ** 2 + v ** 2 < 1.45 ** 2)
            signal = (abs(u) < 9.) & (abs(v) < .3) & (np.mod(u, 2.4) < .8)
            color[face & (planets | signal)] = M.OID['screen']
        elif state == 'broken':
            for start, end in (((18., 6.), (12., 0.)), ((12., 0.), (13., -6.)),
                               ((12., 0.), (4., -3.)), ((18., 6.), (16., 8.))):
                a, b = np.asarray(start), np.asarray(end)
                p = q[:, [0, 2]] - a
                ab = b - a
                t = np.clip((p @ ab) / (ab @ ab), 0., 1.)
                color[face & (np.linalg.norm(p - t[:, None] * ab, axis=1) < .27)] = M.OID['metal']
        return color
    return decal


def equipment(state):
    """A recessed monitor, a floor-standing desk, flanking racks and dish conduits."""
    at, box, disc, rod = N.at, N.box, N.disc, N.rod
    lit = state == 'online'
    parts = [
        box(at(0., CONSOLE_Y + 1., 16.), (24., 5., 16.), 'white', 'console', 2.3),
        box(at(0., SCREEN_Y, SCREEN_Z), (21., .9, 9.4), 'pack', 'bezel', 1.6),
        box(at(0., SCREEN_Y - .95, SCREEN_Z), (19.6, .7, 8.1), 'darkwin', 'screen', .55,
            decal=screen_material(state)),
        box(at(0., CONSOLE_Y - 7., 5.5), (23., 5.4, 5.5), 'white', 'desk', 1.3),
        box(at(0., CONSOLE_Y - 8., 10.7), (17., 3.8, 1.8), 'pack', 'keys', .65),
        disc(at(0., CONSOLE_Y + 5., 34.), 9.5, 3.7, 'white', 'bearing'),
        disc(at(0., CONSOLE_Y + 5., 37.2), 9.7, 1.25, 'pack', 'bearing'),
        disc(at(0., CONSOLE_Y + 5., 40.), 7.6, 2., 'white', 'bearing'),
    ]
    for x in (-12., -8., -4., 0., 5., 10.):
        ramp = 'ledcyan' if lit else 'metal' if state == 'standby' else 'dark'
        parts.append(box(at(x, CONSOLE_Y - 9., 12.3), (1.25, 1., .35), ramp, 'keys', .2))
    for side in (-1, 1):
        x = side * 32.
        group = f'rack{side}'
        parts += [
            box(at(x, 37., 11.), (6.8, 4.8, 11.), 'white', group, 1.2),
            box(at(x, 31.9, 12.), (5., .8, 8.), 'pack', group, .55),
            box(at(x, 31.2, 4.6), (4.6, .55, 1.6), 'metal', group, .3),
        ]
        for tier in (9., 14., 18.):
            for dx in (-2.3, 0., 2.3):
                parts.append(box(at(x + dx, 31.1, tier), (.65, .34, 1.1),
                                 'ledcyan' if lit else 'darkwin', group, .18))
        for lane in (0., 1.6):
            anchors = [at(side * 8., 46., 36. - lane), at(side * 20., 46., 36. - lane),
                       at(side * 27., 45., 33. - lane), at(side * 31.5, 41., 26. - lane),
                       at(side * 31.5, 39., 21.8)]
            for start, end in zip(anchors, anchors[1:]):
                parts.append(rod(start, end, .53, 'pack' if lane else 'metal', f'conduit{side}'))
    if state == 'broken':
        parts += [
            box(at(18., 32.5, 1.), (4., 2., .6), 'metal', 'damaged_panel', .32, yaw=.23),
            rod(at(19., 33., 8.), at(21., 32., 4.), .45, 'dark', 'cables'),
            rod(at(21., 32., 4.), at(22., 31., 1.3), .43, 'coral', 'cables'),
        ]
    return parts


def build():
    N.OUT = OUT
    N.LAYOUT_SCALE = .81
    N.RADIUS = 64.
    N.ENTRY_RADIUS = N.RADIUS - 3.
    door_id = M.primary_comms_airlock()
    _, normal = M.airlock_ends()[door_id]
    N.ENTRIES = [(door_id, normal)]
    N.SPAWN = N.C[:2] + normal * (N.ENTRY_RADIUS - 34.)
    N.setup_room()
    I.WALL_H = 34.
    I.EMERG = (28.8, 30.2)
    I.WIN = (35., 36.)  # the antenna pedestal is an opaque shell
    M.W, M.H, M.AX = 384, 236, 192.
    M.AY = 150. + M.KY * N.C[1] * M.PX
    (OUT / 'anim').mkdir(parents=True, exist_ok=True)
    (OUT / 'preview').mkdir(exist_ok=True)

    stand = N.at(0., 19.)[:2]
    repair = dict(world=N.at(0., SCREEN_Y - 1.3)[:2].tolist(), scan_height=SCREEN_Z)
    metadata = dict(console_stand=stand.tolist(), console_repair=repair)
    walk_file = 'comms_walk.png'
    # Scan materials and desk damage change visually; walkability stays stable on repair.
    walk = N.world_grid(equipment('broken'), walk_file, furniture_approaches=[stand])
    for x, y in ((0., CONSOLE_Y), (0., CONSOLE_Y - 10.), (-32., 37.), (32., 37.)):
        u, v = (int(coord) for coord in M.to_grid(x, N.C[1] + y))
        assert not walk[u, v], 'Communications furniture must block walking and jumps'
    for x, y, rx, ry in ((0., CONSOLE_Y - 4., 27., 13.), (-32., 37., 8., 7.), (32., 37., 8., 7.)):
        N.foot(N.at(x, y), rx, ry)
    M.save_text(json.dumps(dict(sprites={}, objects=[], lamps=[])), str(OUT / 'comms_props.json'))
    for state in STATES:
        name = 'comms' if state == 'broken' else f'comms_{state}'
        parts = equipment(state)
        for view in M.VIEWS:
            N.render_view(view, parts, name, walk_file, extra=metadata, room_name='comms')


if __name__ == '__main__':
    np.seterr(all='ignore')
    build()
