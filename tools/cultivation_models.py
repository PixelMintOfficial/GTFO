#!/usr/bin/env python3
"""Canonical cultivation models for GTFO's native art pipeline.

Owns the approved Emberpod food crop, Dewpod water crop, Moonwell night flower,
Cindercoil wild seed plant and modest nursery damage. Models are built around
canonical world points and use the shared primitives, ramps and ray marcher.
Render/export ownership lives in cultivation_gen.py and nursery_gen.py; importing
this module writes nothing. Wild plants are scaled to roughly 22 world units
(the astronaut's height). Regenerate with make cultivation / make nursery.
"""
import copy
import math
import numpy as np
import mars_map_gen as M
import interior_gen as I
import astronaut_sprite_gen as A
P = M.P_
UP = np.array([0., 0., 1.])
ACTIVE = 'a'

def rod(a, b, r1, r2, ramp, group, name='stem'):
    return P(name, A.RoundCone(a, b, r1, r2), ramp, group)


def leaf(c, length, width, angle, group, ramp='leafa', tilt=-.3):
    direction = np.array([math.cos(angle), math.sin(angle), 0.])
    centre = c + direction * length * .48 + UP * length * .18
    return P('leaf', A.Ellipsoid(centre, (length * .62, width, length * .12),
                                A.rz(angle) @ A.ry(tilt)), ramp, group)


def ember_fruit(c, size, group='ember_fruit', opened=False):
    """A plump three-lobed orange pod; a pointed cream seam distinguishes it."""
    parts = [P('fruit_body', A.Ellipsoid(c, (size * .91, size * .83, size * .75)), 'coral', group)]
    for j in range(3):
        a = j * math.tau / 3 + .2
        offset = np.array([math.cos(a) * .43, math.sin(a) * .43, 0.]) * size
        parts.append(P('fruit_lobe', A.Ellipsoid(c + offset, (size * .6, size * .57, size * .76)),
                       'mustard' if j == 2 else 'coral', group))
    parts += [rod(c + UP * size * .65, c + UP * size * 1.05, size * .12, size * .07, 'wood', group),
              P('cream_seam', A.Ellipsoid(c + np.array([-.22, -.8, .2]) * size,
                (size * .09, size * .07, size * .45), A.ry(-.2)), 'mustard', group)]
    if opened:
        cut = A.RoundBox(c + np.array([0., -size, 0.]), (size * 2., size, size * 2.), .02)
        parts = [P(p.name, I.Cut(p.sdf, cut), p.ramp, p.group) for p in parts]
        parts += [P('edible_flesh', A.Ellipsoid(c + np.array([0., -.02, 0.]),
                      (size * .75, .1, size * .59)), 'mustard', group + '_flesh')]
        for j in range(3):
            parts.append(P('food_seed', A.Ellipsoid(c + np.array([(j - 1) * .35, -.18, .1]) * size,
                            (size * .13, size * .07, size * .19), A.ry((j - 1) * .3)), 'sack', group + '_seed'))
    return parts


def emberplant(c, size=8., seed=1, group='ember', stage='ripe'):
    parts = []
    phase = (seed % 13) * .17
    if stage == 'dead':
        for j in range(5):
            a = phase + j * math.tau / 5
            d = np.array([math.cos(a), math.sin(a), 0.])
            end = c + d * size * .62 + UP * size * .1
            parts += [rod(c, end, .25, .12, 'wood', group),
                      leaf(end - d * size * .16, size * .35, size * .07, a, group, 'sack', .48)]
        return parts
    scale = .44 if stage == 'sprout' else 1.
    for j in range(5 if stage != 'sprout' else 3):
        a = phase + j * math.tau / 5
        parts.append(leaf(c, size * .83 * scale, size * .21 * scale, a, group,
                          'leafa' if j % 2 else 'leaf2', -.27))
    if stage == 'ripe':
        for j, a in enumerate((-.65, 1.15, 3.25)):
            d = np.array([math.cos(a), math.sin(a), 0.])
            fruit = c + d * size * .38 + UP * size * .37
            parts += ember_fruit(fruit, size * .29, group + f'_pod{j}')
    return parts


def dew_fruit(c, size, group='dew_fruit', opened=False):
    """A bottom-heavy blue fluid sac with a narrow neck, fins and pale glint."""
    parts = [P('fluid_sac', A.Ellipsoid(c, (size * .68, size * .62, size)), 'orb', group),
             P('tapered_neck', A.Ellipsoid(c + UP * size * .73,
               (size * .36, size * .35, size * .70)), 'cap3', group),
             P('fluid_highlight', A.Ellipsoid(c + np.array([-.28, -.48, .30]) * size,
               (size * .12, size * .08, size * .35), A.ry(-.2)), 'windowglass', group),
             P('fluid_highlight', A.Sphere(c + np.array([-.34, -.47, -.13]) * size,
               size * .10), 'glassedge', group)]
    for j in range(3):
        a = j * math.tau / 3
        p = c + UP * size * 1.18
        parts.append(leaf(p, size * .68, size * .18, a, group, 'coralb', -.55))
    if opened:
        cut = A.RoundBox(c + np.array([0., -size, 0.]), (size * 2., size, size * 2.), .02)
        parts = [P(p.name, I.Cut(p.sdf, cut), p.ramp, p.group) for p in parts]
        parts += [P('drinkable_interior', A.Ellipsoid(c + np.array([0., -.08, 0.]),
                       (size * .53, .12, size * .81)), 'liquid', group + '_interior')]
    return parts


def dewplant(c, size=6., seed=1, group='dew', stage='ripe'):
    if stage == 'dead':
        return emberplant(c, size, seed, group, 'dead')
    parts = []
    phase = (seed % 7) * .21
    height = size * (.48 if stage == 'sprout' else 1.15)
    top = c + np.array([.12 * size, 0., height])
    parts += [rod(c, top, .34, .2, 'coralb', group)]
    for j in range(3):
        a = phase + j * math.tau / 3
        parts.append(leaf(c + UP * size * .18, size * (.42 if stage == 'sprout' else .77),
                          size * .12, a, group, 'corala', -.72))
        if stage == 'ripe':
            d = np.array([math.cos(a), math.sin(a), 0.])
            neck = top + d * size * .48
            fruit = neck - UP * size * .60
            parts += [rod(top, neck, .23, .15, 'coralb', group)]
            parts += dew_fruit(fruit, size * .32, group + f'_fruit{j}')
    return parts


def seeds(c, kind, group='seeds', glow=False):
    parts = []
    for j, (x, y, z) in enumerate(((-1.8, -.5, .9), (1.4, -.5, .7), (0., 1.3, .8))):
        p = c + np.array([x, y, z])
        ramp = 'mustard' if kind == 'food' else ('ledcyan' if glow else 'orb')
        parts.append(P('seed', A.Ellipsoid(p, (1.05, .75, 1.3), A.ry((j - 1) * .3)), ramp, group))
        if kind == 'water':
            parts.append(P('seed_seam', A.Ellipsoid(p + np.array([-.3, -.6, .2]), (.12, .12, .65)),
                           'windowglass', group))
    return parts


def moonwell(c, opening=0.):
    """Closed purple shell becomes a wide pale flower around luminous seed pearls."""
    parts = []
    for j in range(5):
        a = j * math.tau / 5 + .15
        parts.append(leaf(c, 11., 2.0, a, f'basal{j}', 'corala', -.5))
    elbow = c + np.array([-1.5, .6, 10.])
    flower = c + np.array([0., 0., 22.])
    parts += [rod(c, elbow, 1.4, 1.1, 'stem', 'moon_stem'),
              rod(elbow, flower, 1.1, .8, 'coralb', 'moon_stem'),
              P('seed_cup', A.Ellipsoid(flower + UP * 1.3, (5.5, 5.5, 2.4)), 'coralb', 'cup')]
    theta = -.35 + opening * 1.75
    for j in range(7):
        angle = j * math.tau / 7 + .12
        d = np.array([math.cos(angle), math.sin(angle), 0.])
        tangent = np.array([-math.sin(angle), math.cos(angle), 0.])
        axis = d * math.sin(theta) + UP * math.cos(theta)
        normal = -d * math.cos(theta) + UP * math.sin(theta)
        rotation = np.stack((tangent, normal, axis), axis=1)
        centre = flower + d * (6.8 + opening * 2.5) + UP * (7. - opening * 4.)
        group = f'petal{j}'
        parts += [P('purple_husk', A.Ellipsoid(centre, (4.2, 2.4, 9.2), rotation), 'cap', group),
                  P('pale_inner_petal', A.Ellipsoid(centre + normal * 2.0,
                    (3.55, .58, 8.5), rotation), 'puff', group)]
        if opening > .24:
            a = centre - axis * 5.8 + normal * 2.6
            b = centre + axis * 5.5 + normal * 2.6
            parts.append(rod(a, b, .23, .13, 'ledcyan', group, 'luminous_vein'))
    if opening < .45:
        cap_size = max(.1, 1. - opening / .45)
        parts.append(P('closed_tip', A.Ellipsoid(flower + UP * (15. * cap_size + 2.),
                       (3.8 * cap_size, 3.8 * cap_size, 2. * cap_size)), 'cap', 'tip'))
    # The seed bodies exist within the closed shell, genuinely occluded during daytime.
    for j in range(6):
        a = j * math.tau / 6
        p = flower + np.array([math.cos(a) * 2.4, math.sin(a) * 2.4, 3.4])
        parts.append(P('viable_seed', A.Ellipsoid(p, (1., .9, 1.8), A.ry(.2)),
                       'ledcyan' if opening > .5 else 'orb', 'moonwell_seeds'))
    return parts


def seed_case(c, group, state='ripe', size=1.):
    """A rigid narrow husk with long ribs and pointed tips; no fleshy outer fruit."""
    parts = []
    outer = A.Ellipsoid(c, np.array([2.45, 2.2, 5.2]) * size)
    inner = A.Ellipsoid(c + np.array([0., -.15, 0.]) * size, np.array([1.65, 1.65, 4.45]) * size)
    shell = I.Cut(outer, inner)
    if state != 'sealed':
        # A thin natural split exposes seeds while the dry protective shell remains.
        split = A.RoundBox(c + np.array([0., -2.1, .1]) * size,
                           np.array([1.05, 2.6, 4.45]) * size, .06)
        shell = I.Cut(shell, split)
    parts.append(P('dry_seed_husk', shell, 'wood', group))
    for j in range(5):
        angle = j * math.tau / 5 + .26
        d = np.array([math.cos(angle), math.sin(angle), 0.])
        start = c + (d * 1.25 - UP * 4.6) * size
        middle = c + d * 2.5 * size
        end = c + (d * .58 + UP * 5.7) * size
        if state != 'sealed' and d[1] < -.65:
            continue
        parts += [rod(start, middle, .3 * size, .28 * size, 'stem', group, 'husk_rib'),
                  rod(middle, end, .28 * size, .08 * size, 'stem', group, 'pointed_rib')]
    # Papery side barbs and a forked tip, rather than a smooth bulb or berry shape.
    for sign in (-1, 1):
        start = c + np.array([sign * 1.6, 0., .8]) * size
        end = start + np.array([sign * 2.0, .4, 2.2]) * size
        parts.append(rod(start, end, .35 * size, .03 * size, 'deadbulb', group, 'dry_bract'))
    if state == 'ripe':
        for j in range(4):
            q = c + np.array([(-.38 if j % 2 else .38), -1.65, -1.9 + j * 1.15]) * size
            parts.append(P('ember_seed', A.Ellipsoid(q, np.array([.58, .44, .72]) * size,
                           A.ry((j % 2 - .5) * .6)), 'mustard', group + '_seeds'))
    return parts


def cindercoil(c, state='ripe'):
    """Low root whorl and coiling tough fronds around three tall, dry seed stalks."""
    parts = []
    # The existing alien fern supplies the characteristic coiled silhouette.
    for p in M.curl_fern(c, 41):
        ramp = 'deadbulb' if p.name == 'tip' else 'stem'
        parts.append(P(p.name, p.sdf, ramp, 'wild_' + p.group))
    for j in range(5):
        angle = j * math.tau / 5 + .3
        d = np.array([math.cos(angle), math.sin(angle), 0.])
        root = c + d * 2.2
        elbow = c + d * 7. + UP * 2.3
        tip = c + d * 13. + UP * 6.
        parts += [rod(root, elbow, .8, .5, 'stem', f'root{j}'),
                  rod(elbow, tip, .5, .03, 'stem', f'root{j}')]
    sites = [(-8., 2., 22.), (3., 5., 31.), (10., -1., 24.)]
    for j, (x, y, z) in enumerate(sites):
        end = c + np.array([x, y, z])
        control = c + np.array([x * .45, y * .6, z * .54])
        parts += [rod(c + np.array([j - 1., 0., 0.]), control, .95, .60, 'stem', f'stalk{j}'),
                  rod(control, end - UP * 4., .60, .36, 'wood', f'stalk{j}')]
        # Small hooked spurs read as tough scrub in the wilderness.
        for k in range(2):
            a = c + (control - c) * (.55 + k * .25)
            b = a + np.array([(-1 if j % 2 else 1) * 3.4, -.8, 2.3])
            parts.append(rod(a, b, .38, .03, 'deadbulb', f'spur{j}_{k}'))
        parts += seed_case(end, f'case{j}', state, 1. if j != 1 else 1.14)
    return parts


def clone_part(p, sdf=None, ramp=None, group=None):
    return P(p.name, p.sdf if sdf is None else sdf,
             p.ramp if ramp is None else ramp,
             p.group if group is None else group, p.decal)


def pose_shape(sdf, pivot, rotation, delta):
    """Pose existing primitives, keeping native bounds and local decals usable."""
    point = lambda q: pivot + rotation @ (np.asarray(q) - pivot) + delta
    if isinstance(sdf, I.Cut):
        return I.Cut(pose_shape(sdf.a, pivot, rotation, delta),
                     pose_shape(sdf.b, pivot, rotation, delta))
    if isinstance(sdf, I.Either):
        return I.Either(pose_shape(sdf.a, pivot, rotation, delta),
                        pose_shape(sdf.b, pivot, rotation, delta))
    if isinstance(sdf, M.Scaled):
        # The specimen's native scale wrapper is inside the room-scale wrapper.
        inner = pose_shape(sdf.inner, sdf.C, rotation, np.zeros(3))
        return M.Scaled(inner, point(sdf.C), sdf.s)
    if isinstance(sdf, A.RoundCone):
        return A.RoundCone(point(sdf.a), point(sdf.b), sdf.r1, sdf.r2)
    result = copy.copy(sdf)
    if not hasattr(sdf, 'c'):
        raise TypeError(type(sdf))
    result.c = point(sdf.c)
    if hasattr(sdf, 'R'):
        result.R = rotation @ sdf.R
    return result


def pose(p, pivot, rotation, delta=(0., 0., 0.)):
    return clone_part(p, pose_shape(p.sdf, np.asarray(pivot), rotation, np.asarray(delta)))


def rack_damage_pose(p, centre):
    """One loose middle shelf and its plants sag from the surviving left bracket."""
    return pose(p, np.asarray(centre) + np.array([-22., -11., 30.]), A.ry(.24))


def dead_rosette(c, size, seed, group, flower=False):
    """Actual wilted geometry: drooping narrow leaves, exposed stems, no flowers."""
    rs = np.random.default_rng(seed)
    parts = []
    phase = rs.uniform(0, math.tau)
    leaf_ramp = 'sack' if ACTIVE == 'a' else ('stem' if ACTIVE == 'b' else 'wood')
    count = 5 if ACTIVE == 'a' else 4
    for j in range(count):
        angle = phase + j * math.tau / count
        direction = np.array([math.cos(angle), math.sin(angle), 0.])
        joint = c + direction * size * .25 + UP * size * .20
        tip = c + direction * size * .76 - UP * size * .20
        parts.append(P('dry_stem', A.RoundCone(c, joint, size * .035, size * .023),
                       'wood', group))
        parts.append(P('wilted_leaf', A.Ellipsoid((joint + tip) / 2,
                       (size * .38, size * .10, size * .045),
                       A.rz(angle) @ A.ry(.48)), leaf_ramp, group))
    if flower:
        bend = c + np.array([size * .18, 0., size * .65])
        tip = bend + np.array([size * .24, 0., -size * .22])
        parts += [P('dry_flower_stem', A.RoundCone(c, bend, .23, .14), 'wood', group),
                  P('dry_flower_stem', A.RoundCone(bend, tip, .14, .1), 'wood', group),
                  P('empty_seedhead', A.Ellipsoid(tip, (size * .10, size * .10, size * .08)),
                    'soil', group)]
    return parts


def dead_specimen(c, scale, group):
    """A bare branching version of the same central specimen, with dead leaves."""
    height = 33. * scale
    trunk_top = c + np.array([-.8, 0., height * .77])
    parts = [P('bare_trunk', A.RoundCone(c, trunk_top, 2.7 * scale, .95 * scale),
               'wood', group)]
    for j in range(5):
        angle = j * math.tau / 5 + .3
        start = c + UP * height * (.36 + (j % 3) * .13)
        elbow = start + np.array([math.cos(angle) * 6., math.sin(angle) * 6., 4.]) * scale
        end = elbow + np.array([math.cos(angle) * 3., math.sin(angle) * 3., -1.]) * scale
        parts += [P('bare_branch', A.RoundCone(start, elbow, .75 * scale, .40 * scale), 'wood', group),
                  P('snapped_twig', A.RoundCone(elbow, end, .4 * scale, .15 * scale), 'wood', group)]
        if j % 2 == 0:
            parts += dead_rosette(end, 4.2 * scale, 4100 + j, group + f'_dry{j}')
    return parts


def wire_bundle(c, seed, group):
    rs = np.random.default_rng(seed)
    parts = []
    for j, ramp in enumerate(('cable', 'coral', 'mustard', 'cable')):
        start = c + np.array([j * 1.5 - 2., 0., j * .65])
        end = start + np.array([8. + j * 2.5, -12. - j, -start[2] + .35])
        parts += I.wire(start, start + np.array([4., -6., 2.]), end, rs, ramp,
                        group + str(j), r=.3, n=8, curl=2)
    return parts


def broken_ring(c, radius, group, tilt=.18):
    shape = A.Torus(c, radius, 1.4, A.rx(tilt))
    shape = I.Cut(shape, A.RoundBox(c + np.array([radius * .8, -radius * .5, 0.]),
                                   (12., 9., 22.), .2, A.rz(-.3)))
    return [P('broken_light_hoop', shape, 'white', group)]
