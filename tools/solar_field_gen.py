#!/usr/bin/env python3
"""Solar field equipment, rendered with GTFO's existing SDF camera/palettes.

The map generator calls static_models() to bake the collector and ground cable into
all four maps/depth masks. This tool renders eight physical mirror orientations and
mirror glint and crystal-deployment sheets, exports optical data and per-view pixel anchors.
Receiver masks come from the same SDF surfaces as the baked cone, for pixel-exact shine
and energizing waves. Wall-panel art/anchors belong to interior_gen.py.
No authored solution is stored in runtime metadata. Run through make solar (after map).
Writes assets/maps/red_planet/solar/* and solar_field.json. No hand-edited images.
SOLAR_FEED_DESIGN=shield retains the previous plate feed; beacon is the approved revision.
"""
import json
import math
import os

import numpy as np
from PIL import Image

import astronaut_sprite_gen as A
from solar_layout import load_field, mirror_mount


class CollectorShell(A.RoundCone):
    """Clip a round-cone's straight flank to the authored frustum height.

    The existing round-cone primitive provides the slope; the two clipping planes
    remove its spherical ends. Inheriting it retains the renderer's bounding contract.
    """
    def __init__(self, center, radius, top_radius, height):
        self.center = np.asarray(center, float)
        self.height = height
        slope = (radius - top_radius) / height
        cosine = 1 / math.sqrt(1 + slope * slope)
        r1 = (radius + slope * 100) * cosine
        super().__init__(self.center + [0, 0, -100], self.center + [0, 0, 100],
                         r1, r1 - 200 * slope * cosine)

    def local(self, P):
        return P - self.center

    def __call__(self, P):
        z = P[:, 2] - self.center[2]
        return np.maximum(super().__call__(P), np.maximum(-z, z - self.height))


def collector(M, C):
    spec = load_field()['collector']
    radius, top, height = spec['radius'], spec['top_radius'], spec['height']

    def cells(part, P):
        q = part.sdf.local(P)
        angle = np.arctan2(q[:, 1], q[:, 0]) / (2 * math.pi)
        row = q[:, 2] / 10.0
        side = angle * 32
        # Alternating diagonal edges give the blue receiver the approved triangular cells.
        diagonal = np.mod(side + np.where(np.floor(row) % 2 == 0, row, -row), 1)
        edge = (np.mod(row, 1) < .09) | (np.mod(side, 1) < .055) | (diagonal < .045)
        out = np.full(len(P), M.OID['panel'])
        out[edge] = M.OID['dark']
        glint = (~edge) & ((np.mod(side * .73 + row * .4, 5) < .65)
                           | (np.mod(side - row * .32, 16) < .7))
        out[glint] = M.OID['pline']
        return out

    parts = [M.P_('receiver', CollectorShell(C, radius, top, height), 'panel', 'solar-cone', cells),
             M.P_('plinth', A.Disc(C + [0, 0, 1], radius + 3, 1.5, .6, M.UPAX), 'concrete', 'solar-cone')]
    for z, r in [(3, radius - 1.6), (height - 1, top + .5)]:
        parts.append(M.P_('rim', A.Torus(C + [0, 0, z], r, 1.1), 'metal', 'solar-cone'))
    parts.append(M.P_('cap', A.Disc(C + [0, 0, height], top, 1, .4, M.UPAX), 'dark', 'solar-cone'))
    return parts


def static_models(M, ground):
    field = load_field()
    x, y = field['collector']['world']
    parts = collector(M, np.array([x, y, ground(x, y)]))
    for i, (start, end) in enumerate(zip(field['cable'], field['cable'][1:])):
        a, b = np.array([*start, ground(*start) + .9]), np.array([*end, ground(*end) + .9])
        parts.append(M.P_('cable', A.RoundCone(a, b, 1.3, 1.3), 'dark', f'solar-cable-{i}'))
    return parts


def mirror(M, angle, ramp, shine=0, pitch=0):
    z = load_field()['beam_height']
    span = load_field()['mirror_span']
    rotation = A.rz(angle) @ A.rx(pitch)
    def silver(part, P):
        q = part.sdf.local(P)
        diagonal = q[:, 0] + q[:, 2] * .7
        out = np.full(len(P), M.OID['panel'])
        out[(np.mod(diagonal + 30, 17) < 3.4)] = M.OID['pline']
        out[(np.abs(q[:, 0]) > span - .7) | (np.abs(q[:, 2]) > 8.6)] = M.OID['metal']
        if shine:
            band = -22 + shine * 11
            out[np.abs(diagonal - band) < 2.3] = M.OID['white']
        return out

    parts = [M.P_('foot', A.Disc([0, 0, 1.6], 6, 1.6, .5, M.UPAX), 'concrete', 'mirror'),
            M.P_('footrim', A.Torus([0, 0, 3], 4.9, .5), 'metal', 'mirror'),
            M.P_('post', A.RoundCone([0, 0, 2], [0, 0, z], 1.5, 1.1), 'dark', 'mirror'),
            M.P_('collar', A.Disc([0, 0, z - 9], 2.6, 1.3, .3, M.UPAX), ramp, 'mirror'),
            M.P_('frame', A.RoundBox([0, 0, z], [span + 1.4, 1.4, 11.4], .8, rotation), ramp, 'mirror'),
            M.P_('face', A.RoundBox([0, 0, z], [span, 1.55, 9.8], .4, rotation), 'pline', 'mirror', silver)]
    for side in [-1, 1]:
        parts.append(M.P_('pivot', A.Disc(rotation @ np.array([side * (span + 1.8), 0, 0]) + [0, 0, z],
                                        2.7, 1.1, .35, rotation), 'metal', 'mirror'))
    return parts


def sun_shield(M, angle, ramp, deploy):
    z = load_field()['beam_height']
    rotation = A.rz(angle)
    normal = rotation @ np.array([1., 0., 0.])
    C = np.array([0., 0., z])
    parts = [M.P_('foot', A.Disc([0, 0, 2], 8, 2, .7, M.UPAX), 'concrete', 'feed'),
             M.P_('footrim', A.Torus([0, 0, 3.6], 6.4, .6), ramp, 'feed'),
             M.P_('post', A.RoundCone([0, 0, 3], C, 2, 1.4), 'metal', 'feed'),
             M.P_('housing', A.RoundBox(C - normal * 3, [4, 8.6, 10], 1, rotation), ramp, 'feed'),
             M.P_('faceplate', A.RoundBox(C - normal * .2, [1.2, 7.4, 8.5], .5, rotation), 'metal', 'feed'),
             M.P_('lens', A.Disc(C + normal * 1.2, 5.5, 1, .5, rotation), 'pline' if deploy else 'darkwin', 'feed'),
             M.P_('lensrim', A.Torus(C + normal * 2.1, 5.8, .6, rotation @ A.ry(math.pi / 2)), 'white', 'feed')]
    for side in [-1, 1]:
        # Split lid petals lift away as the crystal rises from its socket.
        c = C - normal * 3 + rotation @ np.array([0, side * (3.8 + deploy * 4), 11 - deploy * 2])
        parts.append(M.P_('lid', A.RoundBox(c, [4, 3.7, .7], .3,
                                          rotation @ A.rx(side * deploy * .9)), 'metal', 'feed'))
    if deploy > 0:
        root = C - normal * 3 + [0, 0, 10]
        waist = root + [0, 0, 4 + deploy * 7]
        tip = root + [0, 0, 5 + deploy * 18]
        parts += [M.P_('crystalbase', A.RoundCone(root, waist, .7, 4.5), 'icex2', 'feed'),
                  M.P_('crystaltip', A.RoundCone(waist, tip, 4.5, .1), 'icex', 'feed'),
                  M.P_('crystalglint', A.RoundCone(waist + [-2, -2, 0], tip, .5, .1), 'white', 'feed')]
    return parts


def sun_feed(M, angle, ramp, deploy):
    """Armored beacon with a sealed crown; activation opens shutters and raises a prism."""
    if os.environ.get('SOLAR_FEED_DESIGN', 'beacon') == 'shield':
        return sun_shield(M, angle, ramp, deploy)
    z = load_field()['beam_height']
    rotation = A.rz(angle)
    normal = rotation @ np.array([1., 0., 0.])
    parts = [M.P_('foot', A.Disc([0, 0, 2], 8, 2, .6, M.UPAX), 'concrete', 'feed'),
             M.P_('footrim', A.Torus([0, 0, 3.8], 6.5, .6), ramp, 'feed'),
             M.P_('stem', A.RoundCone([0, 0, 3], [0, 0, 12], 3, 2.5), 'dark', 'feed'),
             M.P_('body', A.Disc([0, 0, 24], 6.3, 14.5, .8, M.UPAX), 'metal', 'feed'),
             M.P_('collar', A.Disc([0, 0, 13], 7.2, 2.0, .45, M.UPAX), ramp, 'feed'),
             M.P_('crown', A.Torus([0, 0, 38], 6.2, .65), ramp, 'feed'),
             M.P_('lens', A.Disc(normal * 6 + [0, 0, z], 2.6, .65, .25, rotation), 'pline' if deploy > .6 else 'darkwin', 'feed'),
             M.P_('lensrim', A.Torus(normal * 6.7 + [0, 0, z], 2.9, .4, rotation @ A.ry(math.pi / 2)), 'white', 'feed')]
    for side in range(3):
        turn = angle + side * 2 * math.pi / 3
        n = np.array([math.cos(turn), math.sin(turn), 0])
        parts.append(M.P_('rib', A.RoundBox(n * 5.9 + [0, 0, 24], [.6, 1.1, 8.5], .2, A.rz(turn)), ramp, 'feed'))
    if deploy == 0:
        parts.append(M.P_('sealedcap', A.Disc([0, 0, 39], 6.2, .9, .4, M.UPAX), 'metal', 'feed'))
    else:
        for side in [-1, 1]:
            c = rotation @ np.array([0, side * (3 + deploy * 5), 39 + deploy * 1.4])
            parts.append(M.P_('shutter', A.RoundBox(c, [5.6, 3, .65], .4, rotation @ A.rx(side * deploy * .85)), 'metal', 'feed'))
    growth = max(0.0, (deploy - .25) / .75)
    if growth > 0:
        # Existing sharp boxes form a short prism and a chisel-cut crown, rather than
        # the earlier rounded, floating double cone. The lower end stays in its socket.
        parts += [M.P_('prism', A.RoundBox([0, 0, 39 + 6 * growth], [2.5 * growth, 2.5 * growth, 6 * growth], .08, A.rz(math.pi / 4)), 'icex2', 'feed'),
                  M.P_('crystaltip', A.RoundBox([0, 0, 39 + 11.5 * growth], [2 * growth] * 3, .05, A.rz(math.pi / 4) @ A.rx(math.pi / 4)), 'icex', 'feed'),
                  M.P_('glint', A.RoundBox([-1.5 * growth, -1.5 * growth, 39 + 7 * growth], [.22 * growth, .22 * growth, 3 * growth], .02), 'white', 'feed')]
    return parts


def sheet(M, name, frames):
    box = M.sprite_box(frames, pad=3)
    rgba = np.concatenate([M.sprite_rgba(M.render_sprite(parts, box)) for parts in frames], axis=1)
    path = f'solar/{name}.png'
    Image.fromarray(rgba).save(os.path.join(M.OUT, path))
    return dict(file=path, frames=len(frames), size=[box[2], box[3]],
                anchor=[round(M.AX - box[0]), round(M.AY - box[1])])


def main():
    import mars_map_gen as M
    meta = json.load(open(os.path.join(M.OUT, 'red_planet_map.json')))
    M.AX, M.AY = meta['origin_px']
    os.makedirs(os.path.join(M.OUT, 'solar'), exist_ok=True)
    field = load_field()
    field['feed_visual'] = ({'crystal_offset': [-3, 0], 'tip_closed': field['beam_height'] + 15,
                            'tip_open': field['beam_height'] + 33, 'emerge': 0}
                           if os.environ.get('SOLAR_FEED_DESIGN', 'beacon') == 'shield' else
                           {'crystal_offset': [0, 0], 'tip_closed': 39, 'tip_open': 53.3, 'emerge': .25})
    # Reach anchors for capture/validation; actual play can approach from any side.
    field['stands'] = {}
    center = np.array(field['collector']['world'])
    for route in field['routes']:
        controls = [(route['id'] + ' SUN', route['source'])]
        controls.extend((route['id'] + str(i + 1), point) for i, point in enumerate(route['mirrors']))
        for name, point in controls:
            stand = np.array(point) + [18, -12]
            if np.linalg.norm(stand - center) < field['collector']['radius'] + 8:
                stand = np.array(point) + [-18, -12]
            field['stands'][name] = stand.tolist()
    field['sheets'] = {}
    field['special_mirrors'] = {}
    for route in field['routes']:
        ramp = route['ramp']
        print('rendering solar equipment:', route['label'], flush=True)
        field['sheets'][route['id']] = {
            'mirror': dict(sheet(M, 'mirror_' + route['id'].lower(),
                                 [mirror(M, a * math.pi / 8, ramp, shine) for a in range(8) for shine in range(4)]), shine_frames=4),
            'source': dict(sheet(M, 'source_' + route['id'].lower(),
                                 [sun_feed(M, a * math.pi / 2, ramp, step / 8) for a in range(4) for step in range(9)]), deploy_frames=9)}
        for index in range(len(route['mirrors'])):
            yaw, pitch = mirror_mount(route, field, index)
            if abs(yaw) < 1e-6 and abs(pitch) < 1e-6:
                continue
            field['special_mirrors'][route['id'] + str(index + 1)] = [
                dict(sheet(M, f'mirror_{route["id"].lower()}{index + 1}{M.view_sfx(k)}',
                           [mirror(M, a * math.pi / 8 + yaw - k * math.pi / 2, ramp, shine, pitch)
                            for a in range(8) for shine in range(4)]), shine_frames=4)
                for k in range(4)]
    field['views'] = []
    for k, filename in enumerate(meta['views']):
        view = json.load(open(os.path.join(M.OUT, filename)))
        M.AX, M.AY = view['origin_px']
        x, y = field['collector']['world']
        p = M.to_view([x, y, field['collector']['height'] + 12], k)
        center = M.to_view([x, y, 0], k)
        parts = collector(M, np.array([x, y, 0]))
        frames = M.turned(parts, k=k)
        box = M.sprite_box([frames], pad=2)
        fr = M.render_sprite(frames, box)
        jj, ii = np.mgrid[:box[3], :box[2]]
        xx = (box[0] + ii + .5 - M.AX) * M.S
        yy = np.where(fr['filled'], fr['D'], center[1])
        zz = (M.AY - box[1] - jj - .5) / M.PX - M.KY * yy
        angle = np.arctan2(yy - center[1], xx - center[0]) / (2 * math.pi)
        row, side = zz / 10, angle * 32
        edge = (np.mod(row, 1) < .09) | (np.mod(side, 1) < .055) | (np.mod(side + np.where(np.floor(row) % 2 == 0, row, -row), 1) < .045)
        mask = np.zeros((*fr['filled'].shape, 4), np.uint8)
        mask[..., 0] = np.clip(zz / field['collector']['height'] * 255, 0, 255).astype(np.uint8)
        mask[..., 1] = np.where(edge, 0, 255)
        mask[..., 2] = np.clip((yy - center[1] + field['collector']['radius']) / (2 * field['collector']['radius']) * 255, 0, 255).astype(np.uint8)
        mask[..., 3] = np.where(fr['filled'] & (zz > 4) & (zz < field['collector']['height'] - 2), 255, 0)
        filename = f'solar/receiver_mask{M.view_sfx(k)}.png'
        Image.fromarray(mask).save(os.path.join(M.OUT, filename))
        field['views'].append({'indicator_px': [round(v) for v in M.project(*p)],
                               'receiver_mask': {'file': filename, 'position': list(box[:2]), 'size': list(box[2:])}})
    with open(os.path.join(M.OUT, 'solar_field.json'), 'w') as stream:
        json.dump(field, stream, indent=2)
    print('solar field: 4 / 5 / 4 reflectors, three closed feeds, four views', flush=True)


if __name__ == '__main__':
    main()
