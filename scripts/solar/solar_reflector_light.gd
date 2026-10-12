class_name SolarReflectorLight
extends Node2D
## Replays the exact world beam meshes over one y-sorted reflector, clipped to its
## generated silhouette and per-pixel optical/body depth. Parts behind it stay hidden.
## Shares geometry with the world layer: no shortened contact strips or new ray endpoints.
## load_view takes a generator-owned sheet; refresh follows its orientation after FX refresh.
## Native solar_beam_test exercises all ten reflectors/eight settings/four views.

var meshes: Array[MeshInstance2D] = []
var _beams: Array[MeshInstance2D] = []
var _terrain: MapTerrain
var _prop: WorldProp
var _sheet: Dictionary


func setup(terrain: MapTerrain, prop: WorldProp, sheet: Dictionary, beams: Array[MeshInstance2D]) -> void:
	_terrain = terrain
	_prop = prop
	_beams = beams
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
		material.set_shader_parameter("depth_map", _terrain.depth_map)
		material.set_shader_parameter("map_size", _terrain.map_size)
		material.set_shader_parameter("depth_scale", _terrain.depth_scale)
	refresh()


func refresh() -> void:
	# Equipment positions and anchors are whole pixels, so cancelling the prop transform
	# gives precisely the same vertices/pixel coverage as the beam beneath Actors.
	position = -_prop.position
	for index in meshes.size():
		var mesh := meshes[index]
		mesh.mesh = _beams[index].mesh
		var material := mesh.material as ShaderMaterial
		material.set_shader_parameter("reflector_position", _prop.position + _prop.sprite.offset)
		material.set_shader_parameter("reflector_depth", _terrain.view_depth(_prop.world))
		material.set_shader_parameter("reflector_frame", _prop.sprite.frame / int(_sheet["shine_frames"]))
