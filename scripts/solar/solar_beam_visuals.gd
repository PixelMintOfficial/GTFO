class_name SolarBeamVisuals
extends RefCounted
## Shared depth-carrying beam geometry for reflected rays and crystal sunlight funnels.
## World-space Vector3 segment endpoints are projected only through MapTerrain.
## Float UV.x carries view depth: ArrayMesh byte-packs colors, which lose precision.
## Unbounded float depth also keeps long escaping rays accurate inside the map.

const WIDTHS := [6.0, 2.25]


static func mesh(terrain: MapTerrain, segments: Array, width: float) -> ArrayMesh:
	var result := ArrayMesh.new()
	if segments.is_empty():
		return result
	var vertices := PackedVector3Array()
	var depths := PackedVector2Array()
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
			depths.append(Vector2(depth, 0))
		for offset in [0, 1, 2, 0, 2, 3]:
			indices.append(index + offset)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = depths
	arrays[Mesh.ARRAY_INDEX] = indices
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result
