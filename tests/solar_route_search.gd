extends RefCounted
## Search actual ray paths with consistent per-mirror angle domains. A domain retains every
## orientation that can avoid blocking each preceding segment. Branch only when a ray can
## physically strike a mirror; this covers all angle combinations without enumerating misses.
## Each witness is replayed through SolarOptics.trace. The same bounce limit and cycle
## signature as production terminate paths. Used only by tests/solar_field_test.gd.

class Search:
	extends RefCounted
	var field: Dictionary
	var mirrors: Array[Dictionary]
	var group: int
	var bounds: Rect2
	var witnesses: Array[Dictionary] = []
	var nodes := 0
	var stop_after := 1

	func run(state: SolarFieldState, channel: int, limit: int) -> Dictionary:
		field = state.field
		mirrors = state.mirrors
		group = channel
		stop_after = limit
		var box: Array = field["bounds"]
		bounds = Rect2(box[0], box[1], box[2], box[3])
		var origin := SolarOptics.source_origin(field, group)
		var direction := SolarOptics.source_direction(field, group)
		var domains: Array[int] = []
		domains.resize(mirrors.size())
		domains.fill(255)
		_walk(origin, direction, domains, [], -1, {})
		return {"witnesses": witnesses, "nodes": nodes}

	func _clear_to(distances: Array, domains: Array[int], distance: float, chosen := -1, angle := -1) -> Array[int]:
		# Retain only orientations compatible with every earlier segment and this next hit.
		var allowed: Array[int] = domains.duplicate()
		if chosen >= 0:
			allowed[chosen] = 1 << angle
		for index in mirrors.size():
			if index == chosen:
				continue
			var mask := 0
			for turn in 8:
				if domains[index] & (1 << turn) and distances[index][turn] >= distance:
					mask |= 1 << turn
			if mask == 0:
				return []
			allowed[index] = mask
		return allowed

	func _walk(origin: Vector3, direction: Vector3, domains: Array[int], hits: Array, previous: int, visited: Dictionary) -> void:
		if stop_after > 0 and witnesses.size() >= stop_after:
			return
		if hits.size() >= SolarOptics.MAX_BOUNCES:
			return
		nodes += 1
		var edge := SolarOptics.edge_distance(origin, direction, bounds)
		var cone := SolarOptics.collector_distance(origin, direction, field["collector"])
		var stop := minf(edge, cone)
		var distances := []
		var candidates := []
		for index in mirrors.size():
			var row: Array[float] = []
			for angle in 8:
				var t := INF
				if index != previous and domains[index] & (1 << angle):
					t = SolarOptics.mirror_distance(origin, direction, mirrors[index], angle, field)
					if t < stop:
						candidates.append([t, index, angle])
				row.append(t)
			distances.append(row)
		if cone < edge:
			# A clear path to the receiver is a failure unless it visited all assigned mirrors.
			var allowed := _clear_to(distances, domains, cone)
			if not allowed.is_empty():
				var complete := true
				var route: Dictionary = field["routes"][group]
				for index in route["mirrors"].size():
					complete = complete and hits.has(route["id"] + str(index + 1))
				if not complete:
					var angles := {}
					for index in mirrors.size():
						for angle in 8:
							if allowed[index] & (1 << angle):
								angles[mirrors[index]["id"]] = angle
								break
					var actual := SolarOptics.trace(field, mirrors, angles, group, true)
					assert(actual["hit_collector"] and not actual["connected"] and actual["hits"] == hits)
					witnesses.append({"orientations": angles, "hits": actual["hits"]})
		for candidate in candidates:
			var distance: float = candidate[0]
			var index: int = candidate[1]
			var angle: int = candidate[2]
			var allowed := _clear_to(distances, domains, distance, index, angle)
			if allowed.is_empty():
				continue
			var id: String = mirrors[index]["id"]
			var signature := "%s:%d:%d:%d" % [id, roundi(direction.x * 1000), roundi(direction.y * 1000), roundi(direction.z * 1000)]
			if visited.has(signature):
				continue
			var seen := visited.duplicate()
			seen[signature] = true
			var path := hits.duplicate()
			path.append(id)
			var normal := SolarOptics.mirror_normal(mirrors[index], angle)
			var reflected := (direction - 2.0 * direction.dot(normal) * normal).normalized()
			var end := origin + direction * distance
			_walk(end + reflected * (SolarOptics.EPSILON * 2), reflected, allowed, path, index, seen)

static func inspect(state: SolarFieldState, group: int, limit := 1) -> Dictionary:
	return Search.new().run(state, group, limit)
