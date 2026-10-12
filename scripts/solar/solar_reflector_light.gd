class_name SolarReflectorLight
extends Node2D
## Replays the exact world beam meshes over one y-sorted reflector, clipped to its
## generated silhouette and per-pixel optical/body depth. Parts behind it stay hidden.
## Shares geometry with the world layer: no shortened contact strips or new ray endpoints.
## load_view takes a generator-owned sheet; refresh follows its orientation after FX refresh.
## Native solar_beam_test exercises all ten reflectors/eight settings/four views.
## Incident side is evaluated per hit: back-side optical vertices never pierce the panel.

var meshes: Array[MeshInstance2D] = []
var _beams: Array[MeshInstance2D] = []
var _terrain: MapTerrain
var _prop: WorldProp
var _sheet: Dictionary
var _state: SolarFieldState
var _mirror: Dictionary


func setup(terrain: MapTerrain, prop: WorldProp, sheet: Dictionary, beams: Array[MeshInstance2D], state: SolarFieldState, mirror: Dictionary) -> void:
	_terrain = terrain
	_prop = prop
	_beams = beams
	_state = state
	_mirror = mirror
	set_meta("dn_unlit", true)
	for beam in beams:
		var overlay := MeshInstance2D.new()
		overlay.material = beam.material.duplicate()
		overlay.set_meta("group", beam.get_meta("group"))
		overlay.set_meta("dn_unlit", true)
		add_child(overlay)
		meshes.append(overlay)
	load_view(sheet)


func load_view(sheet: Dictionary) -> void:
	_sheet = sheet
	var depth: Dictionary = sheet["depth"]
	var atlas := load("res://assets/maps/red_planet/".path_join(depth["file"])) as Texture2D
	for mesh in meshes:
		var material := mesh.material as ShaderMaterial
		material.set_shader_parameter("reflector_clip", true)
		material.set_shader_parameter("reflector_map", atlas)
		material.set_shader_parameter("reflector_size", SolarOptics.point(sheet["size"]))
		material.set_shader_parameter("reflector_frames", depth["frames"])
		material.set_shader_parameter("reflector_scale", depth["scale"])
		material.set_shader_parameter("reflector_offset", depth["offset"])
		material.set_shader_parameter("skin_depth_span", depth["skin_depth_span"])
		MapStream.bind(material, _terrain)
		material.set_shader_parameter("depth_scale", _terrain.depth_scale)
	refresh()


func refresh() -> void:
	# Equipment positions and anchors are whole pixels, so cancelling the prop transform
	# gives precisely the same vertices/pixel coverage as the beam beneath Actors.
	position = -_prop.position
	for index in meshes.size():
		var mesh := meshes[index]
		var group: int = _beams[index].get_meta("group")
		mesh.mesh = SolarBeamVisuals.on_reflector(_beams[index].mesh, _front_segments(_state.routes[group]))
		var material := mesh.material as ShaderMaterial
		material.set_shader_parameter("reflector_position", _prop.position + _prop.sprite.offset)
		material.set_shader_parameter("reflector_depth", _terrain.view_depth(_prop.world))
		material.set_shader_parameter("reflector_frame", _prop.sprite.frame / int(_sheet["shine_frames"]))


func _front_segments(route: Dictionary) -> Array[int]:
	var segments: Array[int] = []
	var normal := SolarOptics.mirror_normal(_mirror, _state.orientations[_mirror["id"]])
	var xy := _terrain.world_dir(Vector2(0, -1))
	var toward_camera := Vector3(xy.x, xy.y, _terrain.depth_to_px)
	for index in route["hits"].size():
		if route["hits"][index] != _mirror["id"]: continue
		var incoming: Vector3 = route["segments"][index][1] - route["segments"][index][0]
		if incoming.dot(normal) * toward_camera.dot(normal) >= 0: continue
		segments.append(index)
		if index + 1 < route["segments"].size(): segments.append(index + 1)
	return segments
