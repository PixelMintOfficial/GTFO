#!/usr/bin/env python3
"""Modest console/light/rack damage and all three independent scanner repair states.

Called by nursery_gen.py. Preserves the intact composition as the repaired result,
exports every repair-bit combination in four views, and generates crop-only
overlays separately so seed/growth state does not multiply whole-room variants.
Each variant has its actual walk/depth/light layers. Animated airlocks are shared.
Repair metadata owns the physical scanner height and nursery UNIT's floor/patrol anchors;
--repair-metadata-only refreshes them without redrawing the room.
Floor conduits remain intact; the dry channel is grey steel. No dangling wire bundles.
No production exporter runs at import; use make nursery.
"""
import json
import math
import numpy as np
import cultivation_models as C
import cultivation_gen as Art

M, I, A, P, UP = C.M, C.I, C.A, C.P, C.UP


def furniture(N, mask):
    original_rosette, original_tree = N.rosette, N.flowering_tree
    def rosette(c, size, seed, group, flower=False):
        if group.startswith(('living_wall', 'light_tower')):
            return []  # independent crop overlays own all growth stages
        return (original_rosette if mask == 7 else C.dead_rosette)(c, size, seed, group, flower)
    N.rosette = rosette
    N.flowering_tree = original_tree if mask == 7 else C.dead_specimen
    native = N.furniture()
    N.rosette, N.flowering_tree = original_rosette, original_tree
    parts = [C.clone_part(p, sdf=p.sdf.inner) for p in native]
    result = []
    console_chip = I.Either(
        A.RoundBox(N.at(12., -126., 39.), (4.5, 3., 2.1), .15, A.ry(-.3)),
        A.RoundBox(N.at(14., -126., 35.5), (2.4, 3., 3.6), .15))
    for p in parts:
        g, ramp = p.group, p.ramp
        if not mask & 1 and g == 'central_control':
            # A chipped monitor corner replaces the old hole and hanging harness in the base.
            p = C.clone_part(p, I.Cut(p.sdf, console_chip))
            if ramp == 'screen':
                ramp = 'darkwin'
        if not mask & 2:
            if g == 'light_tower0_halo':
                continue
            if g.startswith('light_tower0_tier2'):
                p = C.pose(p, N.at(-123, 6, 45), A.rx(.4) @ A.rz(.13), (5., -3., -6.))
            if ramp == 'ledcyan':
                ramp = 'deadbulb'
        if not mask & 4:
            if g == 'living_wall1_shelf1':
                p = C.rack_damage_pose(p, N.at(0., 155.))
            elif g == 'living_wall1' and ramp == 'white':
                p = C.clone_part(p, I.Cut(p.sdf, A.RoundBox(N.at(23., 155., 28.), (4., 6., 6.), .2)))
        if mask != 7 and ramp == 'liquid':
            ramp = 'steel' if g == 'circulating_water' else 'darkwin'
        if not mask & 1 and ramp == 'screen':
            ramp = 'darkwin'
        result.append(C.clone_part(p, ramp=ramp))
    if not mask & 1:
        for side in (-1., 1.):
            points = [N.at(x, -126. + side * 1.75, z) for x, z in
                      ((10., 37.), (4., 33.), (7., 30.), (-1., 27.))]
            for a, b in zip(points, points[1:]):
                result.append(N.rod(a, b, .28, 'char', 'console_screen_crack'))
    if not mask & 2:
        result += C.broken_ring(N.at(-102., -15., 5.), 21., 'dropped_tower_light')
    return [C.clone_part(p, M.Scaled(p.sdf, N.C, N.LAYOUT_SCALE)) for p in result]


def metadata(N, mask, k):
    config = json.loads((N.ROOT / 'data/cultivation.json').read_text())
    points = {'console': ((0., -127.), (0., -154.)),
              'light': ((-102., -15.), (-103., -22.)),
              'rack': ((0., 144.), (0., 119.))}
    scan_heights = {'console': 40., 'light': 12., 'rack': 45.}
    repairs = []
    for entry in config['repairs']:
        item = dict(entry)
        world, stand = [M.scale_pt(N.at(*point), N.C, N.LAYOUT_SCALE) for point in points[entry['id']]]
        item.update(world=world[:2].tolist(), stand_world=stand[:2].tolist(),
                    scan_height=scan_heights[entry['id']] * N.LAYOUT_SCALE)
        repairs.append(item)
    def floor_point(x, y):
        return M.scale_pt(N.at(x, y), N.C, N.LAYOUT_SCALE)[:2].tolist()
    bot = dict(body='nursery', world=floor_point(-48., -96.), facing=[0., -1.], radius=7.,
               cleaning_spots=[floor_point(*p) for p in [(-48., -78.), (44., -46.), (12., 62.), (-60., 48.)]])
    return dict(bot=bot, repair_variants={str(i): f'nursery_repairs_{i}.json' for i in range(1, 8)},
                cultivation=dict(repair_mask=mask, repairs=repairs, crops='crops.json'))


def repair_metadata_only(N):
    """Refresh scanner anchors in every existing repair/view JSON; leave native art intact."""
    N.setup_room()
    for mask in range(8):
        base = 'nursery' if mask == 0 else f'nursery_repairs_{mask}'
        for k in M.VIEWS:
            path = N.OUT / f'{base}{M.view_sfx(k)}.json'
            data = json.loads(path.read_text())
            data.update(metadata(N, mask, k))
            M.save_text(json.dumps(data, indent=2), str(path))
    print('nursery scanner metadata refreshed in all repair states and views', flush=True)


def build(N):
    N.setup_room()
    (N.OUT / 'anim').mkdir(parents=True, exist_ok=True)
    (N.OUT / 'preview').mkdir(exist_ok=True)
    original_door = N.render_door
    door_cache = {}
    def cached_door(index, normal):
        key = (M.VIEW, index)
        if key not in door_cache:
            door_cache[key] = original_door(index, normal)
        return door_cache[key]
    N.render_door = cached_door
    for mask in range(8):
        N.setup_room()
        base = 'nursery' if mask == 0 else f'nursery_repairs_{mask}'
        walk = f'{base}_walk.png'
        parts = furniture(N, mask)
        N.world_grid(parts, walk)
        for k in M.VIEWS:
            N.render_view(k, parts, base, walk, metadata(N, mask, k))
        print(f'nursery repair state {mask}/7 generated', flush=True)
    N.render_door = original_door
    Art.export_beds(N)
    M.save_text(json.dumps(dict(sprites={}, objects=[], lamps=[])), str(N.OUT / 'nursery_props.json'))
    print('damaged nursery and crops generated ->', N.OUT, flush=True)
