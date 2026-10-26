"""Generated base/nursery-light masks: geometry coverage, crop safety and four-view ownership.
Window spill must reach every azimuth evenly, fade outward and survive terrain height.
Run after make base-power; masks never replace or brighten the rest of the planet.
"""
import json
import sys
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import mars_map_gen as M
import base_power_gen as P


class BasePowerArt(unittest.TestCase):
    def test_even_window_spill(self):
        dome = dict(X=0., Y=0., Z=0., R=100.)
        angle = np.arange(32) * np.pi / 16
        for offset in (10., 35., 65.):
            r = dome['R'] + offset
            points = np.stack([r*np.cos(angle), r*np.sin(angle), np.zeros(32)], -1)
            light = P.window_spill(points, dome)
            np.testing.assert_allclose(light, light[0], atol=1e-12)
            self.assertGreater(light.min(), 0)
        self.assertGreater(P.window_spill(np.array([125., 0., 22.]), dome), .4)
        self.assertEqual(P.window_spill(np.array([201., 0., 0.]), dome), 0.)
        self.assertEqual(P.window_spill(np.array([0., 0., 120.]), dome), 0.)

    def test_four_geometry_masks(self):
        root = ROOT / 'assets/maps/red_planet'
        catalog = json.loads((root / 'power/catalog.json').read_text())
        for owner, key in [('base', 'views'), ('nursery', 'nursery_views')]:
            self.assertEqual(len(catalog[key]), 4)
            self._check_region(root, catalog[key], owner)

    def _check_region(self, root, views, owner):
        for k, info in enumerate(views):
            M.VIEW = k
            M.apply_view_constants(k)
            meta = json.loads((root / f'red_planet_map{M.view_sfx(k)}.json').read_text())
            x, y, w, h = info['rect']
            image = Image.open(root / 'power' / info['file'])
            self.assertEqual(image.mode, 'RGB')
            self.assertEqual(image.size, (w, h))
            self.assertGreaterEqual(min(x, y), 0)
            self.assertLessEqual(x+w, meta['size'][0])
            self.assertLessEqual(y+h, meta['size'][1])
            self.assertLess(w*h, meta['size'][0]*meta['size'][1]//8)
            rgb = np.array(image)
            depth = np.array(Image.open(root / meta['game']['depth_png']).crop((x, y, x+w, y+h)))
            raw = depth[..., 0].astype(np.uint32)*256 + depth[..., 1]
            yy, xx = np.mgrid[y:y+h, x:x+w]
            M.AX, M.AY = meta['origin_px']
            yv = raw / meta['game']['depth_scale']
            points = np.stack([(xx+.5-M.AX)*M.S, yv, (M.AY-yy-.5)/M.PX-M.KY*yv], -1)
            self.assertGreater(np.count_nonzero(rgb[..., 0]), 100000)
            self.assertGreater(np.count_nonzero(rgb[..., 1]), 15000)
            self.assertTrue(np.all(rgb[..., 2] >= rgb[..., 1]))
            self.assertEqual(np.count_nonzero(rgb[0]) + np.count_nonzero(rgb[-1]), 0)
            self.assertEqual(np.count_nonzero(rgb[:, 0]) + np.count_nonzero(rgb[:, -1]), 0)
            self.assertFalse(np.any(rgb[raw == 65535]))
            for d in M.dome_units():
                if d['owner'] != owner:
                    continue
                M.AX, M.AY = meta['origin_px']
                px, py = M.project(d['X'], d['Y'], d['Z']+d['R']*.7)
                patch = rgb[max(0,int(py)-y-20):int(py)-y+20, max(0,int(px)-x-20):int(px)-x+20, 0]
                self.assertGreater(patch.max(), 100, f'view {k} room {d["name"]} lit')
                delta = points - np.array([d['X'], d['Y'], d['Z']])
                radius = np.linalg.norm(delta[..., :2], axis=-1)
                ground = (radius > d['R']+20) & (radius < d['R']+45) & (np.abs(delta[..., 2]) < 12) & (raw != 65535)
                self.assertGreater(ground.sum(), 100, f'view {k} room {d["name"]}: visible apron')
                self.assertGreater(np.median(rgb[..., 0][ground]), 40, f'view {k} room {d["name"]}: outward illumination')
                self.assertGreater(np.median(rgb[..., 1][ground]), 15, f'view {k} room {d["name"]}: reflected window colour')
                np.testing.assert_array_equal(rgb[..., 1][ground], rgb[..., 2][ground])


if __name__ == '__main__':
    unittest.main()
