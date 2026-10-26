"""Native interior artwork must lose outside light at night, without sealing glass.

Checks all four views/machine variants and every glass-repair combination. The
sunlight-free reference may change near a repaired window, never along a former
beam on the wall/floor. Daylight still changes far below a sealed pane.
Run after make interior; generated PNGs are inspected, never modified.
"""
import json
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / 'assets/maps/base_interior'


def rgb(path):
    return np.array(Image.open(path).convert('RGB'))


def composite(base, root, info, key):
    result = base.copy()
    patch = np.array(Image.open(root / info[key]).convert('RGBA'))
    x, y = info['position']
    h, w = patch.shape[:2]
    select = patch[..., 3] > 0
    result[y:y+h, x:x+w][select] = patch[..., :3][select]
    return result


class NightSunlight(unittest.TestCase):
    def test_no_window_beams_in_any_night_state(self):
        daylight_floor_changed = 0
        for folder in ['', 'repaired_power', 'repaired_oxygen', 'repaired_both']:
            root = ROOT / folder
            for view in range(4):
                suffix = f'_r{view}' if view else ''
                meta = json.loads((root / f'base_interior{suffix}.json').read_text())
                day = rgb(root / meta['image'])
                night = rgb(root / meta['game']['no_sun_png'])
                self.assertEqual(night.shape, day.shape)
                windows = np.zeros(day.shape[:2], bool)
                bottom = 0
                for pane in meta['window_cracks']:
                    if not pane.get('patch'):
                        continue
                    info = pane['patch']
                    patch = Image.open(root / info['file'])
                    other = Image.open(root / info['no_sun'])
                    self.assertEqual(patch.size, other.size)
                    self.assertTrue(np.array_equal(np.array(patch)[..., 3], np.array(other)[..., 3]))
                    x, y = info['position']
                    w, h = patch.size
                    windows[max(0,y-3):y+h+3, max(0,x-3):x+w+3] = True
                    bottom = max(bottom, y+h+4)
                self.assertGreater(np.count_nonzero(np.any(day != night, axis=-1) & ~windows), 500)
                for info in meta['window_restorations']:
                    if 'file' not in info:
                        continue
                    repaired = composite(night, root, info, 'no_sun')
                    changed = np.any(repaired != night, axis=-1)
                    self.assertEqual(np.count_nonzero(changed & ~windows), 0,
                                     f'{folder} view {view} panes {info["panes"]}: outside light at night')
                    repaired_day = composite(day, root, info, 'file')
                    daylight_floor_changed += np.count_nonzero(np.any(repaired_day[bottom:] != day[bottom:], axis=-1))
        self.assertGreater(daylight_floor_changed, 1000, 'daylight still casts beams under unrepaired glass')


if __name__ == '__main__':
    unittest.main()
