"""Physical generator regression for the power repair's cabinet and battery feed.

Run with .venv/Scripts/python.exe tests/test_power_restore.py. Uses the actual authored
fixtures and SDFs: the torn feed has a gap before repair, and the open cabinet has no
closed white cover. Restoration must seal the cover and connect the cable end to end.
No images are written; native repair tests cover the live completion/variant switch.
"""
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import interior_gen as interior


class PowerRestorationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rng = np.random.default_rng(77)
        interior.storage_props(rng)
        cls.broken, center, _ = interior.power_props(rng)
        cls.repaired = interior.restore_power(cls.broken, center)

    def test_battery_feed_has_no_gap_after_repair(self):
        feed = next(p.sdf for p in self.broken if p.name == 'cable' and p.group == 'cable3')
        battery = next(p.sdf for p in self.broken if p.name == 'cabinet' and p.group == 'cab3')
        end = battery.c.copy()
        end[2] = .9
        route = feed.b[None, :] + np.linspace(0, 1, 81)[:, None] * (end - feed.b)

        def distances(parts):
            cables = [p.sdf(route) for p in parts if p.group.startswith('cable3')]
            return np.min(cables, axis=0)

        self.assertGreater(distances(self.broken).max(), 3, 'fixture must expose the original torn cable gap')
        self.assertLess(distances(self.repaired).max(), 0, 'restored cable must reach its battery continuously')

    def test_service_cover_closes_over_the_whole_opening(self):
        cabinet = next(p.sdf for p in self.broken if p.name == 'svc')
        local = np.array([[x, -3.8, z] for x in (-5, 0, 5) for z in (-6, 0, 6)])
        probes = cabinet.c + local @ cabinet.R.T

        def cover_distances(parts):
            covers = [p.sdf(probes) for p in parts if p.name.startswith('svc') and p.ramp in ('white', 'coral')]
            return np.min(covers, axis=0)

        self.assertGreater(cover_distances(self.broken).max(), .3, 'fixture must have an open service cover')
        self.assertLess(cover_distances(self.repaired).max(), -.1, 'closed cover must span the exposed board')
        self.assertFalse(any(p.group == 'pcb' or p.group.startswith(('pcbw', 'cable3w'))
                             or p.name == 'cableend' for p in self.repaired), 'bare damaged leads must be stowed')


if __name__ == '__main__':
    unittest.main()
