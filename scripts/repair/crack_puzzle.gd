class_name CrackPuzzle
extends RefCounted
## Untimed scrap welding model. Three generator-authored sites on the machine panel;
## placement covers every hole/fracture sample with a 2px margin. Each perimeter needs
## 95% weld coverage. Fast strokes leave gaps; ~3s lingering overheats a small local weld.
## Coordinates are logical repair-panel pixels. No inventory mutation here.
## Uses the draft's chipped plates, enlarged 12%, and its persistent hand-stroke weld deposits.
## Reference panels supply actual damage samples; legacy panels use procedural contours.
## Test hooks: place(), stroke(), cool(), coverage(), solved(), advance_visuals().

const SCRAP_COST := 3
const REQUIRED_COVERAGE := 0.95
const BRUSH := 3.0
const FAST_SPEED := 110.0
const SLOW_SPEED := 30.0
const MARGIN := 2.0
const DAMAGE_SCALE := 1.12

var sites := PackedVector2Array()
var holes: Array[PackedVector2Array] = []
var fractures: Array = [] # two tapered 2D fracture polygons branching from each aperture
var damage_samples: Array[PackedVector2Array] = [] # local offsets measured from source PNG
var shapes: Array[PackedVector2Array] = []
var placed := PackedInt32Array([-1, -1, -1])
var positions := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
var seams: Array[PackedVector2Array] = []
var welded: Array[PackedByteArray] = []
var ages: Array[PackedFloat32Array] = []
var sealed := PackedByteArray([0, 0, 0])
var glow := PackedFloat32Array([0, 0, 0])
var heat := 0.0
var overheated := false
var deposits: Dictionary = {} # rounded pixel -> [position, tangent, stroke arc, age, hole]
var _distance := 0.0
var _last_deposit_arc := -2.0
var _direction := Vector2.RIGHT


func _init(points := PackedVector2Array()) -> void:
	sites = points
	var silhouettes := [
		[-34,-8, -24,-23, -15,-20, -7,-29, 9,-24, 17,-27, 31,-13, 27,-5, 35,5, 30,9, 26,22, 5,19, -5,25, -22,18, -19,12, -31,6, -26,1],
		[-30,-15, -20,-27, -2,-20, 5,-25, 24,-19, 31,-5, 25,-1, 33,8, 24,16, 20,29, 4,23, -4,26, -17,20, -28,17, -24,9, -33,2, -27,-4],
		[-37,-7, -30,-20, -18,-18, -12,-26, 4,-24, 11,-18, 24,-21, 32,-8, 27,-1, 35,9, 23,18, 16,15, 9,27, -6,21, -11,25, -28,15, -25,8, -36,4, -29,0]]
	var apertures := [
		[-16,-8, -6,-12, 1,-7, 12,-11, 16,-2, 10,3, 14,9, 2,10, -4,6, -14,8, -12,0],
		[-15,-4, -10,-11, 0,-8, 9,-12, 16,-3, 11,5, 4,7, -1,12, -12,9, -8,2],
		[-18,-6, -7,-11, 3,-8, 13,-10, 16,-1, 10,4, 15,8, 1,11, -8,5, -16,9, -13,1]]
	var gashes := [
		[[-12,-4, -22,-9, -18,-10, -10,-6], [7,7, 15,15, 11,12, 4,7]],
		[[9,-6, 21,-13, 17,-8, 10,-3], [-10,7, -20,13, -17,9, -8,4]],
		[[10,0, 23,5, 17,6, 8,3], [-6,-8, -12,-17, -8,-12, -2,-6]]]
	for i in SCRAP_COST:
		shapes.append(_contour(silhouettes[i]))
		holes.append(_contour(apertures[i]))
		var branches: Array[PackedVector2Array] = []
		for gash in gashes[i]:
			branches.append(_contour(gash))
		fractures.append(branches)
		seams.append(PackedVector2Array())
		welded.append(PackedByteArray())
		ages.append(PackedFloat32Array())


static func _contour(coordinates: Array) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	for i in range(0, coordinates.size(), 2):
		polygon.append(Vector2(coordinates[i], coordinates[i + 1]) * DAMAGE_SCALE)
	return polygon


func available(piece: int) -> bool:
	return piece >= 0 and piece < SCRAP_COST and not placed.has(piece)


## Preserve partial work if the inspection layout changes or is reopened.
func relocate(points: PackedVector2Array) -> void:
	var shifted := {}
	for deposit: Array in deposits.values():
		var hole: int = deposit[4]
		deposit[0] += points[hole] - sites[hole]
		shifted[Vector2i(deposit[0].round())] = deposit
	deposits = shifted
	for i in mini(sites.size(), points.size()):
		var offset := points[i] - sites[i]
		if placed[i] >= 0:
			positions[i] += offset
			seams[i] = translated(seams[i], offset)
	sites = points


static func _edge_margin(point: Vector2, polygon: PackedVector2Array) -> float:
	if not Geometry2D.is_point_in_polygon(point, polygon):
		return -1
	var distance := INF
	for i in polygon.size():
		distance = minf(distance, Geometry2D.get_closest_point_to_segment(point, polygon[i], polygon[(i + 1) % polygon.size()]).distance_to(point))
	return distance


func can_place(piece: int, at: Vector2, hole: int) -> bool:
	at = at.round()
	if not available(piece) or hole < 0 or hole >= sites.size() or placed[hole] >= 0:
		return false
	var polygon := translated(shapes[piece], at)
	if not damage_samples.is_empty():
		for sample in damage_samples[hole]:
			if _edge_margin(sites[hole] + sample, polygon) < MARGIN:
				return false
	var contours: Array = [holes[hole]]
	contours.append_array(fractures[hole])
	for contour: PackedVector2Array in contours if damage_samples.is_empty() else []:
		for edge in contour.size():
			var a := contour[edge]
			var b := contour[(edge + 1) % contour.size()]
			var steps := maxi(1, ceili(a.distance_to(b)))
			for sample in steps:
				var point := sites[hole] + a.lerp(b, float(sample) / steps)
				if not Geometry2D.is_point_in_polygon(point, polygon):
					return false
				for j in polygon.size():
					if Geometry2D.get_closest_point_to_segment(point, polygon[j], polygon[(j + 1) % polygon.size()]).distance_to(point) < MARGIN:
						return false
	for i in SCRAP_COST:
		if placed[i] >= 0 and not Geometry2D.intersect_polygons(polygon, translated(shapes[placed[i]], positions[i])).is_empty():
			return false
	return true


func place(piece: int, at: Vector2) -> int:
	for i in sites.size():
		if not can_place(piece, at, i):
			continue
		placed[i] = piece
		positions[i] = at.round()
		var polygon := translated(shapes[piece], positions[i])
		var points := PackedVector2Array()
		for j in polygon.size():
			var a := polygon[j]
			var b := polygon[(j + 1) % polygon.size()]
			var steps := maxi(1, ceili(a.distance_to(b)))
			for s in steps:
				points.append(a.lerp(b, float(s) / steps))
		seams[i] = points
		welded[i].resize(points.size())
		welded[i].fill(0)
		ages[i].resize(points.size())
		ages[i].fill(99.0)
		return i
	return -1


static func translated(shape: PackedVector2Array, at: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in shape:
		out.append(p + at)
	return out


func coverage(hole: int) -> float:
	if welded[hole].is_empty():
		return 0.0
	var count := 0
	for value in welded[hole]:
		count += value
	return float(count) / welded[hole].size()


func solved() -> bool:
	return sealed[0] == 1 and sealed[1] == 1 and sealed[2] == 1


func on_perimeter(point: Vector2) -> int:
	for i in seams.size():
		for sample in seams[i]:
			if sample.distance_squared_to(point) <= BRUSH * BRUSH:
				return i
	return -1


## Returns true only when this stroke actually contacts a seam (for synchronized sparks).
func stroke(from: Vector2, to: Vector2, delta: float) -> bool:
	if delta <= 0 or solved():
		return false
	var travel := from.distance_to(to)
	var speed := travel / delta
	if overheated:
		return false
	var contact := false
	for seam in seams:
		for point in seam:
			if Geometry2D.get_closest_point_to_segment(point, from, to).distance_to(point) <= BRUSH:
				contact = true
				break
	if not contact:
		heat = maxf(0, heat - delta)
		return false
	heat = clampf(heat + delta * (.35 if speed < SLOW_SPEED else -1.0), 0, 1)
	if heat >= 1:
		overheated = true
		for i in SCRAP_COST:
			for j in seams[i].size():
				if seams[i][j].distance_to(to) < BRUSH * 1.35:
					welded[i][j] = 0
		for key in deposits.keys():
			if deposits[key][0].distance_to(to) < BRUSH * 1.35:
				deposits.erase(key)
		_refresh_sealed()
		return false
	if travel < .05:
		return true
	_direction = (to - from).normalized()
	var steps := maxi(1, ceili(travel))
	for s in steps + 1:
		var point := from.lerp(to, float(s) / steps)
		var arc := _distance + travel * float(s) / steps
		if speed > FAST_SPEED and int(arc / 16) % 2 == 1:
			continue
		var hole := -1
		for i in SCRAP_COST:
			for j in seams[i].size():
				if seams[i][j].distance_to(point) <= BRUSH:
					welded[i][j] = 1
					ages[i][j] = 0
					hole = i
		if hole >= 0 and arc - _last_deposit_arc >= 1.5:
			var at := point.round()
			var key := Vector2i(at)
			if deposits.has(key):
				deposits[key][3] = 0.0
			else:
				if deposits.size() >= 2048:
					deposits.erase(deposits.keys()[0])
				deposits[key] = [at, _direction, arc, 0.0, hole]
			_last_deposit_arc = arc
	_distance += travel
	_refresh_sealed()
	return true


func _refresh_sealed() -> void:
	for i in SCRAP_COST:
		var done := coverage(i) >= REQUIRED_COVERAGE
		if done and sealed[i] == 0:
			glow[i] = 1.0
		elif not done:
			glow[i] = 0.0
		sealed[i] = int(done)


func cool(delta: float) -> void:
	heat = maxf(0, heat - delta * 2.5)
	if heat < 0.3:
		overheated = false
	_distance = 0
	_last_deposit_arc = -2


func advance_visuals(delta: float) -> void:
	for deposit: Array in deposits.values():
		deposit[3] += delta
	for i in SCRAP_COST:
		glow[i] = maxf(0, glow[i] - delta)
		for j in ages[i].size():
			ages[i][j] += delta
