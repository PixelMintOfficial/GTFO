"""Full base lighting, derived from the existing four-view geometry and depth.

make base-power exports compact RGB masks beside the map: R is illumination,
G is the existing glass's teal emission, B is emission after glass restoration.
Both emission channels include the same outward window spill on nearby ground.
Reuse mars_map_gen's actual sphere/band/hex/hole geometry, projection and Bayer
dither. Saved depth rejects hidden surfaces; no terrain, approved art or tiles
are rewritten. Run after make map; this is a separate, cheap derived export.
The runtime samples in map pixels, independently of the streamed map window.
Tests: tests/test_base_power_art.py; native tests/base_power_test.tscn gallery.
"""
import json
import os

import numpy as np
from PIL import Image

import mars_map_gen as M


SPILL_REACH = 100.0                  # world units beyond each dome's footing


def window_spill(points, dome):
    """Diffuse window-band light around the entire footprint, before view occlusion.

    Saved depth supplies the receiving surface, so the pool follows terrain and cannot
    paint over a foreground dome. A broad height falloff includes the uneven apron;
    the original narrow, 18-unit slab cut most of the visible spill off.
    """
    delta = points - np.array([dome['X'], dome['Y'], dome['Z']])
    radius = np.linalg.norm(delta[..., :2], axis=-1)
    outward = np.maximum(radius - dome['R'], 0)
    fade = np.clip(1 - outward / SPILL_REACH, 0, 1) ** 2
    height = np.clip(1 - np.maximum(np.abs(delta[..., 2]) - 12, 0) / 48, 0, 1)
    return fade * height * (radius >= dome['R'] - 8)


def build():
    root = os.path.join(M.OUT, 'power')
    os.makedirs(root, exist_ok=True)
    catalog = []
    for heading in range(4):
        M.VIEW, M.SFX = heading, M.view_sfx(heading)
        M.apply_view_constants(heading)
        with open(os.path.join(M.OUT, f'red_planet_map{M.SFX}.json')) as source:
            meta = json.load(source)
        M.W, M.H = meta['size']
        M.AX, M.AY = meta['origin_px']
        units = [d for d in M.dome_units() if d['owner'] == 'base']
        centers = [np.array([d['X'], d['Y'], d['Z']]) for d in units]
        boxes = [(M.project(*c), (d['R'] + SPILL_REACH + 6) / M.S) for c, d in zip(centers, units)]
        x0 = max(0, int(min(p[0] - r for p, r in boxes)))
        x1 = min(M.W, int(max(p[0] + r for p, r in boxes)) + 1)
        y0 = max(0, int(min(p[1] - r for p, r in boxes)))
        y1 = min(M.H, int(max(p[1] + r for p, r in boxes)) + 1)
        depth = np.array(Image.open(os.path.join(M.OUT, meta['game']['depth_png'])).crop((x0, y0, x1, y1)))
        raw = depth[..., 0].astype(np.uint32) * 256 + depth[..., 1]
        yv = raw / meta['game']['depth_scale']
        yy, xx = np.mgrid[y0:y1, x0:x1]
        xv = (xx + .5 - M.AX) * M.S
        zv = (M.AY - yy - .5) / M.PX - M.KY * yv
        points = np.stack([xv, yv, zv], -1)
        ambient = np.zeros(raw.shape)
        emission = np.zeros(raw.shape)
        restored = np.zeros(raw.shape)
        for d, center in zip(units, centers):
            delta = points - center
            distance = np.linalg.norm(delta, axis=-1)
            # Every window faces outward. Illuminate the visible receiving surface,
            # including the baked solar shadow, with the glass's existing teal ramp.
            spill = window_spill(points, d)
            ambient = np.maximum(ambient, spill * .68)
            emission = np.maximum(emission, spill * .22)
            restored = np.maximum(restored, spill * .22)
            shell = (np.abs(distance - d['R']) < .28) & (delta[..., 2] >= 0) & (raw != 65535)
            if not shell.any():
                continue
            # Quantized depth is within .1 unit of the original shell sample.
            q = center + delta[shell] / distance[shell, None] * d['R']
            layers = M.band_layers(q, center, d)
            glass = layers['glass']
            intact = glass | layers['hole']
            a = np.where(intact, .92, .52)
            a[layers['frame'] | layers['trim']] = .72
            ambient[shell] = np.maximum(ambient[shell], a)
            e = np.where(glass, .40, 0.0)
            # Keep the original damage readable; light alone does not mend windows.
            for key in ('rim', 'crack', 'crack_shade'):
                e[layers[key]] = 0
            e[layers['trim']] = .055
            emission[shell] = np.maximum(emission[shell], e)
            restored[shell] = np.maximum(restored[shell], np.where(intact, .40, e))
        # Lit corridors connect the three dome footprints. Only their low structure.
        for ia, ib in M.BASE_LINKS:
            a, b = centers[ia], centers[ib]
            ab = b[:2] - a[:2]
            t = np.clip(np.sum((points[..., :2] - a[:2]) * ab, axis=-1) / np.dot(ab, ab), 0, 1)
            dist = np.linalg.norm(points[..., :2] - a[:2] - t[..., None] * ab, axis=-1)
            corridor = (dist < 18) & (zv >= a[2] - 2) & (zv < a[2] + 50)
            ambient[corridor] = np.maximum(ambient[corridor], .52)
        for layer in (ambient, emission, restored):
            layer[raw == 65535] = 0
        # Ordered steps, matching the existing lighting effects (no blurred silhouettes).
        bay = M.BAYER[yy % 4, xx % 4]
        ambient = np.floor(ambient * 12 + bay * .95) / 12
        rgb = np.round(np.stack([ambient, emission, restored], -1) * 255).clip(0, 255).astype(np.uint8)
        name = f'base{M.SFX}.png'
        M.save_png(Image.fromarray(rgb), os.path.join(root, name))
        catalog.append(dict(file=name, rect=[x0, y0, x1-x0, y1-y0]))
        print(f'base power view {heading}: {x1-x0}x{y1-y0}, {np.count_nonzero(ambient)} lit pixels')
    M.save_text(json.dumps(dict(views=catalog), indent=2), os.path.join(root, 'catalog.json'))
    M.VIEW = 0
    M.apply_view_constants(0)


if __name__ == '__main__':
    build()
