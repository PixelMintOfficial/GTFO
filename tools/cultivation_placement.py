#!/usr/bin/env python3
"""Deterministic, reachable seed-plant clearings within the existing forest.

Called by mars_map_gen after its original flora placement random stream finishes.
Selects gentle forest understory sites, keeps clear of trees/buildings/equipment,
and removes only filler understory inside small authored clearings. No random
draw is added to the original forest stream. Canonical placements and the exact
removed filler are exported by the map generator for runtime and QA.
"""
from pathlib import Path
import json
import math
import numpy as np
from scipy import ndimage as ndi

ROOT = Path(__file__).resolve().parents[1]


def place_forage(G, domes, walkable):
    config = json.loads((ROOT / 'data/cultivation.json').read_text())
    radius = float(config['clearing_radius'])
    flora = G['flora']
    trees = np.array([[p['X'], p['Y']] for p in flora if p['species'] == 'tree'])
    # Use the same smoothed slopes, structures and tree trunks as the game's walk grid.
    traversable = walkable
    regions, _ = ndi.label(traversable)
    sizes = np.bincount(regions.ravel())
    sizes[0] = 0
    connected = int(np.argmax(sizes))
    candidates = []
    for p in flora:
        if p['species'] in ('tree', 'ice'):
            continue
        x, y = p['X'], p['Y']
        u, v = int((x + y) / math.sqrt(2)), int((y - x) / math.sqrt(2))
        if (G['bio_f'][u, v] < float(config['forest_fraction_min']) or
                G['nZ'][u, v] < .96 or G['mat'][u, v] in (2, 4, 5, 6)):
            continue
        if regions[u, v] != connected:
            continue
        if G['path_d'][u, v] < 14 or G['lane_d'][u, v] < 18:
            continue
        if len(trees) and np.min(np.linalg.norm(trees - [x, y], axis=1)) < 40:
            continue
        if min(math.hypot(x - d['X'], y - d['Y']) - d['R'] for d in domes) < 48:
            continue
        # Every site has a level approach rather than sitting in a scenery-only pocket.
        if not np.all(G['nZ'][u - 7:u + 8, v - 7:v + 8] > .90):
            continue
        candidates.append((x, y, p['z']))
    if not candidates:
        raise RuntimeError('No suitable forest seed-plant sites')
    points = np.asarray(candidates)
    centre = points[:, :2].mean(axis=0)
    choice = int(np.argmin(np.linalg.norm(points[:, :2] - centre, axis=1)))
    selected = []
    distances = np.full(len(points), np.inf)
    wanted = int(config['wild_per_species']) * 2
    for j in range(wanted):
        p = points[choice]
        if j and distances[choice] < float(config['site_spacing']):
            raise RuntimeError(f'Only {j}/{wanted} well-spaced forage sites fit')
        selected.append(p)
        distances = np.minimum(distances, np.linalg.norm(points[:, :2] - p[:2], axis=1))
        choice = int(np.argmax(distances))
    sites = []
    for j, p in enumerate(selected):
        species = 'cindercoil' if j % 2 == 0 else 'moonwell'
        sites.append(dict(id=f'{species}_{j // 2:02d}', species=species,
                          world=[round(float(p[0]), 4), round(float(p[1]), 4)],
                          height=round(float(p[2]), 4), clearance=radius))
    selected = np.asarray(selected)
    keep, removed = [], []
    for p in flora:
        clear = (p['species'] not in ('tree', 'ice') and
                 np.min(np.linalg.norm(selected[:, :2] - [p['X'], p['Y']], axis=1)) < radius)
        (removed if clear else keep).append(p)
    G['flora'] = keep
    G['forage'] = dict(sites=sites, removed_filler=removed, clearing_radius=radius,
                       character_height=22., version=1)
    print(f'cultivation: {len(sites)} seed plants, {len(removed)} filler plants cleared', flush=True)
    return G['forage']
