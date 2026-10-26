class_name CropVisual
extends Node2D
## A generated cultivation sheet, y-sorted at its canonical foot. Its native depth/glow
## atlas keeps crop leaves behind nursery racks, scenery and glass in every camera view.
## Rebind on streamed-window movement; changing frames never reloads the texture.

const SHADER := preload("res://shaders/crop_depth.gdshader")
var world := Vector2.ZERO
var sprite: Sprite2D
var _terrain: MapTerrain
var _material: ShaderMaterial
var _sheet: Dictionary
var _root := ""
var _glow: Texture2D
var _solid := false


func setup(info: Dictionary, root: String, terrain: MapTerrain, foot: Vector2, solid := false) -> void:
	_terrain = terrain
	world = foot
	_root = root
	_solid = solid
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	sprite = Sprite2D.new()
	sprite.centered = false
	sprite.material = _material
	add_child(sprite)
	set_view(info)
	if solid:
		_terrain.blockers[get_instance_id()] = Vector3(world.x, world.y, 3.0)


func set_view(info: Dictionary) -> void:
	_sheet = info
	sprite.texture = load(_root.path_join(info["file"]))
	sprite.hframes = int(info["frames"])
	sprite.offset = -Vector2(info["anchor"][0], info["anchor"][1]).round()
	sprite.frame = mini(sprite.frame, sprite.hframes - 1)
	_material.set_shader_parameter("sprite_data", load(_root.path_join(info["data"])))
	_material.set_shader_parameter("depth_scale", _terrain.depth_scale)
	_material.set_shader_parameter("sprite_depth", _terrain.view_depth(world))
	_material.set_shader_parameter("local_depth_scale", float(info["local_depth_scale"]))
	_material.set_shader_parameter("depth_offset", float(info["depth_offset"]))
	_glow = load(_root.path_join(info["glow"])) if info.has("glow") else null
	position = _terrain.to_screen(world, _terrain.height_at(world)).round()
	refresh_window()


func refresh_window() -> void:
	if _material != null:
		MapStream.bind(_material, _terrain)


func set_frame(index: int) -> void:
	var next := clampi(index, 0, sprite.hframes - 1)
	if sprite.frame != next:
		sprite.frame = next


func boards() -> Array:
	var size := Vector2(_sheet["frame_size"][0], _sheet["frame_size"][1])
	var region := Rect2(Vector2(sprite.frame * size.x, 0.), size)
	var at := Vector3(world.x, world.y, _terrain.height_at(world))
	var result := [{"tex": sprite.texture, "region": region, "anchor": -sprite.offset, "world": at}]
	if _glow != null:
		result.append({"tex": _glow, "region": region, "anchor": -sprite.offset,
				"world": at + Vector3(0., 0., .002), "unlit": true})
	return result


func _exit_tree() -> void:
	if _solid and _terrain != null:
		_terrain.blockers.erase(get_instance_id())
