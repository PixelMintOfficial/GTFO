"""Verify generated solar placement against actual walk/depth/view data.

This checks shared walk components from the main-base spawn to every interaction,
declared elevations at hardware, graded access paths, generous spacing, preserved vegetation,
valid sprite strips and projected
four-view indicator positions. It reads generated assets; it never changes them.
Run after make map: python tools/check_solar_field.py.
"""
import json
import hashlib
import math
import os

import numpy as np
from PIL import Image
from scipy import ndimage

from solar_layout import access_profile, equipment, load_field

# The original main map (27b92c9), before solar work: exact instance placement/order in each
# view. Hardware pads must not reroll or remove the forest. Update only for authored flora changes.
# 2026-10-11: the trail lamps went (TRAIL_LAMPS); placements are identical, but three plants whose
# glow a lamp post hid now show it (the last field, live_glow_flags): views 0 and 2 updated.
ORIGINAL_FLORA = [
    'bafe18a8a80839e8484a82cc15d73a4af6c5522f77743ac756a99220798c5c35',
    '7a6df5795b1308c51abbace62fab83483b6af2ab7b04fa035f9ed2139803bb7b',
    '9b120fe5fccb2fe54d6c3b124e226f060d7239551791780f37ccefe9e92fb885',
    'a4e398087fb1577b1731a1b00f7f86df9e071274f1070d526b1a369c3d6076f6',
]
# Variant, horizontal foot, sway phase and view depth fix the original X/Y placement.
# The approved terraces change vertical feet and terrain occlusion, so v2 checks those
# placements independently of ground height and live-glow visibility.
ORIGINAL_FLORA_PLACEMENTS = [
    '9785d7c5d3e99cfdb7619515e15cdfc8db23306b6bf97ba7e66ad09431569087',
    'c01b4d171b16a741984769461a34e4364de79132d666c1a7ac03c26bc4e26a30',
    '36e8d4c88f6520363f5b129fc78083f17db6fc73cad5ff6d4da8b0f157f91455',
    'cedad2fdb16759ab9f9cb95ab7acbc119556cc5c8ba196a0e1bd6ee36abca34d',
]

ROOT = os.path.dirname(os.path.dirname(__file__))
BASE = os.path.join(ROOT, 'assets', 'maps', 'red_planet')


def read(name):
    with open(os.path.join(BASE, name), encoding='utf-8') as stream:
        return json.load(stream)


def cell(point):
    x, y = point
    return round((y - x) / math.sqrt(2) - .5), round((y + x) / math.sqrt(2) - .5)


def main():
    field, meta, art = load_field(), read('red_planet_map.json'), read('solar_field.json')
    walk = np.asarray(Image.open(os.path.join(BASE, meta['game']['walk_png']))).astype(np.int32)
    labels, _ = ndimage.label(walk[..., 2] > 191, np.ones((3, 3)))
    spawn_label = labels[cell(meta['game']['spawn_world'])]
    assert spawn_label != 0, 'main-base spawn is not walkable'
    positions = list(equipment(field))
    counts = [4, 5, 4] if os.environ.get('SOLAR_FIELD_LAYOUT') == 'v1' else [3, 3, 4]
    assert [len(route['mirrors']) for route in field['routes']] == counts, 'incorrect route counts'
    assert art['collector'] == field['collector'] and art['routes'] == field['routes'], 'stale solar art metadata'
    for route in field['routes']:
        expected_yaw = math.atan2(route['direction'][1], route['direction'][0]) if field.get('terrain') else 0
        assert abs(art['sheets'][route['id']]['source']['yaw_offset'] - expected_yaw) < 1e-6, 'beacon outlet does not face its ray'
    center = field['collector']['world']
    for i, (name, point, _) in enumerate(positions):
        assert math.dist(point, center) > field['collector']['radius'] + 35, name + ' crowds the receiver'
        for other, target, _ in positions[i + 1:]:
            assert math.dist(point, target) >= 80, f'{name}/{other}: equipment is crowded'
    path_cells = []
    for path in field.get('access_paths', []):
        for a, b in zip(path['points'], path['points'][1:]):
            # Center and both sides must be connected, not just an isolated pad.
            delta = np.array(b[:2]) - a[:2]
            side = np.array([-delta[1], delta[0]]) / np.linalg.norm(delta) * (path['half_width'] - 3)
            for t in np.linspace(0, 1, math.ceil(np.linalg.norm(delta)) + 1):
                for offset in [np.zeros(2), side, -side]:
                    row, column = cell(np.array(a[:2]) + delta * t + offset)
                    assert labels[row, column] == spawn_label, f'access path is blocked at {a}/{b}, t={t:.2f}'
                    path_cells.append((row, column))
    if path_cells:
        rows, columns = np.array(path_cells).T
        # Compare at the actual grid cell, using continuous grade blending at bends/branches.
        x, y = (columns - rows) / math.sqrt(2), (columns + rows + 1) / math.sqrt(2)
        _, expected = access_profile(field, x, y)
        heights = (walk[rows, columns, 0] * 256 + walk[rows, columns, 1]) / meta['game']['height_scale'] - meta['game']['height_offset']
        assert np.max(np.abs(heights - expected)) < .02, 'access ramp does not match its authored grade'
    for name, point, elevation in positions:
        stand = art['stands'][name]
        assert math.dist(stand, point) < field['reach'], name + ' approach outside interaction reach'
        row, column = cell(stand)
        assert labels[row, column] == spawn_label, name + ' cannot be reached from the base'
        height = (walk[row, column, 0] * 256 + walk[row, column, 1]) / meta['game']['height_scale'] - meta['game']['height_offset']
        assert abs(height - elevation) < (1 if elevation else .02), f'{name}: unexpected ground elevation ({height})'
        assert walk[cell(point)][2] == 0, name + ' has no baked pedestal collision'
    assert walk[cell(field['collector']['world'])][2] == 0, 'collector has no collision'
    strips = [sheet for sheets in art['sheets'].values() for sheet in sheets.values()]
    strips.extend(sheet for sheets in art['special_mirrors'].values() for sheet in sheets)
    for sheet in strips:
        image = Image.open(os.path.join(BASE, sheet['file']))
        assert image.size == (sheet['size'][0] * sheet['frames'], sheet['size'][1]), 'malformed sprite strip'
    for heading, filename in enumerate(meta['views']):
        view = read(filename)
        assert view['game']['heading'] == heading
        center = view['game']['view_center']
        px, py = np.array(field['collector']['world']) - center
        for _ in range(heading):
            px, py = py, -px
        px, py = np.array([px, py]) + center
        game = view['game']
        anchor = [view['origin_px'][0] + px / game['world_units_per_px'],
                  view['origin_px'][1] - (py * game['depth_to_px'] + field['collector']['height'] + 12) * game['px_per_unit']]
        assert np.linalg.norm(np.array(anchor) - art['views'][heading]['indicator_px']) <= 1, 'stale indicator view'
        fx = read(view['fx'])
        flora = fx['flora']
        if field.get('terrain'):
            instances = [[i[0], i[1], i[3], i[4]] for i in flora['instances']]
            expected = ORIGINAL_FLORA_PLACEMENTS[heading]
        else:
            instances, expected = flora['instances'], ORIGINAL_FLORA[heading]
        fingerprint = hashlib.sha256(json.dumps(instances, separators=(',', ':')).encode()).hexdigest()
        assert fingerprint == expected, 'the original forest placements changed'
        mask = art['views'][heading]['receiver_mask']
        assert Image.open(os.path.join(BASE, mask['file'])).size == tuple(mask['size']), 'stale receiver mask'
        for instance in flora['instances']:
            sheet = flora['sheets'][instance[0]]
            # Invert the existing instance contract (map foot X and encoded view Y).
            vx = (instance[1] + sheet['anchor'][0] - view['origin_px'][0]) * game['world_units_per_px']
            vy = instance[4] / flora['depth_scale']
            vx, vy = np.array([vx, vy]) - center
            for _ in range(heading):
                vx, vy = -vy, vx
            wx, wy = np.array([vx, vy]) + center
            for name, point, elevation in positions:
                # Raised equipment retains nearby undergrowth on the same hill.
                clearance = 18 if elevation else 38
                assert math.hypot(wx - point[0], wy - point[1]) > clearance, name + ' overlaps original vegetation'
    print(f'SOLAR ASSET CHECK: {len(positions)} spaced/reachable controls, graded approaches, original forest placements, four views')


if __name__ == '__main__':
    main()
