"""Verify generated solar placement against actual walk/depth/view data.

This checks shared walk components from the main-base spawn to every interaction,
declared elevations at hardware, graded access paths, generous spacing, preserved vegetation,
valid sprite/depth strips with matching silhouettes and projected
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
    # The forest as the solar field was laid out around it, fingerprinted by where each plant
    # stands (see placement_hash). Taken from the assets at the time and unchanged since: the
    # gentler tree sway narrowed the sprite boxes, which moved 339 of the stored x values by a
    # pixel without moving a single foot, and these hashes are the same either way.
    'b790a9d3d983257d92ef9272bee6629810750ea2141a62bf5971d62aa287691a',
    'cc7a886067b08d1533bb02f1717d6f8333b5cd3f88f3106a11fdcd9e804d66e0',
    'dc28813417ef01d6930251038affa0afb88249013959bfd7a08c871c6a15ed43',
    'd259d8088be0f18010eac92dc52a6ce595d2ad296d254ce3bb8a9573e86640ec',
]
# Variant, horizontal foot, sway phase and view depth fix the original X/Y placement.
# The approved terraces change vertical feet and terrain occlusion, so v2 checks those
# placements independently of ground height and live-glow visibility.
ORIGINAL_FLORA_PLACEMENTS = [
    'c9597a53f020a2b5fbf9ea85cc24fc4110cfd031fd73e8b5f66adeb6e9375472',
    '24b0b6a907f0a095b6861d5a34414456b1fa5f326edb0839d131cc821d587ce3',
    '2bfbfe2139870537050ee00f448220711d22d554f10961e5edf0f7a9508c7fb2',
    'a27ce2debd32bb45551b67ad02f87e0da4c3e1ae5ae035b56de493bb8f95bebb',
]

def placement_hash(flora, terraced=False):
    """Where every plant stands, and nothing else.

    An instance's stored x is the left edge of its sprite's box, so anything that changes how
    wide that box is - how far the plant leans, say - moves the number without moving the
    plant. The foot (x plus the sheet's anchor) is the position the clearance checks below
    care about, so that is what is fingerprinted: a plant that really moves still trips this,
    and a plant that only got drawn differently does not.
    """
    feet = [[i[0], round(i[1] + flora['sheets'][i[0]]['anchor'][0], 3),
             i[3] if terraced else round(i[2] + flora['sheets'][i[0]]['anchor'][1], 3),
             i[4]] for i in flora['instances']]
    return hashlib.sha256(json.dumps(feet, separators=(',', ':')).encode()).hexdigest()


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
        if 'shine_frames' in sheet:
            depth = sheet['depth']
            atlas = np.asarray(Image.open(os.path.join(BASE, depth['file'])))
            width, height = sheet['size']
            assert atlas.shape == (height, width * depth['frames'], 4), 'malformed mirror depth strip'
            assert depth['frames'] * sheet['shine_frames'] == sheet['frames'], 'depth/shine frames disagree'
            rgba = np.asarray(image)
            for frame in range(depth['frames']):
                mask = atlas[:, frame * width:(frame + 1) * width, 3]
                for shine in range(sheet['shine_frames']):
                    start = (frame * sheet['shine_frames'] + shine) * width
                    assert np.array_equal(mask, rgba[:, start:start + width, 3]), 'depth silhouette differs from mirror sprite'
            assert depth['skin_depth_span'] == 32 and np.any(atlas[..., 2] > 0), 'reflective optical skin gap missing'
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
        terraced = bool(field.get('terrain'))
        expected = (ORIGINAL_FLORA_PLACEMENTS if terraced else ORIGINAL_FLORA)[heading]
        assert placement_hash(flora, terraced) == expected, 'the original forest placements changed'
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
