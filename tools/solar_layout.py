"""Canonical solar field layout shared by the map and equipment generators.

data/solar_field.json owns world positions, optical dimensions, routes and the cable.
Small equipment pads and authored access paths are levelled after original plant generation.
The optical bounds limit escaped rays; they never clear terrain or forest.
No renderer or view state is owned here.
"""
import json
import os

import numpy as np

PATH = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'data', 'solar_field.json')


def load_field():
    with open(PATH, encoding='utf-8') as stream:
        return json.load(stream)


def pad_distance(X, Y):
    field = load_field()
    centers = [(*field['collector']['world'], field['collector']['radius'] + 8)]
    for route in field['routes']:
        if not route.get('source_elevation', 0):
            centers.append((*route['source'], 26))
        centers.extend((*point, 26) for point in route['mirrors'])
    distances = [np.hypot(X - x, Y - y) - radius for x, y, radius in centers]
    for path in field.get('access_paths', []):
        for a, b in zip(path['points'], path['points'][1:]):
            dx, dy = b[0] - a[0], b[1] - a[1]
            t = np.clip(((X - a[0]) * dx + (Y - a[1]) * dy) / (dx * dx + dy * dy), 0, 1)
            distances.append(np.hypot(X - a[0] - t * dx, Y - a[1] - t * dy) - path['half_width'])
    return np.minimum.reduce(distances)


def mirror_mount(route, field, index=0):
    """Mount bias for free world placement; player yaw still moves in 22.5° steps.

    The same finite-plane normal is used by SolarOptics. Only the first mirror of an
    elevated route has pitch; the fixed yaw bias permits routes to follow the landscape.
    """
    points = [route['source'], *route['mirrors'], field['collector']['world']]
    before, center, after = (np.array(p, float) for p in points[index:index + 3])
    elevation = route.get('source_elevation', 0) if index == 0 else 0
    incoming = np.array([*(center - before), -elevation])
    outgoing = np.array([*(after - center), 0])
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
