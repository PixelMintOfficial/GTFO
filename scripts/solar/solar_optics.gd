class_name SolarOptics
extends RefCounted
## Stateless optics in canonical world coordinates. Finite mirror planes reflect rays;
## the receiver is the actual capped cone. Fixed mounting offsets allow landscape-aware
## placements; elevated feeds aim down to a tilted first mirror. Other mirrors are upright.
## An incomplete path
## stops at the cone but cannot energize it. Views never participate in this calculation.
## tests/solar_field_test.gd covers bypasses, cycles, shutoff and all B4 orientations.

const STEP := PI / 8.0
const EPSILON := .03
const MAX_BOUNCES := 26


static func point(pair: Array) -> Vector2:
	return Vector2(pair[0], pair[1])


static func alignment(incoming: Vector2, outgoing: Vector2) -> int:
	return posmod(roundi((incoming.angle() + outgoing.angle()) / (2.0 * STEP)), 8)


static func mount(field: Dictionary, mirror: Dictionary) -> Vector2:
	var route: Dictionary = field["routes"][mirror["group"]]
	var index: int = mirror["index"]
	var elevation := float(route.get("source_elevation", 0.0)) if index == 0 else 0.0
	var center := point(route["mirrors"][index])
	var before := point(route["source"] if index == 0 else route["mirrors"][index - 1])
	var after := point(field["collector"]["world"] if index + 1 == route["mirrors"].size() else route["mirrors"][index + 1])
	var incoming := Vector3(center.x - before.x, center.y - before.y, -elevation).normalized()
	var outgoing := Vector3(after.x - center.x, after.y - center.y, 0).normalized()
	var normal := (incoming - outgoing).normalized()
	var yaw := atan2(-normal.x, normal.y)
	if yaw < 0:
		yaw += PI
		normal = -normal
	var bias := yaw - alignment(center - before, after - center) * STEP
	var pitch := asin(normal.z)
	return Vector2(0.0 if absf(bias) < .000001 else bias, 0.0 if absf(pitch) < .000001 else pitch)


static func mirror_normal(mirror: Dictionary, angle: int) -> Vector3:
	var tilt: Vector2 = mirror["mount"]
	var yaw := angle * STEP + tilt.x
	return Vector3(-sin(yaw) * cos(tilt.y), cos(yaw) * cos(tilt.y), sin(tilt.y))


static func mirror_distance(origin: Vector3, direction: Vector3, mirror: Dictionary, angle: int, field: Dictionary) -> float:
	var normal := mirror_normal(mirror, angle)
	var denominator := direction.dot(normal)
	if absf(denominator) < .000001:
		return INF
	var world: Vector2 = mirror["world"]
	var center := Vector3(world.x, world.y, field["beam_height"])
	var distance := (center - origin).dot(normal) / denominator
	var yaw: float = angle * STEP + mirror["mount"].x
	var tangent := Vector3(cos(yaw), sin(yaw), 0)
	var vertical := normal.cross(tangent)
	var hit := origin + direction * distance - center
	return distance if distance > EPSILON and absf(hit.dot(tangent)) <= field["mirror_span"] and absf(hit.dot(vertical)) <= field["mirror_half_height"] else INF


static func collector_distance(origin: Vector3, direction: Vector3, spec: Dictionary) -> float:
	var offset := Vector2(origin.x, origin.y) - point(spec["world"])
	var flat := Vector2(direction.x, direction.y)
	var slope := (float(spec["radius"]) - float(spec["top_radius"])) / float(spec["height"])
	var radius := float(spec["radius"]) - slope * origin.z
	var a := flat.length_squared() - pow(slope * direction.z, 2)
	var b := 2 * (offset.dot(flat) + radius * slope * direction.z)
	var c := offset.length_squared() - radius * radius
	var discriminant := b * b - 4 * a * c
	var candidates := []
	if absf(a) > .000001 and discriminant >= 0:
		candidates.append((-b - sqrt(discriminant)) / (2 * a))
		candidates.append((-b + sqrt(discriminant)) / (2 * a))
	elif absf(a) <= .000001 and absf(b) > .000001:
		candidates.append(-c / b)
	var distance := INF
	for candidate in candidates:
		var z: float = origin.z + direction.z * candidate
		if candidate > EPSILON and z >= 0 and z <= float(spec["height"]):
			distance = minf(distance, candidate)
	if absf(direction.z) > .000001:
		for z in [0.0, float(spec["height"])]:
			var t: float = (z - origin.z) / direction.z
			if t > EPSILON and (offset + flat * t).length() <= float(spec["radius"]) - slope * z:
				distance = minf(distance, t)
	return distance


static func edge_distance(origin: Vector3, direction: Vector3, bounds: Rect2) -> float:
	var distance := INF
	for axis in 2:
		if absf(direction[axis]) > .000001:
			var edge := bounds.end[axis] if direction[axis] > 0.0 else bounds.position[axis]
			var t := (edge - origin[axis]) / direction[axis]
			if t > EPSILON:
				distance = minf(distance, t)
	if absf(direction.z) > .000001:
		var t := ((160.0 if direction.z > 0 else 0.0) - origin.z) / direction.z
		if t > EPSILON:
			distance = minf(distance, t)
	return distance


static func trace(field: Dictionary, mirrors: Array[Dictionary], orientations: Dictionary, route_index: int, active: bool) -> Dictionary:
	var result := {"segments": [], "hits": [], "connected": false, "hit_collector": false}
	if not active:
		return result
	var route: Dictionary = field["routes"][route_index]
	var source := point(route["source"])
	var elevation := float(route.get("source_elevation", 0.0))
	var origin := Vector3(source.x, source.y, float(field["beam_height"]) + elevation)
	var flat := point(route["direction"]).normalized()
	var direction := Vector3(flat.x, flat.y, 0)
	if elevation > 0:
		var first := point(route["mirrors"][0])
		direction = (Vector3(first.x, first.y, field["beam_height"]) - origin).normalized()
	var spec: Dictionary = field["collector"]
	var box: Array = field["bounds"]
	var bounds := Rect2(box[0], box[1], box[2], box[3])
	var previous := ""
	var visited := {}
	for bounce in MAX_BOUNCES:
		var distance := edge_distance(origin, direction, bounds)
		var chosen := ""
		var cone_distance := collector_distance(origin, direction, spec)
		if cone_distance < distance:
			distance = cone_distance
			chosen = "collector"
		for mirror in mirrors:
			var id: String = mirror["id"]
			if id == previous:
				continue
			var t := mirror_distance(origin, direction, mirror, orientations[id], field)
			if t < distance:
				distance = t
				chosen = id
		if is_inf(distance):
			break
		var end := origin + direction * distance
		result["segments"].append([origin, end])
		if chosen == "collector":
			result["hit_collector"] = true
			result["connected"] = true
			for index in route["mirrors"].size():
				if not result["hits"].has(route["id"] + str(index + 1)):
					result["connected"] = false
			break
		if chosen.is_empty():
			break
		result["hits"].append(chosen)
		var signature := "%s:%d:%d:%d" % [chosen, roundi(direction.x * 1000), roundi(direction.y * 1000), roundi(direction.z * 1000)]
		if visited.has(signature):
			break
		visited[signature] = true
		for mirror in mirrors:
			if mirror["id"] == chosen:
				var normal := mirror_normal(mirror, orientations[chosen])
				direction = (direction - 2.0 * direction.dot(normal) * normal).normalized()
				break
		origin = end + direction * (EPSILON * 2)
		previous = chosen
	return result
