class_name CircuitCatalog
extends RefCounted
## Authored circuit routes, shared with the browser preview. Five per machine.

const DATA_PATH := "res://data/repair_circuits.json"
static var _data: Dictionary = {}


static func for_machine(machine_id: String) -> Array[Dictionary]:
	if _data.is_empty():
		_data = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	var result: Array[Dictionary] = []
	for id in _data["machines"].get(machine_id, []):
		for circuit in _data["circuits"]:
			if circuit["id"] == id:
				result.append(circuit)
	return result


static func route(definition: Dictionary) -> Array[Vector2i]:
	var points: Array = definition["waypoints"]
	var result: Array[Vector2i] = [Vector2i(points[0][0], points[0][1])]
	for p in points.slice(1):
		var end := Vector2i(p[0], p[1])
		var at := result[-1]
		assert(at.x == end.x or at.y == end.y, "Circuit routes must be orthogonal")
		var step := Vector2i(signi(end.x - at.x), signi(end.y - at.y))
		while at != end:
			at += step
			assert(not result.has(at), "Circuit routes cannot cross themselves")
			result.append(at)
	return result
