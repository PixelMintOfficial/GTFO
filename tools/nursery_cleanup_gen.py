#!/usr/bin/env python3
"""Native removable nursery/base floor litter, independent of room repair variants.

Uses the cultivation colour/depth exporter and the existing soil/wood/steel ramps.
Four views and four diminishing pile frames share canonical, reachable floor anchors.
No map PNG is painted over; NurseryCleanup removes these overlays as UNIT vacuums.
"""
from pathlib import Path
import json
import math
import numpy as np
from PIL import Image
import nursery_gen as N
import cultivation_gen as Art

M, A, P = Art.M, Art.A, Art.P
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/maps/nursery_interior/cleanup'


def floor_site(world, walk):
    """Keep litter on a clear patch of the actual final walk grid, with room for the bot."""
    for radius in (0., 3., 6., 9., 12., 16.):
        for angle in np.arange(16) * math.tau / 16:
            q = world + radius * np.array([math.cos(angle), math.sin(angle)])
            clear = True
            for off in ((0, 0), (4, 0), (-4, 0), (0, 4), (0, -4)):
                x, y = q + off
                u, v = int((x+y)/math.sqrt(2)), int((y-x)/math.sqrt(2))
                clear &= 0 <= u < walk.shape[1] and 0 <= v < walk.shape[0] and walk[v,u,2] == 255
            if clear: return q
    raise ValueError(f'No clear nursery cleaning floor near {world}')


def pile(seed):
    rng = np.random.default_rng(seed)
    parts = []
    for i in range(26):
        x, y = rng.normal(0., 3., 2)
        kind = i % 4
        shape = A.Ellipsoid((x, y, .14), (rng.uniform(.5, 1.4), rng.uniform(.3, .75), .14), A.rz(rng.uniform(0, math.tau)))
        parts.append(P('soil' if kind < 2 else 'leaf' if kind == 2 else 'tray_chip', shape,
                       'soil' if kind < 2 else 'wood' if kind == 2 else 'steel', 'nursery_litter'))
    return parts


def build_room(meta_path, out, worlds, prefix):
    out.mkdir(parents=True, exist_ok=True)
    meta = json.loads(meta_path.read_text(encoding='utf-8'))
    walk = np.asarray(Image.open(meta_path.parent / meta['game']['walk_png']).convert('RGB'))
    M.SUN = N.I.SUN_IN
    sites = []
    for index, world in enumerate(worlds):
        world = floor_site(world, walk)
        parts = pile(3140 + index)
        frames = [parts[:max(3, round(len(parts) * fraction))] for fraction in (1., .7, .4, .15)]
        views = [Art.sheet(frames, out, f'pile_{index}{M.view_sfx(k)}', view=k) for k in range(4)]
        sites.append(dict(id=f'{prefix}litter_{index}', world=world.tolist(), views=views))
    M.save_text(json.dumps(dict(sites=sites, clean_seconds=4.5), indent=2), str(out / 'cleanup.json'))
    print(f'{meta_path.stem} cleanup: {len(sites)} reachable litter piles, four native views', flush=True)


def build():
    worlds = [N.C[:2] + np.array(q)*N.LAYOUT_SCALE for q in
              ((-48,-78),(44,-46),(12,62),(-60,48),(65,25),(-32,112))]
    build_room(N.OUT / 'nursery.json', OUT, worlds, '')
    base = ROOT / 'assets/maps/base_interior'
    rooms = N.I.ROOMS
    worlds = [np.array([rooms[room]['X']+x, rooms[room]['Y']+y]) for room,x,y in
              [('storage',-55,20),('storage',48,-8),('storage',18,-63),
               ('oxygen',-25,-35),('oxygen',25,42),('power',-22,-42)]]
    build_room(base / 'base_interior.json', base / 'cleanup', worlds, 'base_')


if __name__ == '__main__':
    build()
