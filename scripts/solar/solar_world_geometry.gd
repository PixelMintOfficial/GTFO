class_name SolarWorldGeometry
extends RefCounted
## Canonical terrain intersections and an off-screen escape distance for solar rays.
## Walk-grid cells are bilinear height patches: within one cell, ray clearance is quadratic.
## Traverse their exact boundaries and solve that quadratic, so narrow ridges cannot be
## skipped and camera occlusion never substitutes for a physical collision. MapTerrain owns
## height sampling; generated view metadata owns the envelope beyond which no view sees a ray.
## No nodes, current heading or mutable control state. tests/solar_beam_test.gd exercises it.

const TOLERANCE := .001
var _terrain: MapTerrain
var _grid_size: float
var _views: Array[Dictionary] = []


func _init(terrain: MapTerrain) -> void:
	_terrain = terrain
	for path in terrain.views:
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		_grid_size = meta["game"]["grid_size"]
		var size := Vector2(meta["size"][0], meta["size"][1])
		var margin := Vector2(meta["zoom"]["max_view_px"][0], meta["zoom"]["max_view_px"][1])
		_views.append({"origin": Vector2(meta["origin_px"][0], meta["origin_px"][1]),
				"rect": Rect2(-margin, size + margin * 2), "heading": int(meta["game"]["heading"])})


## Long enough to leave every map's image plus its largest viewport. No artificial Z ceiling.
func escape_distance(origin: Vector3, direction: Vector3) -> float:
	var distance := 0.0
	for view in _views:
		var screen := _terrain.to_screen_in_view(Vector2(origin.x, origin.y), origin.z, view["heading"], view["origin"])
		var delta := _terrain.to_screen_direction(direction, view["heading"])
		var rect: Rect2 = view["rect"]
		var exit := INF
		for axis in 2:
			if absf(delta[axis]) > .000001:
				var edge := rect.end[axis] if delta[axis] > 0 else rect.position[axis]
				exit = minf(exit, (edge - screen[axis]) / delta[axis])
		# A ray parallel to this view's sightline projects to a point; the other views
		# still need its full length. It must not turn the common extent into infinity.
		if not is_inf(exit):
			distance = maxf(distance, exit)
	return distance


func _clearance(origin: Vector3, direction: Vector3, distance: float) -> float:
	var p := origin + direction * distance
	return p.z - _terrain.height_at(Vector2(p.x, p.y))


## Earliest root in a bilinear cell's ray interval, or INF when it stays in empty space.
static func _root(start: float, middle: float, end: float) -> float:
	if start <= 0:
		return 0.0
	var a := 2.0 * (start + end - 2.0 * middle)
	var b := end - start - a
	if absf(a) < .00001:
		var t := -start / b if absf(b) > .00001 else INF
		return t if t >= 0 and t <= 1 else INF
	var discriminant := b * b - 4.0 * a * start
	if discriminant < 0:
		return INF
	var result := INF
	for t in [(-b - sqrt(discriminant)) / (2.0 * a), (-b + sqrt(discriminant)) / (2.0 * a)]:
		if t >= 0 and t <= 1:
			result = minf(result, t)
	return result


func surface_distance(origin: Vector3, direction: Vector3, limit: float) -> float:
	var grid := Vector2(origin.x + origin.y, origin.y - origin.x) / sqrt(2.0)
	var delta := Vector2(direction.x + direction.y, direction.y - direction.x) / sqrt(2.0)
	var entry := 0.0
	var exit := limit
	for axis in 2:
		if absf(delta[axis]) < .000001:
			if grid[axis] < 0 or grid[axis] > _grid_size:
				return INF
		else:
			var a := -grid[axis] / delta[axis]
			var b := (_grid_size - grid[axis]) / delta[axis]
			entry = maxf(entry, minf(a, b))
			exit = minf(exit, maxf(a, b))
	var distance := entry
	while distance < exit:
		var next := exit
		var cell := grid + delta * distance - Vector2(.5, .5)
		for axis in 2:
			if absf(delta[axis]) > .000001:
				var boundary := floorf(cell[axis] + TOLERANCE) + 1 if delta[axis] > 0 else ceilf(cell[axis] - TOLERANCE) - 1
				next = minf(next, distance + (boundary - cell[axis]) / delta[axis])
		var start := _clearance(origin, direction, distance)
		var middle := _clearance(origin, direction, (distance + next) * .5)
		var end := _clearance(origin, direction, next)
		var t := _root(start, middle, end)
		if not is_inf(t):
			return lerpf(distance, next, t)
		distance = next
	return INF
