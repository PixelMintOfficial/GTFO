class_name SolarBeamVisuals
extends RefCounted
## Shared depth-carrying beam geometry for reflected rays and crystal sunlight funnels.
## World-space Vector3 segment endpoints are projected only through MapTerrain.
## contacts isolates the incoming/outgoing ends for light drawn on a struck mirror's face.

const WIDTHS := [6.0, 2.25]


static func contacts(route: Dictionary, id: String, reach: float) -> Array:
	var segments := []
	for index in route["hits"].size():
		if route["hits"][index] != id:
			continue
		var incoming: Array = route["segments"][index]
		var hit: Vector3 = incoming[1]
		var start: Vector3 = incoming[0]
		segments.append([hit.move_toward(start, reach), hit])
		if index + 1 < route["segments"].size():
			var outgoing: Array = route["segments"][index + 1]
			segments.append([hit, hit.move_toward(outgoing[1], reach)])
	return segments


static func mesh(terrain: MapTerrain, segments: Array, width: float) -> ArrayMesh:
	var result := ArrayMesh.new()
	if segments.is_empty():
		return result
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for segment in segments:
		var start: Vector3 = segment[0]
		var end: Vector3 = segment[1]
		var a := terrain.to_screen(Vector2(start.x, start.y), start.z)
		var b := terrain.to_screen(Vector2(end.x, end.y), end.z)
		var normal := (b - a).normalized().orthogonal() * width * .5
		var index := vertices.size()
		for point in [a - normal, a + normal, b + normal, b - normal]:
			vertices.append(Vector3(point.x, point.y, 0))
		for depth in [terrain.view_depth(Vector2(start.x, start.y)), terrain.view_depth(Vector2(start.x, start.y)), terrain.view_depth(Vector2(end.x, end.y)), terrain.view_depth(Vector2(end.x, end.y))]:
			colors.append(Color(depth / 4096.0, 0, 0, 1))
		for offset in [0, 1, 2, 0, 2, 3]:
			indices.append(index + offset)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result
