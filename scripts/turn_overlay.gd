class_name TurnOverlay
extends CanvasLayer
## The camera's swing round the world, for the moment a turn takes (ViewTurn drives it).
##
## The map is a set of pictures, one per view, so in between two views there is no picture to
## show. For those few tenths of a second the world is stood up in 3D instead: each view's
## picture is laid over the shape its depth map gives it (turn_relief.gdshader), the plants, the
## props and the astronaut stand in it as billboards, and the game's own orthographic camera
## swings round the astronaut. The view it leaves dissolves into the view it arrives at (a pixel
## dither), and at the end the overlay fades into the live, pre-rendered view underneath.
##
## It sits above the world and below the UI, so the time panel and the backpack stay put.

signal finished

const RELIEF := preload("res://shaders/turn_relief.gdshader")
const SPACE := Color("#0b0915")
const PITCH := deg_to_rad(30.0)
## Grid spacing of the relief, in map px at the default zoom (finer looks better, costs more).
const GRID_PX := 2.0
## Margin round the view the reliefs cover, as a share of the view (the swing brings it in).
const MARGIN := 0.65

var _vp: SubViewport
var _cam: Camera3D
var _rect: TextureRect
var _reliefs: Array[MeshInstance3D] = []   # [left, arrived at] front copies, then their back copies
var _grids := {}                 # (subdivide_width, subdivide_depth) -> PlaneMesh, kept and reused
var _boards: Node3D
var _player_board: Sprite3D
var _player: Player
var _views: Array = []           # [from, to] view info (see view_info())
var _psi0 := 0.0                 # camera yaw at the start (radians), and the turn
var _dpsi := 0.0
var _pivot := Vector3.ZERO
var _view_h := 216.0             # map px across the view's height (each view's furthest zoom differs a little)
var _upp := 0.433
var _block := 1.0               # screen px per map px (the dither's grain)
var _t := 0.0
var _time := 0.42
var _running := false


func _ready() -> void:
	layer = 3
	visible = false
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(_vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = SPACE
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_cam.near = 1.0
	_cam.far = 30000.0
	_cam.environment = env
	_vp.add_child(_cam)
	for i in 4:
		var mi := MeshInstance3D.new()
		var m := ShaderMaterial.new()
		m.shader = RELIEF
		mi.material_override = m
		mi.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
		_vp.add_child(mi)
		_reliefs.append(mi)
	_boards = Node3D.new()
	_vp.add_child(_boards)
	_rect = TextureRect.new()
	_rect.texture = _vp.get_texture()
	_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE        # the screen's size, not the texture's
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)


## What a relief needs from one view: its textures and projection, the part of its picture to lay
## out (round the camera), and where the astronaut and the camera are in it.
static func view_info(terrain: MapTerrain, camera: Camera2D, player: Player) -> Dictionary:
	var view := _base_view() / camera.zoom
	camera.force_update_scroll()                             # it may have just jumped (a view switch)
	var centre := camera.get_screen_center_position()       # with the camera's offset (it looks above the feet)
	var rect := Rect2(centre - view * (0.5 + MARGIN), view * (1.0 + 2.0 * MARGIN))
	return {"map": terrain.map_texture, "depth": terrain.depth_map, "light": terrain.light_mask,
			"sun": terrain.sun_mask, "win": MapStream.win_vec(terrain), "origin": terrain.origin,
			"upp": terrain.units_per_px, "dtp": terrain.depth_to_px, "ppu": terrain.px_per_unit,
			"depth_scale": terrain.depth_scale, "heading": terrain.heading, "center": terrain.view_center,
			"rect": rect, "view": view, "player_px": player.global_position,
			"offset": player.global_position - centre}


## Start a turn: `from` the view being left (with the things to stand up in it), `to` the one
## arrived at; `step` +1 / -1 quarter turn.
func begin(from: Dictionary, to: Dictionary, step: int, pivot_world: Vector3, boards: Array, player: Player,
		time: float) -> void:
	_views = [from, to]
	_player = player
	_time = time
	_upp = from["upp"]
	_pivot = _godot(pivot_world)
	_psi0 = from["heading"] * PI * 0.5
	_dpsi = step * PI * 0.5
	var scale := _screen_scale()
	var base := _base_view()
	_vp.size = Vector2i((base * scale).round())
	_block = scale * base.y / from["view"].y
	for i in 2:
		_setup_view(i)
	for c in _boards.get_children():
		c.queue_free()
	_add_boards(boards, true)
	_player_board = _board({"tex": null, "region": Rect2(), "anchor": -player.sprite.offset,
			"world": pivot_world + Vector3(0, 0, -player.sprite.position.y / from["ppu"])})
	_boards.add_child(_player_board)
	_t = 0.0
	_running = true
	_apply(0.0)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_rect.modulate.a = 1.0                       # opaque at once: the world switches underneath
	visible = true


## The view arrived at, once the world has switched under the overlay, and the things standing
## in it as that view draws them (they take over from the view left's halfway through).
func set_arrival(to: Dictionary, boards: Array = []) -> void:
	_views[1] = to
	_setup_view(1)
	_add_boards(boards, false)


func _add_boards(boards: Array, first: bool) -> void:
	for b in boards:
		var s := _board(b)
		s.set_meta("first", first)
		_boards.add_child(s)


func _process(delta: float) -> void:
	if not _running:
		return
	_t += minf(delta, 1.0 / 30.0)                # a slow frame (the switch) doesn't jump the swing
	var k := clampf(_t / _time, 0.0, 1.0)
	_apply(k)
	if k >= 1.0:
		_running = false
		var tw := create_tween()
		tw.tween_property(_rect, "modulate:a", 0.0, 0.14)
		tw.tween_callback(_done)


func _done() -> void:
	visible = false
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	for c in _boards.get_children():
		c.queue_free()
	finished.emit()


## Where the swing is at k (0..1): the camera's yaw, eased like Don't Starve's, and the dissolve.
func _apply(k: float) -> void:
	var e := k * k * k * (k * (k * 6.0 - 15.0) + 10.0)      # smootherstep
	var psi := _psi0 + _dpsi * e
	var basis := Basis(Vector3.UP, psi) * Basis(Vector3.RIGHT, Vector3(0, cos(PITCH), -sin(PITCH)), Vector3(0, sin(PITCH), cos(PITCH)))
	_view_h = lerpf(_views[0]["view"].y, _views[1]["view"].y, e)
	_cam.size = _view_h * _upp
	var off: Vector2 = (_views[0]["offset"] as Vector2).lerp(_views[1]["offset"], e)
	var centre := _pivot - basis.x * (off.x * _upp) + basis.y * (off.y * _upp)
	_cam.transform = Transform3D(basis, centre + basis.z * 12000.0)
	var mix := smoothstep(0.32, 0.68, e)
	for mi in _reliefs:
		var m := mi.material_override as ShaderMaterial
		m.set_shader_parameter("dissolve", mix)
		m.set_shader_parameter("toward", basis.z)
	for b in _boards.get_children():
		var s := b as Sprite3D
		s.modulate = DayNight.light_mul
		s.position = s.get_meta("at") + basis.z * 16.0                     # in front of both views
		if s.has_meta("first"):
			s.visible = s.get_meta("first") == (mix < 0.5)                 # each view's own drawing of it
	_face_player(psi)


## Where a world point (X, Y, Z up) is at swing position k, in map px from the screen's centre
## (for tests: at 0 and 1 it must be where the live views draw it).
func screen_point(world: Vector3, k: float) -> Vector2:
	_apply(k)
	var px_per_vp := _view_h / _vp.size.y
	return (_cam.unproject_position(_godot(world)) - Vector2(_vp.size) * 0.5) * px_per_vp


## The astronaut keeps facing the same way in the world while the camera goes round them, so
## their sprite turns through the eight directions as the camera passes.
func _face_player(psi: float) -> void:
	if _player == null or _player_board == null:
		return
	var w := _player.facing_dir()
	var v := w.rotated(-psi)                    # the world direction as the turning camera sees it
	var sd := Vector2(v.x, -v.y)
	var dir: String = Player.DIRS[posmod(int(round(sd.angle() / (PI / 4.0))), 8)]
	var kind := String(_player.sprite.animation)
	kind = kind.substr(0, kind.rfind("_"))
	var anim := StringName("%s_%s" % [kind, dir])
	var frames := _player.sprite.sprite_frames
	if not frames.has_animation(anim):
		return
	_player_board.texture = frames.get_frame_texture(anim, mini(_player.sprite.frame, frames.get_frame_count(anim) - 1))
	_player_board.modulate = DayNight.light_mul


## The relief's grid of vertices. Building one is tens of milliseconds at the sizes used here
## (up to 600x600 subdivisions), and a turn lays out three of them, so they are kept: only the
## subdivision counts vary, and there are only a handful of those (one per zoom level).
func _grid(sw: int, sh: int) -> PlaneMesh:
	var key := Vector2i(sw, sh)
	if _grids.has(key):
		return _grids[key]
	var pm := PlaneMesh.new()
	pm.size = Vector2.ONE
	pm.subdivide_width = sw
	pm.subdivide_depth = sh
	_grids[key] = pm
	return pm


## Lay view i (0 the view left, 1 the view arrived at) out on its two reliefs, front and back.
func _setup_view(i: int) -> void:
	var v: Dictionary = _views[i]
	var rect: Rect2 = v["rect"]
	var spacing: float = GRID_PX * v["view"].y / 216.0
	var pm := _grid(clampi(int(rect.size.x / spacing), 8, 600), clampi(int(rect.size.y / spacing), 8, 600))
	for front in [true, false]:
		var mi := _reliefs[i if front else i + 2]
		mi.mesh = pm
		var m := mi.material_override as ShaderMaterial
		m.set_shader_parameter("first", i == 0)
		m.set_shader_parameter("front", front)
		_set_view_params(m, v)


func _set_view_params(m: ShaderMaterial, v: Dictionary) -> void:
	var rect: Rect2 = v["rect"]
	m.set_shader_parameter("map_tex", v["map"])
	m.set_shader_parameter("depth_tex", v["depth"])
	m.set_shader_parameter("light_tex", v["light"])
	m.set_shader_parameter("sun_tex", v["sun"])
	m.set_shader_parameter("win", v["win"])
	m.set_shader_parameter("origin", v["origin"])
	m.set_shader_parameter("upp", v["upp"])
	m.set_shader_parameter("dtp", v["dtp"])
	m.set_shader_parameter("ppu", v["ppu"])
	m.set_shader_parameter("depth_scale", v["depth_scale"])
	m.set_shader_parameter("heading", v["heading"])
	m.set_shader_parameter("view_center", v["center"])
	m.set_shader_parameter("rect", Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
	m.set_shader_parameter("block", _block)
	m.set_shader_parameter("lamp_px", v["player_px"])


## Something standing in the world, as a billboard: texture region, the anchor where it stands
## (px from the frame's top left), and that point in the world.
func _board(b: Dictionary) -> Sprite3D:
	var s := Sprite3D.new()
	s.texture = b["tex"]
	if (b["region"] as Rect2).size != Vector2.ZERO:
		s.region_enabled = true
		s.region_rect = b["region"]
	s.pixel_size = _upp
	s.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	s.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	s.shaded = false
	s.double_sided = true
	s.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	s.centered = false
	var h: float = (b["region"] as Rect2).size.y if (b["region"] as Rect2).size != Vector2.ZERO else 64.0
	s.offset = Vector2(-b["anchor"].x, -(h - b["anchor"].y))
	s.set_meta("at", _godot(b["world"]))
	s.position = _godot(b["world"])
	return s


static func _godot(w: Vector3) -> Vector3:
	return Vector3(w.x, w.z, -w.y)


## Screen px per canvas px (the window's integer scale).
func _screen_scale() -> float:
	var win := Vector2(get_window().size)
	var base := _base_view()
	return maxf(1.0, floorf(minf(win.x / base.x, win.y / base.y)))


static func _base_view() -> Vector2:
	return Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height"))
