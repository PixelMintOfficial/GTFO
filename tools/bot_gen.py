#!/usr/bin/env python3
"""The base's bot
===============

The little bot that sleeps in its charging cradle in storage (tools/interior_gen.py bakes the
cradle and says where it stands: base_interior.json -> bot). Woken with the multitool's fix job,
it greets the astronaut, releases maintenance access, gives ordered repair guidance and patrols
the floor to clean (scripts/story/). The nursery uses the same native body and sheet. Modelled with the same SDF primitives, ramps and
inside light as the rest of the base, so it looks drawn by the same hand.

Eight facings, like the astronaut (Player.DIRS: E SE S SW W NW N NE, screen compass): the camera
turns but the light stays put on screen, so a facing drawn once looks right from every side. The
game picks the row from the bot's world facing as the current view sees it.

    python tools/bot_gen.py              (make interior runs it after interior_gen.py)

Design versions (BOT_DESIGN), kept so the approved look can be compared or reworked:
  pod      (default) an egg with a dark visor and two eyes, side pods, an antenna that lights
  lantern  a rounded screen-head on a tapered body, stub arms, a cyan thruster ring
  orb      a sphere with a coral ring round its waist and one big lens eye

Animations, one row per facing (frames side by side), listed in bot.json:
  dormant  slumped on the cradle, eyes dark
  wake     eyes flicker on, it straightens up and rises off the cradle
  idle     a slow hover-bob, and a blink
  talk     the eyes pulse brighter, a little bob
  move     leaning into its flight, bobbing
  clean_start / clean / clean_end   deploy intake, lower and sweep, stow it again
`face` is where its eyes are, from the foot anchor, per facing: the game keeps them lit at night.
`nozzle_tips` exports the exact vacuum intake position per facing/absolute atlas frame.

Writes assets/maps/base_interior/bot/bot.png and bot.json.
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import astronaut_sprite_gen as A  # noqa: E402
import interior_gen as I  # noqa: E402
import mars_map_gen as M  # noqa: E402

OUT = os.path.join(I.OUT, 'bot')
DESIGN = os.environ.get('BOT_DESIGN', 'pod')
P_ = M.P_
OID = M.OID

# A pose: how high it floats off the floor (world units), how far it slumps forward (radians),
# what its eyes are (dark, lit, blinking shut, brighter while talking), and its antenna tip.
DORMANT = dict(z=1.6, slump=0.42, eyes='darkwin', tip='deadbulb', blink=False)
AWAKE = dict(z=3.0, slump=0.0, eyes='screen', tip='beacon', blink=False, vacuum=0., sweep=0.)


def pose(**kw):
    p = dict(AWAKE)
    p.update(kw)
    return p


def lerp_pose(a, b, t):
    """Between two poses: height and slump eased; the lights switch at the end."""
    e = t * t * (3 - 2 * t)
    out = dict(b if t >= 1 else a)
    out['z'] = a['z'] + (b['z'] - a['z']) * e
    out['slump'] = a['slump'] + (b['slump'] - a['slump']) * e
    return out


def face_decal(base, eyes, visor=(3.2, 1.6, 0.6), eye_at=((-1.3, 0.7), (1.3, 0.7)), band=None, blink=False):
    """A white shell with a dark visor on its front (-y) and two eyes in it; a coral band."""
    def decal(part, P):
        q = part.sdf.local(P)
        out = np.full(len(P), OID[base])
        if band is not None:
            out[np.abs(q[:, 2] - band[0]) < band[1]] = OID['coral']
        front = q[:, 1] < -0.5
        vis = front & (np.abs(q[:, 0]) < visor[0]) & (np.abs(q[:, 2] - visor[2]) < visor[1])
        out[vis] = OID['dark']
        for ex, ez in eye_at:
            if blink:                                    # shut: a thin lit line
                out[vis & (np.abs(q[:, 0] - ex) < 0.8) & (np.abs(q[:, 2] - ez) < 0.2)] = OID[eyes]
            else:
                out[vis & (np.hypot(q[:, 0] - ex, q[:, 2] - ez) < 0.75)] = OID[eyes]
        return out
    return decal


# ------------------------------------------------------------------ designs (built at the foot, facing -y)
def pod(p):
    """A: an egg-shaped pod with a visor, little side pods and an antenna."""
    tilt = A.rx(p['slump'])
    c = np.array([0, 0, p['z'] + 5.6])
    parts = [P_('body', A.Ellipsoid(c, (4.8, 4.4, 5.8), tilt), 'white', 'bot',
                face_decal('white', p['eyes'], visor=(3.4, 1.5, 1.6), eye_at=((-1.4, 1.6), (1.4, 1.6)), band=(-2.4, 0.45),
                           blink=p['blink']))]
    for s in (-1, 1):
        parts.append(P_('ear', A.Ellipsoid(c + tilt @ np.array([s * 4.7, 0, 0.4]), (1.0, 1.6, 2.2), tilt), 'steel', 'bot'))
    top = c + tilt @ np.array([0, 0.6, 5.6])
    tip = top + tilt @ np.array([0.0, 0.8, 2.4])
    parts.append(P_('ant', A.RoundCone(top, tip, 0.35, 0.25), 'steel', 'bot'))
    parts.append(P_('tip', A.Sphere(tip, 0.7), p['tip'], 'bot'))
    return parts, c + tilt @ np.array([0, -4.4, 1.6])


def lantern(p):
    """B: a rounded screen-head on a short tapered body, with stub arms."""
    base = np.array([0, 0, p['z'] - 0.4])
    k = p['slump'] / 0.5
    tilt = A.rx(p['slump'])
    head_c = base + np.array([0, -1.6 * k, 8.2 - 1.4 * k])
    parts = [P_('body', A.RoundCone(base + np.array([0, 0, 0.6]), base + np.array([0, 0, 4.6]), 2.6, 3.6), 'white', 'bot', decal_body),
             P_('head', A.RoundBox(head_c, (4.2, 3.6, 3.2), 1.5, tilt), 'white', 'bot',
                face_decal('white', p['eyes'], visor=(3.2, 2.0, 0.2), eye_at=((-1.4, 0.4), (1.4, 0.4)), band=(-2.6, 0.4),
                           blink=p['blink']))]
    for s in (-1, 1):
        sh = base + np.array([s * 3.6, 0, 3.8])
        hand = sh + np.array([s * (1.6 - 0.8 * k), -0.6 + 0.4 * k, -2.4 - 0.6 * k])
        parts.append(P_('arm', A.RoundCone(sh, hand, 0.9, 0.7), 'steel', 'bot'))
    if p['eyes'] != 'darkwin':
        parts.append(P_('thrust', A.Torus(base + np.array([0, 0, 0.1]), 2.2, 0.5), 'ledcyan', 'bot'))
    return parts, head_c + tilt @ np.array([0, -3.6, 0.4])


def decal_body(part, P):
    t = part.sdf.local(P)
    out = np.full(len(P), OID['white'])
    out[(t > 0.55) & (t < 0.7)] = OID['coral']
    return out


def orb(p):
    """C: a round orb with a coral ring round its waist and one big lens eye."""
    c = np.array([0, 0, p['z'] + 5.0])
    look = A.rx(p['slump'] * 1.3)
    parts = [P_('body', A.Sphere(c, 5.0), 'white', 'bot', decal_orb),
             P_('ring', A.Torus(c + np.array([0, 0, -0.4]), 5.2, 0.7, A.rx(0.12 + p['slump'] * 0.4)), 'coral', 'bot')]
    lens = c + look @ np.array([0, -4.3, 0.9])
    parts.append(P_('lens', A.Sphere(lens, 1.9), 'dark', 'bot', decal_lens(p['eyes'], p['blink'])))
    for s in (-1, 1):
        parts.append(P_('fin', A.RoundBox(c + np.array([s * 5.4, 0.6, 1.2]), (0.5, 1.6, 2.2), 0.4, A.ry(s * 0.35)), 'steel', 'bot'))
    return parts, lens + look @ np.array([0, -1.6, 0])


def decal_orb(part, P):
    q = part.sdf.local(P)
    out = np.full(len(P), OID['white'])
    out[(q[:, 2] > 3.6) & (np.abs(q[:, 0]) < 0.5)] = OID['steel']          # a seam over the top
    return out


def decal_lens(ramp, blink):
    def decal(part, P):
        q = part.sdf.local(P)
        out = np.full(len(P), OID['dark'])
        iris = (q[:, 1] < -1.1) & ((np.abs(q[:, 2]) < 0.25) if blink else (np.hypot(q[:, 0], q[:, 2]) < 0.9))
        out[iris & ((np.abs(q[:, 0]) < 0.9) if blink else iris)] = OID[ramp]
        return out
    return decal


DESIGNS = dict(pod=pod, lantern=lantern, orb=orb)


# ------------------------------------------------------------------ animations
def animations():
    """Every frame's pose, in order, and where each animation starts: {name: [first, count, fps, loop]}."""
    frames, anims = [], {}

    def add(name, poses, fps, loop):
        anims[name] = [len(frames), len(poses), fps, loop]
        frames.extend(poses)

    add('dormant', [DORMANT], 1, True)
    wake = [lerp_pose(DORMANT, AWAKE, i / 9) for i in range(10)]
    for i in (2, 4, 5):                                 # the eyes flicker on before it straightens
        wake[i] = dict(wake[i], eyes='screen' if i != 4 else 'darkwin', tip='beacon')
    add('wake', wake, 10, False)
    add('idle', [pose(z=AWAKE['z'] + 0.6 * math.sin(i / 8 * math.tau), blink=(i == 5)) for i in range(8)], 6, True)
    add('talk', [pose(z=AWAKE['z'] + 0.3 * math.sin(i / 4 * math.tau), eyes='ledcyan' if i % 2 else 'screen') for i in range(4)],
        8, True)
    add('move', [pose(z=AWAKE['z'] + 0.4 * math.sin(i / 4 * math.tau), slump=0.16) for i in range(4)], 8, True)
    add('clean_start', [pose(z=3.-1.3*i/3, slump=.3*i/3, vacuum=i/3) for i in range(4)], 10, False)
    add('clean', [pose(z=1.7 + .15 * math.sin(i / 8 * math.tau), slump=.3,
                       vacuum=1., sweep=math.sin(i / 8 * math.tau)) for i in range(8)], 8, True)
    add('clean_end', [pose(z=1.7+1.3*i/3, slump=.3*(1.-i/3), vacuum=1.-i/3) for i in range(4)], 10, False)
    return frames, anims


FACINGS = ['E', 'SE', 'S', 'SW', 'W', 'NW', 'N', 'NE']   # Player.DIRS: facing i looks along (cos 45i, -sin 45i)


class Yaw:
    """A model built facing -y, turned about the foot to face along another direction."""

    def __init__(self, inner, a):
        self.inner, self.a = inner, a
        c, s = math.cos(a), math.sin(a)
        self.R = np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])

    def back(self, P):
        return P @ self.R                                 # world -> the model's own frame

    def __call__(self, P):
        return self.inner(self.back(P))

    def local(self, P):
        return self.inner.local(self.back(P))

    def __getattr__(self, k):
        if k in ('inner', 'a', 'R'):
            raise AttributeError(k)
        return getattr(self.inner, k)


def part_bound(sdf):
    if isinstance(sdf, Yaw):
        c, r = part_bound(sdf.inner)
        return sdf.R @ c, r
    return _orig_part_bound(sdf)


_orig_part_bound = M.part_bound                          # as interior_gen extends it for its walls
M.part_bound = part_bound


def facing_yaw(i):
    """The turn that points the model's front (-y, 'S') along facing i."""
    return math.radians(90.0 - 45.0 * i)


def faced(parts, i):
    a = facing_yaw(i)
    return [A.Part(p.name, Yaw(p.sdf, a), p.ramp, p.group, blend=p.blend, decal=p.decal, emissive=p.emissive) for p in parts]


def face_offset(p, i):
    """The eyes (a model point built at the foot) on screen for facing i, from the foot."""
    a = facing_yaw(i)
    q = np.array([p[0] * math.cos(a) - p[1] * math.sin(a), p[0] * math.sin(a) + p[1] * math.cos(a), p[2]])
    d = np.array(M.project(*q)) - np.array(M.project(0.0, 0.0, 0.0))
    return [round(float(v), 1) for v in d]


def main():
    np.seterr(all='ignore')
    os.makedirs(OUT, exist_ok=True)
    M.VIEW, M.SFX = 0, ''
    M.SUN = I.SUN_IN
    I.set_frame()
    make = DESIGNS[DESIGN]
    poses, anims = animations()
    models = []
    for pose_data in poses:
        parts, face = make(pose_data)
        amount = pose_data.get('vacuum', 0.)
        tip = np.array([pose_data.get('sweep', 0.) * 1.5, -4.-3.*amount, .6])
        if amount > 0.:
            shoulder = np.array([0., -3.2, 4.1])
            elbow = np.array([tip[0]*.5, -4.8, 2.3])
            parts += [P_('vacuum_arm', A.RoundCone(shoulder, elbow, .4, .3), 'steel', 'bot'),
                      P_('vacuum_hose', A.RoundCone(elbow, tip, .3, .4), 'dark', 'bot'),
                      P_('vacuum_head', A.RoundBox(tip, (2.6, .9, .45), .25), 'coral', 'bot'),
                      P_('vacuum_intake', A.RoundBox(tip + [0., -.7, -.1], (2., .3, .2), .1), 'dark', 'bot')]
        models.append((parts, face))
    face = models[anims['idle'][0]][1]                   # the eyes, upright
    rows = [[faced(parts, i) for parts, _ in models] for i in range(len(FACINGS))]
    box = M.sprite_box([fp for row in rows for fp in row], pad=3)
    sheet = np.concatenate([np.concatenate([M.sprite_rgba(M.render_sprite(fp, box)) for fp in row], axis=1)
                            for row in rows], axis=0)
    Image.fromarray(sheet).save(os.path.join(OUT, 'bot.png'))
    data = dict(design=DESIGN, file='bot.png', facings=FACINGS, frames=len(poses), frame_size=[box[2], box[3]],
                anchor=[round(M.AX - box[0], 1), round(M.AY - box[1], 1)],
                face=[face_offset(face, i) for i in range(len(FACINGS))], animations=anims,
                nozzle_tips=[[face_offset(np.array([p.get('sweep', 0.)*1.5, -4.-3.*p.get('vacuum',0.), .6]), i)
                              for p in poses] for i in range(len(FACINGS))],
                note='The base\'s bot (sleeps at base_interior.json -> bot.world). One row per facing (Player.DIRS order, '
                     'screen compass: right for every view), one column per frame; anchor = its foot in a frame; face = '
                     'its eyes from the foot, map px, per facing. animations: [first frame, count, fps, loop].')
    with open(os.path.join(OUT, 'bot.json'), 'w') as fh:
        json.dump(data, fh, indent=1)
    print(f'bot ({DESIGN}): {len(poses)} frames x {len(FACINGS)} facings -> {OUT}')


if __name__ == '__main__':
    main()
