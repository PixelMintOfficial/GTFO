class_name BiomeFX
extends Node2D
## Life in the three lands, drawn between the map and the astronaut: alien plants swaying as
## wind rolls through the forest, bioluminescence pulsing through it in slow waves, shimmering
## pools, glinting ice, crystal spires breathing light and embers smouldering at the wreck.
## The data comes from the map generator (red_planet_fx.json). Only what the camera can see
## is drawn.

const FLORA_SHADER := preload("res://shaders/flora_depth.gdshader")
const CELL := 256
## Largest plant sprite: plants whose corner is this far off screen can still reach into it.
const MARGIN := 260.0

enum Kind { PLANT, POOL, EMBER, GLINT, SPIRE }

## Forest light waves: how fast they roll (radians/s) and how far apart they are (map px).
@export var wave_speed := 1.3
@export var wave_length := 520.0
## How strongly the wreck's embers glow (the crash scene fades them in).
var embers := 1.0

var _camera: Camera2D
var _sheets: Array = []          # {tex, frames, fps, size, glows}
var _plants: Dictionary = {}     # Vector2i cell -> Array of [draw order, sheet, position, phase, depth colour, lit]
var _points: Dictionary = {}     # Vector2i cell -> PackedInt32Array, 7 ints per point
var _visible: Array = []
var _colors: Array[Color] = []
var _halo: Texture2D
var _halo_cell := 0
var _t := 0.0
var _plant_layer: Node2D
var _glow_layer: Node2D
var _player: Node2D


## depth_map / map_size: the map's depth image, so plants hide behind cliffs and props.
## player: plants in front of it thin out so the astronaut never gets lost in the forest.
func setup(meta_path: String, camera: Camera2D, depth_map: Texture2D, map_size: Vector2,
		player: Player = null) -> void:
	_camera = camera
	_player = player
	_plant_layer = Node2D.new()
	var fmat := ShaderMaterial.new()
	fmat.shader = FLORA_SHADER
	_plant_layer.material = fmat
	_plant_layer.draw.connect(_draw_plants)
	add_child(_plant_layer)
	_glow_layer = Node2D.new()
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow_layer.material = mat
	_glow_layer.draw.connect(_draw_glows)
	add_child(_glow_layer)
	load_view(meta_path, depth_map, map_size)


## The camera turned: this view's plant sprites, where they stand, and its lights.
func load_view(meta_path: String, depth_map: Texture2D, map_size: Vector2) -> void:
	_sheets.clear()
	_plants.clear()
	_points.clear()
	_visible.clear()
	_colors.clear()
	var fmat := _plant_layer.material as ShaderMaterial
	fmat.set_shader_parameter("depth_map", depth_map)
	fmat.set_shader_parameter("map_size", map_size)
	var dir := meta_path.get_base_dir()
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	fmat.set_shader_parameter("depth_scale", float(meta["game"]["depth_scale"]))
	if not meta.has("fx"):
		return
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(meta["fx"])))
	for s in fx["flora"]["sheets"]:
		var size := Vector2(s["frame_size"][0], s["frame_size"][1])
		var anchor: Array = s.get("anchor", [size.x * 0.5, size.y])
		_sheets.append({"tex": load(dir.path_join(s["file"])), "frames": int(s["frames"]), "fps": float(s["fps"]),
				"size": size, "glows": s["glows"], "anchor": Vector2(anchor[0], anchor[1])})
	var order := 0
	for inst in fx["flora"]["instances"]:
		var pos := Vector2(inst[1], inst[2])
		var key := _cell_of(pos)
		if not _plants.has(key):
			_plants[key] = []
		var depth := int(inst[4])          # the plant's depth (view Y) * 16, handed to the shader as a colour
		var tag := Color8(depth >> 8, depth & 255, 255, 255)
		_plants[key].append([order, int(inst[0]), pos, float(inst[3]), tag, int(inst[5]) == 1])
		order += 1
	for c in fx["glow_colors"]:
		_colors.append(Color(c))
	_halo = load(dir.path_join(fx["halos"]["file"]))
	_halo_cell = int(fx["halos"]["cell"])
	for g in fx["glows"]:
		var key := _cell_of(Vector2(g[0], g[1]))
		if not _points.has(key):
			_points[key] = PackedInt32Array()
		_points[key].append_array(PackedInt32Array(g))


## The plants in the camera's view, for the camera's turn: [texture, frame rect, top-left (map px),
## anchor in the frame (where the plant stands), depth (view Y)].
func visible_plants() -> Array:
	var out := []
	for p in _in_view(_view_rect()):
		var sh: Dictionary = _sheets[p[1]]
		var size: Vector2 = sh["size"]
		var tag: Color = p[4]
		var depth := (roundf(tag.r8) * 256.0 + roundf(tag.g8)) / 16.0
		out.append([sh["tex"], Rect2(Vector2(_frame(sh, p) * size.x, 0.0), size), p[2], sh["anchor"], depth])
	return out


func _process(delta: float) -> void:
	_t += delta
	if _plant_layer != null:
		if _player != null:
			var mat := _plant_layer.material as ShaderMaterial
			mat.set_shader_parameter("player_px", _player.global_position + _player.sprite.position)
			mat.set_shader_parameter("player_depth", _player.terrain.view_depth(_player.world_pos))
		_plant_layer.queue_redraw()
		_glow_layer.queue_redraw()


# ---------------------------------------------------------------- plants
func _draw_plants() -> void:
	_visible = _in_view(_view_rect())
	for p in _visible:
		var sh: Dictionary = _sheets[p[1]]
		var size: Vector2 = sh["size"]
		_plant_layer.draw_texture_rect_region(sh["tex"], Rect2(p[2], size), Rect2(Vector2(_frame(sh, p) * size.x, 0.0), size), p[4])


## The plants whose frames touch this rect (map px), far ones first.
func _in_view(view: Rect2) -> Array:
	var out := []
	for key in _cells(view.grow_individual(MARGIN, MARGIN, 0.0, 0.0)):
		for p in _plants.get(key, []):
			if Rect2(p[2], _sheets[p[1]]["size"]).intersects(view):
				out.append(p)
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out


func _frame(sh: Dictionary, p: Array) -> int:
	return int(floor(_t * sh["fps"] + float(p[3]) * sh["frames"])) % int(sh["frames"])


# ---------------------------------------------------------------- lights (additive layer)
func _draw_glows() -> void:
	if _camera == null:
		return
	var view := _view_rect().grow(20.0)
	var far := _camera.zoom.x < 0.55     # zoomed right out: skip the tiniest twinkles
	for key in _cells(view):
		if not _points.has(key):
			continue
		var pts: PackedInt32Array = _points[key]
		for i in range(0, pts.size(), 7):
			var pos := Vector2(pts[i], pts[i + 1])
			if not view.has_point(pos):
				continue
			var kind := pts[i + 5]
			if far and (kind == Kind.GLINT or kind == Kind.POOL):
				continue
			var b := _brightness(kind, pos, pts[i + 6] / 255.0) * pts[i + 4] / 255.0
			if b < 0.03:
				continue
			if kind == Kind.GLINT:
				_draw_glint(pos, b, _colors[pts[i + 3]])
			else:
				_draw_halo(pos, pts[i + 2], _colors[pts[i + 3]], b)
	for p in _visible:                    # the swaying plants carry their lights with them
		if not p[5]:
			continue
		var sh: Dictionary = _sheets[p[1]]
		var b := _wave(p[2], p[3]) * (1.0 + 0.35 * DayNight.night)
		for g in sh["glows"][_frame(sh, p)]:
			_draw_halo(p[2] + Vector2(g[0], g[1]), int(g[2]), _colors[int(g[3])], b * g[4] / 255.0)


func _brightness(kind: int, pos: Vector2, ph: float) -> float:
	return _base_brightness(kind, pos, ph) * (DayNight.daylight if kind == Kind.GLINT else 1.0 + 0.35 * DayNight.night)


func _base_brightness(kind: int, pos: Vector2, ph: float) -> float:
	match kind:
		Kind.PLANT:
			return _wave(pos, ph)
		Kind.POOL:
			return 0.3 + 0.7 * pow(0.5 + 0.5 * sin(_t * 1.1 + ph * TAU), 3.0)
		Kind.EMBER:
			return embers * (0.35 + 0.65 * absf(sin(_t * 5.3 + ph * 40.0)) * (0.6 + 0.4 * sin(_t * 1.7 + ph * TAU)))
		Kind.GLINT:
			return pow(maxf(0.0, sin(_t * 0.7 + ph * TAU * 3.0)), 60.0)
		Kind.SPIRE:
			return 0.55 + 0.45 * sin(_t * 0.55 + ph * TAU)
	return 1.0


## Bioluminescence rolling through the forest in long slow waves.
func _wave(pos: Vector2, ph: float) -> float:
	var s := 0.5 + 0.5 * sin(_t * wave_speed - (pos.x * 0.6 + pos.y) / wave_length * TAU + ph * 1.2)
	return 0.35 + 0.65 * s * s


func _draw_halo(pos: Vector2, size_index: int, col: Color, b: float) -> void:
	var c := float(_halo_cell)
	draw_halo_at(_glow_layer, pos, Rect2(size_index * c, 0.0, c, c), Color(col, clampf(b, 0.0, 1.0)))


func draw_halo_at(layer: CanvasItem, pos: Vector2, region: Rect2, col: Color) -> void:
	var c := region.size
	layer.draw_texture_rect_region(_halo, Rect2((pos - c * 0.5).floor(), c), region, col)


## A star glint on snow and ice: one pixel, with arms while it is bright.
func _draw_glint(pos: Vector2, b: float, col: Color) -> void:
	_glow_layer.draw_rect(Rect2(pos, Vector2.ONE), Color(col, b))
	if b > 0.35:
		for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			_glow_layer.draw_rect(Rect2(pos + d, Vector2.ONE), Color(col, b * 0.6))
	if b > 0.7:
		for d in [Vector2(2, 0), Vector2(-2, 0), Vector2(0, 2), Vector2(0, -2)]:
			_glow_layer.draw_rect(Rect2(pos + d, Vector2.ONE), Color(col, b * 0.3))


# ---------------------------------------------------------------- helpers
func _view_rect() -> Rect2:
	var size := get_viewport_rect().size / _camera.zoom
	return Rect2(_camera.get_screen_center_position() - size * 0.5, size)


func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.y / CELL))


func _cells(r: Rect2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var a := _cell_of(r.position)
	var b := _cell_of(r.end)
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			out.append(Vector2i(x, y))
	return out
