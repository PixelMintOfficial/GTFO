class_name WorldProp
extends Node2D
## Something loose on the ground that the multitool can work on: an ore rock, a chunk of ore,
## a piece of scrap, a crate. It lives in world coordinates like the astronaut, is drawn at
## its projected position (y-sorted with the astronaut), hides behind nearer scenery, and can
## float above the ground (lifted, or hopping) while its shadow stays below.
## A box you can stand on (the cargo box) has a top and a footprint: resting on the ground it is
## one of MapTerrain's platforms, so the astronaut can jump onto it and is stopped by its sides.
## Crushed flat (top 0) it stays one, level with the floor: walked over, and drawn under you.

const SHADER := preload("res://shaders/prop_depth.gdshader")

var kind := ""
var job := ""
var world := Vector2.ZERO
var radius := 4.0
## Blocks the astronaut while it rests on the ground.
var solid := false
## Height above the ground, map px.
var lift := 0.0
## Work done on it so far, 0..1 (mining cracks, how far it has been pulled in).
var progress := 0.0
var gone := false
## Something to stand on: its height, world units, and its footprint (none: zero), half its
## size along its own X / Y, turned by yaw.
var top := 0.0
var half := Vector2.ZERO
var yaw := 0.0

var sprite: Sprite2D
var shadow: Sprite2D
var _terrain: MapTerrain
var _mat: ShaderMaterial


func setup(sheet: Dictionary, frame: int, terrain: MapTerrain, depth_map: Texture2D) -> void:
	_terrain = terrain
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("depth_map", depth_map)
	_mat.set_shader_parameter("map_size", terrain.map_size)
	_mat.set_shader_parameter("depth_scale", terrain.depth_scale)
	_mat.set_shader_parameter("tolerance", radius + 2.0)
	shadow = Sprite2D.new()
	shadow.texture = _shadow_texture(radius)
	shadow.material = _mat
	add_child(shadow)
	sprite = Sprite2D.new()
	sprite.texture = sheet["tex"]
	sprite.hframes = int(sheet["frames"])
	sprite.frame = clampi(frame, 0, sprite.hframes - 1)
	sprite.centered = false
	sprite.offset = -sheet["anchor"]
	sprite.material = _mat
	add_child(sprite)


## Put it at a world point on the ground.
func place(p: Vector2) -> void:
	world = p
	position = _terrain.to_screen(p, _terrain.height_at(p)).round()
	_mat.set_shader_parameter("sprite_depth", _terrain.view_depth(p))
	_update_blocker()


## The camera turned: this view's drawing of it, and its depth map.
func set_view(sheet: Dictionary, depth_map: Texture2D) -> void:
	var frame := sprite.frame
	sprite.texture = sheet["tex"]
	sprite.hframes = int(sheet["frames"])
	sprite.frame = clampi(frame, 0, sprite.hframes - 1)
	sprite.offset = -sheet["anchor"]
	_mat.set_shader_parameter("depth_map", depth_map)
	_mat.set_shader_parameter("map_size", _terrain.map_size)
	place(world)
	set_lift(lift)


func set_lift(px: float) -> void:
	lift = px
	sprite.position.y = -roundf(px)
	var k := clampf(px / 40.0, 0.0, 1.0)
	shadow.scale = Vector2.ONE * lerpf(1.0, 0.6, k)
	shadow.modulate.a = lerpf(1.0, 0.45, k)
	_update_blocker()


func remove() -> void:
	gone = true
	_terrain.blockers.erase(get_instance_id())
	_terrain.platforms.erase(get_instance_id())
	queue_free()


## Its new height to stand on (0: flat on the floor).
func set_top(h: float) -> void:
	top = h
	_update_blocker()


## Whether a world point is over its footprint (grown by margin), as if it stood at `at`.
func covers(p: Vector2, margin := 0.0, at: Variant = null) -> bool:
	var c := world
	if at != null:
		c = at
	var q := (p - c).rotated(-yaw).abs()
	return q.x <= half.x + margin and q.y <= half.y + margin


## Whether it would fit at a world point: its middle, and its corners if it has a footprint,
## clear of walls and anything solid.
func fits(p: Vector2) -> bool:
	if _terrain.surface(p) == MapTerrain.Surface.SOLID:
		return false
	if half == Vector2.ZERO:
		return true
	for c: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		if _terrain.surface(p + (half * c).rotated(yaw)) == MapTerrain.Surface.SOLID:
			return false
	return true


## Where its middle is drawn on screen (for beams and effects).
func center_px() -> Vector2:
	var h: float = sprite.texture.get_height() if sprite.texture else 10.0
	return global_position + sprite.position + Vector2(0, -minf(h * 0.35, radius * 1.4))


func _update_blocker() -> void:
	if solid and lift < 1.0 and not gone:
		_terrain.blockers[get_instance_id()] = Vector3(world.x, world.y, radius)
	else:
		_terrain.blockers.erase(get_instance_id())
	if half != Vector2.ZERO and lift < 1.0 and not gone:
		_terrain.platforms[get_instance_id()] = [world, half, yaw, _terrain.height_at(world) + top]
	else:
		_terrain.platforms.erase(get_instance_id())


static func _shadow_texture(r: float) -> ImageTexture:
	var rx := int(ceil(r / 0.866 + 2))
	var ry := int(ceil(rx * 0.5))
	var img := Image.create(rx * 2 + 1, ry * 2 + 1, false, Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var d := Vector2((x - rx) / float(rx), (y - ry) / float(ry)).length_squared()
			if d <= 1.0:
				img.set_pixel(x, y, Color(0.13, 0.09, 0.17, 0.33 if d > 0.5 else 0.5))
	return ImageTexture.create_from_image(img)
