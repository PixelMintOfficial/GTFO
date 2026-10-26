class_name Bulkhead
extends Node2D
## A bulkhead sealing a corridor out of storage (to the power room, to the oxygen room) until the
## bot releases maintenance access. Its frame is baked into the room; its two leaves are a sprite
## sheet from the generator (base_interior.json -> bulkheads: closed -> open), drawn over the map
## behind nearer scenery (prop_depth) and y-sorted with the astronaut on its foot. Sealed, it
## stands across the corridor in MapTerrain.blockers; its lamp blinks red if mains are on. Open, the leaves are
## telescoped into the posts (the sprite goes), the way is clear, and its lamp holds steady cyan.
## Positions come from the data (world, lamp_px), so it follows the camera through every view.
## Seen edge-on (the corridors run across the screen in some views), a sealed bulkhead could be
## mistaken for an open corridor: walk up to it and SEALED shows over its lamp.

const SHADER := preload("res://shaders/prop_depth.gdshader")
const SEALED := Color("#ff5a4a")
const OPEN := Color("#7fe6cf")
## How long the leaves take to slide into the posts, seconds.
const OPEN_TIME := 0.9
## How close (world units) you come before SEALED shows.
const NOTICE := 34.0

var id := ""
var world := Vector2.ZERO
var opened := false
var sprite: Sprite2D

var _terrain: MapTerrain
var _player: Player
var _mat: ShaderMaterial
var _lit: Node2D
var _glow: Node2D
var _lamp := Vector2.ZERO
var _axis := 0
var _half := 15.0
var _frames := 10
var _opening := -1.0            # seconds into opening (-1: not opening)
var _t := 0.0
var _drawn: Variant = null      # what the lamp and label showed last time they were drawn
var _halos := {}


func setup(info: Dictionary, base_dir: String, terrain: MapTerrain, player: Player) -> void:
	_terrain = terrain
	_player = player
	id = info["id"]
	world = Vector2(info["world"][0], info["world"][1])
	_axis = int(info["axis"])
	_half = float(info["half_width"])
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("depth_scale", terrain.depth_scale)
	_mat.set_shader_parameter("tolerance", _half + 2.0)
	sprite = Sprite2D.new()
	sprite.centered = false
	sprite.material = _mat
	add_child(sprite)
	_lit = Node2D.new()
	_lit.z_index = 41
	_lit.set_meta("dn_unlit", true)                      # the lamp is a light
	_lit.draw.connect(_draw_lamp)
	add_child(_lit)
	_glow = Node2D.new()
	_glow.z_index = 41
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = add
	_glow.draw.connect(_draw_glow)
	add_child(_glow)
	set_view(info, base_dir)
	_set_open(GameState.story.access_opened)


## The camera turned: this view's sheet, foot and lamp.
func set_view(info: Dictionary, base_dir: String) -> void:
	_frames = int(info["frames"])
	_lamp = Vector2(info["lamp_px"][0], info["lamp_px"][1])
	position = Vector2(0.0, float(info["sort_y"]))
	sprite.texture = load(base_dir.path_join(info["file"]))
	sprite.hframes = _frames
	sprite.position = Vector2(info["position"][0], info["position"][1]) - position
	_lit.position = -position                            # draws in map pixels
	_glow.position = -position
	refresh_window()
	_mat.set_shader_parameter("sprite_depth", _terrain.view_depth(world))


## The depth map it hides behind is a moving window (MapStream): point the shader at it again.
func refresh_window() -> void:
	MapStream.bind(_mat, _terrain)


## Reserve power is on: the leaves slide into the posts, and the corridor opens.
func open() -> void:
	if opened or _opening >= 0.0:
		return
	_opening = 0.0
	Audio.play("door_unseal", _lamp)                     # the airlock's own seal letting go


func _process(delta: float) -> void:
	_t += delta
	if _opening >= 0.0:
		_opening += delta
		var k := clampf(_opening / OPEN_TIME, 0.0, 1.0)
		sprite.frame = mini(_frames - 1, int(k * (_frames - 1) + 0.5))
		if k >= 1.0:
			_opening = -1.0
			_set_open(true)
	# Redraw only when the lamp blinks, the bulkhead opens or SEALED comes and goes (as DayClock does).
	var state := [_lamp_on(), opened, _notice()]
	if state != _drawn:
		_drawn = state
		_lit.queue_redraw()
		_glow.queue_redraw()


func _set_open(value: bool) -> void:
	opened = value
	sprite.visible = not value
	sprite.frame = 0
	for i in 3:                                          # three discs across the corridor
		var key := "bulkhead:%s:%d" % [id, i]
		if value:
			_terrain.blockers.erase(key)
		else:
			var across := (i - 1) * (_half - 6.0)
			var p := world + (Vector2(0, across) if _axis == 0 else Vector2(across, 0))
			_terrain.blockers[key] = Vector3(p.x, p.y, 7.5)


## The sealed bulkhead as a billboard for the camera's swing (none once it is open).
func boards() -> Array:
	if not sprite.visible:
		return []
	var tex := sprite.texture
	var w := tex.get_width() / float(_frames)
	var foot := _terrain.to_screen(world, _terrain.height_at(world))
	return [{"tex": tex, "region": Rect2(sprite.frame * w, 0.0, w, tex.get_height()),
			"anchor": foot - (position + sprite.position), "world": Vector3(world.x, world.y, _terrain.height_at(world))}]


## Close enough to a sealed bulkhead to be told so.
func _notice() -> bool:
	return not opened and _player != null and _player.controls_enabled and _player.world_pos.distance_to(world) < NOTICE


func _lamp_on() -> bool:
	return GameState.base_powered() and (opened or fmod(_t, 1.2) < 0.6)


func _draw_lamp() -> void:
	if _lamp_on():
		_lit.draw_rect(Rect2(_lamp.round() - Vector2(1, 1), Vector2(2, 2)), (OPEN if opened else SEALED).lerp(Color.WHITE, 0.4))
	if _notice():
		var w := PixelFont.width("SEALED") + 6
		var top := (_lamp + Vector2(-round(w / 2.0), -14)).round()
		_lit.draw_rect(Rect2(top - Vector2(1, 1), Vector2(w + 2, 11)), Color("#120f1d", 0.9))
		_lit.draw_rect(Rect2(top, Vector2(w, 9)), Color("#241f36", 0.95))
		PixelFont.draw(_lit, top + Vector2(3, 2), "SEALED", SEALED)


func _draw_glow() -> void:
	if _lamp_on():
		_halo(_lamp, 6, Color(OPEN if opened else SEALED, 0.45))


func _halo(center: Vector2, r: int, col: Color) -> void:
	if not _halos.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var bayer := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
		for y in size:
			for x in size:
				var d := Vector2(x - r, y - r).length() / float(r)
				if d > 1.0:
					continue
				var lv := floorf(pow(1.0 - d, 1.6) * 3.0 + (bayer[(y % 4) * 4 + x % 4] + 0.5) / 16.0)
				if lv > 0.0:
					img.set_pixel(x, y, Color(1, 1, 1, minf(lv, 3.0) / 3.0))
		_halos[r] = ImageTexture.create_from_image(img)
	_glow.draw_texture(_halos[r], (center - Vector2(r, r)).round(), col)
