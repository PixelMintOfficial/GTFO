#!/usr/bin/env python3
"""Generate the native cultivation sprites, per-pixel depth/glow and inventory icons.

Writes assets/cultivation/: four-view character-height wild Moonwell/Cindercoil
sheets and cultivation.json; nursery_gen calls export_beds for its crop overlays.
Colour and RG16 local view depth come from the exact same native ray-march frame.
The centre rack and left silo have separate broken-dead poses matching their loose shelves.
Data B is emissive coverage. Runtime crop_depth samples it against MapStream's
depth window, so leaves sit behind racks, cliffs, glass and the astronaut correctly.
Run through make cultivation; importing writes nothing.
"""
from pathlib import Path
import json
import numpy as np
from PIL import Image
from scipy import ndimage as ndi
import cultivation_models as C

M, I, A, P = C.M, C.I, C.A, C.P
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/cultivation'
DEPTH_OFFSET, DEPTH_SCALE = 64., 512.


def sheet(frames, root, name, anchor_world=np.zeros(3), view=0, about=np.zeros(3)):
    root = Path(root)
    M.VIEW = view
    M.AX, M.AY = 0., 0.
    frames = [M.turned(parts, about=about, k=view) for parts in frames]
    bounds = M.sprite_box(frames, pad=3)
    world = M.TurnZ(A.Sphere(anchor_world, .1), view, about).fwd(anchor_world)
    anchor = np.asarray(M.project(*world)) - bounds[:2]
    colours, data, glow = [], [], []
    for parts in frames:
        frame = M.render_sprite(parts, bounds)
        colour = M.sprite_rgba(frame)
        covered = frame['filled'] | frame['ring']
        depth = frame['D'].copy()
        # Outline pixels inherit their nearest solid surface's depth.
        nearest = ndi.distance_transform_edt(~frame['filled'], return_distances=False, return_indices=True)
        depth[~frame['filled']] = depth[tuple(nearest[:, ~frame['filled']])]
        encoded = np.round((depth - world[1] + DEPTH_OFFSET) * DEPTH_SCALE)
        if np.any(covered & ((encoded < 0) | (encoded > 65535))):
            raise ValueError(f'{name}: crop exceeds local-depth encoding')
        encoded = np.where(covered, np.clip(encoded, 0, 65535), 0).astype(np.uint32)
        mask = np.zeros((*depth.shape, 4), np.uint8)
        mask[..., 0], mask[..., 1] = encoded >> 8, encoded & 255
        mask[..., 2], mask[..., 3] = frame['emit'], covered * 255
        colours.append(colour)
        data.append(mask)
        lit = colour.copy()
        lit[..., 3] = np.minimum(lit[..., 3], frame['emit'])
        glow.append(lit)
    filename, depth_file = f'{name}.png', f'{name}_data.png'
    M.save_png(Image.fromarray(np.concatenate(colours, axis=1)), str(root / filename))
    M.save_png(Image.fromarray(np.concatenate(data, axis=1)), str(root / depth_file))
    info = dict(file=filename, data=depth_file, frames=len(frames), frame_size=list(bounds[2:]),
                anchor=anchor.tolist(), depth_offset=DEPTH_OFFSET, local_depth_scale=DEPTH_SCALE)
    if any(np.any(image[..., 3]) for image in glow):
        info['glow'] = f'{name}_glow.png'
        M.save_png(Image.fromarray(np.concatenate(glow, axis=1)), str(root / info['glow']))
    return info


def wild_parts(species, opening, available, scale):
    if species == 'moonwell':
        parts = C.moonwell(np.zeros(3), opening)
        if not available:
            parts = [p for p in parts if p.name != 'viable_seed']
    else:
        parts = C.cindercoil(np.zeros(3), 'ripe' if available else 'gathered')
    return M.scaled(parts, np.zeros(3), scale, species)


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'icons').mkdir(exist_ok=True)
    config = json.loads((ROOT / 'data/cultivation.json').read_text())
    result = dict(wild={}, icons={}, character_height=22., bloom_frames=9)
    M.SUN = A.nz([-.62, -.32, .62])
    original_emissive = M.EMISSIVE.copy()
    for species in ('cindercoil', 'moonwell'):
        result['wild'][species] = []
        M.EMISSIVE.clear()
        M.EMISSIVE.update(original_emissive)
        if species == 'moonwell':
            M.EMISSIVE.add(M.OID['puff'])
        frames = [wild_parts(species, f / 8., available, config['wild_scale'][species])
                  for available in (True, False) for f in (range(9) if species == 'moonwell' else (0,))]
        for k in range(4):
            info = sheet(frames, OUT, f'{species}{M.view_sfx(k)}', view=k)
            result['wild'][species].append(info)
        print(species, 'four native views generated', flush=True)
    M.EMISSIVE.clear()
    M.EMISSIVE.update(original_emissive)
    for kind, parts in [
        ('emberpod_seed', C.seeds(np.zeros(3), 'food')),
        ('dewpod_seed', C.seeds(np.zeros(3), 'water')),
        ('emberpod', C.ember_fruit(np.array([0., 0., 3.]), 2.7)),
        ('dewpod', C.dew_fruit(np.array([0., 0., 3.]), 2.6)),
    ]:
        M.AX = M.AY = 0.
        frame = M.render_sprite(parts, M.sprite_box([parts], pad=1))
        icon = Image.fromarray(M.sprite_rgba(frame))
        icon = icon.crop(icon.getbbox())
        if icon.width > 28 or icon.height > 28:
            raise ValueError(f'{kind}: inventory icon must fit its native slot')
        filename = f'icons/{kind}.png'
        M.save_png(icon, str(OUT / filename))
        result['icons'][kind] = filename
    M.save_text(json.dumps(result, indent=2), str(OUT / 'cultivation.json'))
    print('cultivation art generated ->', OUT, flush=True)


def export_beds(N):
    """Native crops only, with a shared root anchor for every stage/view of each bed."""
    N.setup_room()
    root = N.OUT / 'crops'
    root.mkdir(exist_ok=True)
    original = N.rosette
    frames = {key: [] for key in ('rack0', 'rack1', 'rack2', 'silo0', 'silo1')}
    for stage in ('dead', 'sprout', 'ripe', 'broken_dead'):
        def rosette(c, size, seed, group, flower=False):
            if group.startswith('living_wall'):
                bed, kind = 'rack' + group[len('living_wall')], 'food'
            elif group.startswith('light_tower'):
                bed, kind = 'silo' + group[len('light_tower')], 'water'
            else:
                return []
            fn = C.emberplant if kind == 'food' else C.dewplant
            parts = fn(c, size, seed, group, 'dead' if stage == 'broken_dead' else stage)
            for p in parts:
                p.group = f'{bed}:{p.group}'
                if stage == 'broken_dead' and 'light_tower0_tier2' in group:
                    moved = C.pose(p, N.at(-123, 6, 45), A.rx(.4) @ A.rz(.13), (5., -3., -6.))
                    p.sdf = moved.sdf
                if stage == 'broken_dead' and group.startswith('living_wall1_plant1_'):
                    p.sdf = C.rack_damage_pose(p, N.at(0., 155.)).sdf
            return parts
        N.rosette = rosette
        parts = N.rear_gardens()
        for bed in frames:
            if stage == 'broken_dead' and bed not in ('silo0', 'rack1'):
                continue
            selected = [P(p.name, M.Scaled(p.sdf, N.C, N.LAYOUT_SCALE), p.ramp, p.group, p.decal)
                        for p in parts if p.group.startswith(bed + ':')]
            frames[bed].append(selected)
    N.rosette = original
    entries = []
    for j, deg in enumerate((69., 90., 111.)):
        angle = np.radians(deg)
        point = N.at(np.cos(angle) * 155., np.sin(angle) * 155.)
        stand = N.at(np.cos(angle) * 119., np.sin(angle) * 119.)
        entries.append(dict(id=f'rack{j}', kind='food', root=point, stand=stand))
    for j, (x, y) in enumerate(N.TOWERS):
        entries.append(dict(id=f'silo{j}', kind='water', root=N.at(x, y),
                            # The left approach also clears the unrepaired dropped light.
                            stand=N.at(x + (29. if x < 0 else -32.), y - (8. if x < 0 else 5.))))
    for entry in entries:
        anchor = M.scale_pt(entry.pop('root'), N.C, N.LAYOUT_SCALE)
        stand = M.scale_pt(entry.pop('stand'), N.C, N.LAYOUT_SCALE)
        entry.update(world=anchor[:2].tolist(), stand_world=stand[:2].tolist(), views=[])
        for k in range(4):
            info = sheet(frames[entry['id']], root, f"{entry['id']}{M.view_sfx(k)}", anchor, k, N.C)
            info['file'], info['data'] = 'crops/' + info['file'], 'crops/' + info['data']
            if 'glow' in info:
                info['glow'] = 'crops/' + info['glow']
            entry['views'].append(info)
    M.save_text(json.dumps(dict(beds=entries), indent=2), str(N.OUT / 'crops.json'))
    N.setup_room()
    print('five nursery crop beds generated in four views', flush=True)


if __name__ == '__main__':
    np.seterr(all='ignore')
    build()
