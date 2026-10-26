#!/usr/bin/env python3
"""Read-only cultivation QA against generated art, walk grids and forest clearings.

Checks all wild plants/approaches in the spawn's actual walk component; filler
clearance in four views; colour/depth/glow atlas alignment; character-scale wild
models; distinct bloom/seed states; five bed sheets and every nursery repair
combination's reachable controls/doors. Run after make map / make nursery.
"""
from pathlib import Path
import hashlib
import json
import math
import numpy as np
from PIL import Image
from scipy import ndimage as ndi

ROOT = Path(__file__).resolve().parents[1]
WORLD = ROOT / 'assets/maps/red_planet'
ROOM = ROOT / 'assets/maps/nursery_interior'
ART = ROOT / 'assets/cultivation'
checks = 0


def check(ok, label):
    global checks
    checks += 1
    if not ok:
        raise AssertionError(label)


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def uv(point):
    return int((point[0] + point[1]) / math.sqrt(2)), int((point[1] - point[0]) / math.sqrt(2))


def walk_component(path, spawn):
    walk = np.asarray(Image.open(path))[..., 2] == 255
    labels, _ = ndi.label(walk)
    u, v = uv(spawn)
    component = labels[v, u]
    check(component != 0, 'spawn is walkable: ' + str(path))
    return labels, component


def atlas(root, info):
    colour = np.asarray(Image.open(root / info['file']).convert('RGBA'))
    depth = np.asarray(Image.open(root / info['data']).convert('RGBA'))
    w, h = info['frame_size']
    check(colour.shape == depth.shape == (h, w * info['frames'], 4), 'atlas dimensions match ' + info['file'])
    check(np.array_equal(colour[..., 3], depth[..., 3]), 'native depth silhouette matches ' + info['file'])
    check(np.all(depth[..., 2] <= colour[..., 3]), 'glow clipped to plant ' + info['file'])
    if 'glow' in info:
        glow = np.asarray(Image.open(root / info['glow']).convert('RGBA'))
        check(np.array_equal(glow[..., 3], depth[..., 2]), 'turn glow silhouette matches ' + info['file'])
    check(info['local_depth_scale'] == 512 and info['depth_offset'] == 64, 'local depth contract ' + info['file'])
    return colour


def main():
    config = read(ROOT / 'data/cultivation.json')
    art = read(ART / 'cultivation.json')
    for species in ('cindercoil', 'moonwell'):
        check(len(art['wild'][species]) == 4, species + ' has four views')
        gathered_changes = []
        for k, info in enumerate(art['wild'][species]):
            colour = atlas(ART, info)
            w, _ = info['frame_size']
            alpha = colour[:, :w, 3]
            rows = np.nonzero(alpha.any(axis=1))[0]
            height = rows[-1] - rows[0] + 1
            check(32 <= height <= 64, f'{species} view {k} is near astronaut scale ({height} px)')
            if species == 'moonwell':
                check(info['frames'] == 18, 'opening and gathered Moonwell frames')
                check(not np.array_equal(colour[:, :w], colour[:, 8*w:9*w]), 'Moonwell really opens')
                check(not np.array_equal(colour[:, 8*w:9*w], colour[:, 17*w:18*w]), 'gathered seeds disappear')
            else:
                # Rear-facing woody cases naturally hide both full and empty seed cavities.
                gathered_changes.append(not np.array_equal(colour[:, :w], colour[:, w:2*w]))
        if species == 'cindercoil':
            check(any(gathered_changes), 'visible Cindercoil seeds disappear when gathered')
    for kind, filename in art['icons'].items():
        icon = Image.open(ART / filename)
        check(max(icon.size) <= 28, kind + ' inventory icon fits')
    forage = read(WORLD / 'forage_sites.json')
    check(len(forage['sites']) == int(config['wild_per_species']) * 2, 'dispersed seed-plant count')
    check(len({p['id'] for p in forage['sites']}) == len(forage['sites']), 'stable unique world IDs')
    meta = read(WORLD / 'red_planet_map.json')
    labels, component = walk_component(WORLD / meta['game']['walk_png'], meta['game']['spawn_world'])
    biome = np.asarray(Image.open(WORLD / 'red_planet_biome.png'))
    for site in forage['sites']:
        u, v = uv(site['world'])
        weights = biome[v // 4, u // 4]
        check(weights[1] == max(weights) and weights[1] >= config['forest_fraction_min'] * 255 - 6,
              site['id'] + ' belongs to the forest, clear of red/snow biome edges')
        for stand in (site['world'], site['stand_world']):
            u, v = uv(stand)
            check(labels[v, u] == component, site['id'] + ' reachable root/approach')
    centres = np.array([site['world'] for site in forage['sites']])
    for plant in forage['removed_filler']:
        check(plant['species'] not in ('tree', 'ice'), 'clearings preserve trees and ice')
        check(np.min(np.linalg.norm(centres - [plant['X'], plant['Y']], axis=1)) < forage['clearing_radius'], 'only filler inside a clearing removed')
    for k, filename in enumerate(meta['views']):
        view = read(WORLD / filename)
        flora = read(WORLD / view['fx'])['flora']
        centre = np.array(view['game']['view_center'])
        for instance in flora['instances']:
            sh = flora['sheets'][instance[0]]
            vx = (instance[1] + sh['anchor'][0] - view['origin_px'][0]) * view['game']['world_units_per_px']
            vy = instance[4] / flora['depth_scale']
            p = np.array([vx, vy]) - centre
            for _ in range(k):
                p = np.array([-p[1], p[0]])
            p += centre
            check(np.min(np.linalg.norm(centres - p, axis=1)) >= forage['clearing_radius'] - .4, 'filler clearance in view ' + str(k))
    beds = read(ROOM / 'crops.json')['beds']
    check({b['id'] for b in beds} == set(config['beds']), 'five authored crop beds')
    for bed in beds:
        for info in bed['views']:
            atlas(ROOM, info)
    unique = set()
    for mask in range(8):
        base = 'nursery' if mask == 0 else f'nursery_repairs_{mask}'
        m = read(ROOM / f'{base}.json')
        labels, component = walk_component(ROOM / m['game']['walk_png'], m['game']['spawn_world'])
        stands = [b['stand_world'] for b in beds]
        stands += [r['stand_world'] for r in m['cultivation']['repairs']]
        check(all(r['scan_height'] > 0 for r in m['cultivation']['repairs']), 'native scanner heights for repair state ' + str(mask))
        for d in m['doors']:
            stands.append(np.array(d['world']) + np.array(d['dir']) * 26.)
        for stand in stands:
            u, v = uv(stand)
            check(labels[v, u] == component, f'repair state {mask} reachable approach {stand}')
        for filename in m['views']:
            view = read(ROOM / filename)
            check(view['cultivation']['repair_mask'] == mask, 'repair state metadata')
            check(Image.open(ROOM / view['image']).size == tuple(view['size']), 'repair colour size')
            for field in ('depth_png', 'light_png', 'sun_png'):
                check(Image.open(ROOM / view['game'][field]).size == tuple(view['size']), 'repair depth/lighting size')
        unique.add(hashlib.sha256((ROOM / m['image']).read_bytes()).hexdigest())
    check(len(unique) == 8, 'all independent repair combinations have distinct native art')
    print(f'CULTIVATION ART QA: {checks} checks, 0 failures')


if __name__ == '__main__':
    main()
