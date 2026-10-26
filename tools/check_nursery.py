"""Nursery QA regressions against native models and the exported animation sheets.

The arrival overlay must leave the walk surface transparent; a y-sorted floor in
that sprite covers the astronaut's legs. The propagation ring must stay at floor
height, both monitor faces must be screens, and the room must use the approved
smaller scale. Reads assets and models only; run after make nursery / make map.
Also guards intact floor feeds, grey dry channels, wire-free damage and the repairable rear shelf.
"""
import json
from pathlib import Path
import numpy as np
from PIL import Image
import nursery_gen as N
import nursery_cultivation as NC

failures = []
checks = 0


def check(ok, label):
    global checks
    checks += 1
    if not ok:
        failures.append(label)
        print('FAIL:', label)


N.setup_room()
root = Path(N.OUT)
meta = json.loads((root / 'nursery.json').read_text())
N.M.VIEW = 0
for door in meta['doors']:
    # Sample the walk surface well inside the door, during its fully open frame.
    point = np.array([*door['world'], .2]) + np.array([*door['dir'], 0.]) * 34.
    px = N.M.project(*point)
    x, y = int(round(px[0] - door['position'][0])), int(round(px[1] - door['position'][1]))
    w, h = door['frame_size']
    sheet = np.asarray(Image.open(root / door['file']).convert('RGBA'))
    alpha = int(sheet[y, x + (door['frames'] - 1) * w, 3]) if 0 <= x < w and 0 <= y < h else 0
    check(alpha == 0, f"door {door['id']} animation leaves the landing below the astronaut")

water = [p for p in N.water_loop() if p.group in
         ('water_housing', 'circulating_water', 'water_edge', 'island_floor')]
points = N.WATER_C + np.array([[69., 0., z] for z in np.linspace(.2, 9., 45)])
check(all(np.all(p.sdf(points) > 0) for p in water), 'propagation ring is flush with the floor')

screen = N.console(N.at(), 'probe', 17.)
for side in (-1, 1):
    for height in (28., 33., 38.):
        rays = N.at() + np.array([[12., side * y, height] for y in np.linspace(8., 0., 801)])
        hits = [(int(np.flatnonzero(p.sdf(rays) <= 0)[0]), p.ramp)
                for p in screen if np.any(p.sdf(rays) <= 0)]
        face = min(hits)[1] if hits else None
        check(face == 'screen', f'monitor side {side:+d} displays the screen at height {height}')

check(N.M.DOMES['nursery']['R'] <= 160., 'exterior nursery radius is reduced')
check(N.RADIUS <= 155., 'interior nursery radius is reduced')
building = N.M.DOMES['nursery']
center = N.M.cam(building['X'], building['Y'], building['Z'])
contents, _ = N.M.nursery_interior(building)
extent = max(np.linalg.norm(c - center) + r for c, r in (N.M.part_bound(p.sdf) for p in contents))
check(extent * N.M.DOME_SCALE < building['R'], 'baked exterior contents fit inside the smaller shell')
for k in range(4):
    exterior = json.loads((N.ROOT / 'assets/maps/red_planet' / f'red_planet_map{N.M.view_sfx(k)}.json').read_text())
    check(exterior['domes']['nursery']['radius_world'] <= 160., f'exterior view {k} exports the smaller nursery')
broken = NC.furniture(N, 0)
fixed = NC.furniture(N, 7)
check(not any(p.group in ('console_wire', 'tower_wire') for p in broken), 'no dangling wire bundles')
check(all(p.ramp == 'steel' for p in broken if p.group == 'circulating_water'), 'dry propagation channel is grey')
feed_point = N.M.scale_pt(N.at(-69., 60., 1.), N.C, N.LAYOUT_SCALE)[None, :]
check(any(np.any(p.sdf(feed_point) <= 0) for p in broken if p.group == 'feed0_0'), 'floor feed remains continuous before repairs')
shelf_point = N.M.scale_pt(N.at(18., 144., 30.), N.C, N.LAYOUT_SCALE)[None, :]
check(all(np.all(p.sdf(shelf_point) > 0) for p in broken if p.group == 'living_wall1_shelf1'), 'broken centre shelf sags away from its original position')
check(any(np.any(p.sdf(shelf_point) <= 0) for p in fixed if p.group == 'living_wall1_shelf1'), 'repaired centre shelf returns to its original position')
check(any(p.group == 'console_screen_crack' for p in broken) and
      not any(p.group == 'console_screen_crack' for p in fixed), 'screen fractures disappear after repair')
print(f'NURSERY ART QA: {checks} checks, {len(failures)} failures')
raise SystemExit(1 if failures else 0)
