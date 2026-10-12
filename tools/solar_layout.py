"""Canonical solar field layout shared by the map and equipment generators.

data/solar_field.json owns world positions, optical dimensions, routes and the cable.
Equipment elevations, capped peaks, plateau tops and graded access paths are applied after
original plant generation. SOLAR_FIELD_LAYOUT=v1 retains the previous ground-field layout.
The optical bounds limit escaped rays; they never clear terrain or forest.
No renderer or view state is owned here.
"""
import json
import os

import numpy as np

PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'data', 'solar_field.json')


def load_field():
    path = PATH.replace('.json', '_v1.json') if os.environ.get('SOLAR_FIELD_LAYOUT') == 'v1' else PATH
    with open(path, encoding='utf-8') as stream:
        return json.load(stream)


def mirror_elevation(route, index):
    return route.get('mirror_elevations', [0] * len(route['mirrors']))[index]


def equipment(field):
    """One placement/elevation contract for terrain pads and reachable controls."""
    for route in field['routes']:
        yield route['id'] + ' SUN', route['source'], route.get('source_elevation', 0)
        for index, point in enumerate(route['mirrors']):
            yield route['id'] + str(index + 1), point, mirror_elevation(route, index)


def access_profile(field, X, Y):
    """Blend nearby ramp grades continuously through bends and branching approaches."""
    distance = np.full_like(X, np.inf, dtype=float)
    legs = [(a, b, path['half_width']) for path in field.get('access_paths', [])
            for a, b in zip(path['points'], path['points'][1:])]

    def profile(a, b, width):
        dx, dy = b[0] - a[0], b[1] - a[1]
        t = np.clip(((X - a[0]) * dx + (Y - a[1]) * dy) / (dx * dx + dy * dy), 0, 1)
        za, zb = a[2] if len(a) > 2 else 0, b[2] if len(b) > 2 else 0
        return np.hypot(X - a[0] - t * dx, Y - a[1] - t * dy) - width, za + (zb - za) * t

    for a, b, width in legs:
        np.minimum(distance, profile(a, b, width)[0], out=distance)
    total = np.zeros_like(X, dtype=float)
    heights = np.zeros_like(X, dtype=float)
    for a, b, width in legs:
        leg_distance, grade = profile(a, b, width)
        weight = np.exp(-((leg_distance - distance) / (width * .75)) ** 2)
        total += weight
        heights += grade * weight
    return distance, heights / np.maximum(total, 1e-30)


def apply_terrain(height, material, X, Y):
    """Shape only the authored solar sites; retain the world's original placement stream."""
    field = load_field()

    def blend(distance, target, width=12):
        t = np.clip(distance / width, 0, 1)
        weight = t * t * (3 - 2 * t)
        height[:] = target + (height - target) * weight

    for cap in field.get('terrain', {}).get('peak_caps', []):
        x, y, w, h = cap['bounds']
        distance = np.maximum.reduce([x - X, X - x - w, y - Y, Y - y - h])
        material[(distance <= 0) & (height > cap['height'])] = 1
        blend(distance, np.minimum(height, cap['height']), cap['blend'])
    for plateau in field.get('terrain', {}).get('plateaus', []):
        x, y = plateau['world']
        rx, ry = plateau['half']
        distance = (np.hypot((X - x) / rx, (Y - y) / ry) - 1) * min(rx, ry)
        material[distance <= 0] = 1
        blend(distance, plateau['height'], plateau['blend'])
    x, y = field['collector']['world']
    blend(np.hypot(X - x, Y - y) - field['collector']['radius'] - 8, 0)
    for name, (x, y), elevation in equipment(field):
        if name.endswith('SUN') and elevation and not field.get('terrain'):
            continue  # v1's mountain beacon keeps its natural ground.
        blend(np.hypot(X - x, Y - y) - 26, elevation)
    if field.get('access_paths'):
        path_distance, path_height = access_profile(field, X, Y)
        blend(path_distance, path_height)
        if field.get('terrain'):
            material[path_distance <= 0] = 1  # Reshaped ramps must not retain buried boulder collision.


def mirror_mount(route, field, index=0):
    """Mount bias for free world placement; player yaw still moves in 22.5° steps.

    The same finite-plane normal is used by SolarOptics. Every mirror's fixed pitch
    follows the actual elevation changes; player controls turn only its yaw.
    """
    points = [route['source'], *route['mirrors'], field['collector']['world']]
    heights = [route.get('source_elevation', 0),
               *[mirror_elevation(route, i) for i in range(len(route['mirrors']))], 0]
    before, center, after = (np.array([*p, z], float) for p, z in zip(points[index:index + 3], heights[index:index + 3]))
    incoming, outgoing = center - before, after - center
    incoming /= np.linalg.norm(incoming)
    outgoing /= np.linalg.norm(outgoing)
    normal = incoming - outgoing
    normal /= np.linalg.norm(normal)
    yaw = np.arctan2(-normal[0], normal[1])
    if yaw < 0:
        yaw += np.pi
        normal = -normal
    a = np.arctan2(center[1] - before[1], center[0] - before[0])
    b = np.arctan2(after[1] - center[1], after[0] - center[0])
    control = round((a + b) / (np.pi / 4)) % 8
    bias, pitch = yaw - control * np.pi / 8, np.arcsin(normal[2])
    return (0.0 if abs(bias) < 1e-6 else bias), (0.0 if abs(pitch) < 1e-6 else pitch)


def footprints():
    field = load_field()
    yield (*field['collector']['world'], field['collector']['radius'] + 2)
    for route in field['routes']:
        yield (*route['source'], 9.0)
        for point in route['mirrors']:
            yield (*point, 7.0)
