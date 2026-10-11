class_name WindFX
extends Node2D
## The weather of each land, drawn over everything: dusty wind on the red plains (soft gusts
## sweeping across the screen as a dithered shader overlay, fine dust motes and quick wind
## streaks), glowing spores drifting up through the alien forest, and snow blowing over the
## ice. Everything is anchored in world space, so it parallaxes as the camera moves, and the
## layers crossfade with the land under the astronaut.

const GUST_SHADER := preload("res://shaders/dust_gusts.gdshader")

@export var wind_dir := Vector2(1.0, 0.2)
## Gust drift speed, px/s.
@export var wind_speed := 34.0
@export var dust_color := Color("#e1a07c")
## Colour of the drifting motes and streaks (a touch lighter than the gusts so they read).
@export var mote_color := Color("#f6d2b0")
@export_range(0.0, 1.0) var gust_strength := 0.2
@export_range(0.0, 1.0) var gust_coverage := 0.55
@export var mote_count := 150
@export var streak_count := 14
@export_group("Forest")
@export var spore_colors: Array[Color] = [Color("#7fffe0"), Color("#ff9ef0"), Color("#e2ff8a"), Color("#a8c8ff")]
@export var spore_haze := Color("#9a86e0")
@export var spore_count := 80
@export_group("Ice")
@export var snow_color := Color("#f4f9ff")
@export var snow_haze := Color("#eef5ff")
@export var snow_count := 190

var _camera: Camera2D
var _gusts: ShaderMaterial
var _layers: Array[CPUParticles2D] = []
var _lands: Array[Node2D] = []       # red, forest, ice
var _biome_source: Callable
var _weights := Vector3(1, 0, 0)


## biome_source returns the land weights (red, forest, ice) where the astronaut stands.
func setup(camera: Camera2D, biome_source: Callable = Callable()) -> void:
	_camera = camera
	_biome_source = biome_source
	z_index = 50  # above the map and the astronaut
	var view := get_viewport_rect().size
	var dir := wind_dir.normalized()
	for i in 3:
		var land := Node2D.new()
		add_child(land)
		_lands.append(land)
	# red: dust
	_add(0, _make_layer(mote_count, 6.0, Vector2(24, 46), _dot(1, 1), 0.9, view, dir, 6.0, [mote_color]))
	_add(0, _make_layer(mote_count / 3, 5.0, Vector2(38, 70), _dot(2, 1), 0.6, view, dir, 6.0, [mote_color]))
	_add(0, _make_layer(streak_count, 1.4, Vector2(150, 220), _dot(5, 1), 0.45, view, dir, 6.0, [mote_color]))
	# forest: spores rising slowly, twinkling as they turn
	var up := Vector2(0.35, -1.0).normalized()
	var spores := _make_layer(spore_count, 9.0, Vector2(4, 11), _dot(1, 1), 1.0, view, up, 55.0, spore_colors, true)
	spores.gravity = Vector2(3.0, -1.5)
	_add(1, spores)
	var fluff := _make_layer(spore_count / 4, 11.0, Vector2(3, 7), _dot(2, 2), 0.55, view, up, 40.0,
			[Color("#c9b8ff"), Color("#9ff5df")], true)
	_add(1, fluff)
	# ice: snow blowing in on the wind, a few hard streaks
	var fall := (dir + Vector2(0, 1.6)).normalized()
	_add(2, _make_layer(snow_count, 6.5, Vector2(18, 34), _dot(1, 1), 0.95, view, fall, 14.0, [snow_color]))
	_add(2, _make_layer(snow_count / 4, 5.0, Vector2(26, 44), _dot(2, 1), 0.7, view, fall, 10.0, [snow_color]))
	_add(2, _make_layer(streak_count, 1.2, Vector2(170, 240), _dot(6, 1), 0.4, view, dir, 4.0, [snow_color]))

	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)
	var overlay := ColorRect.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.012
	noise.fractal_octaves = 3
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.noise = noise
	_gusts = ShaderMaterial.new()
	_gusts.shader = GUST_SHADER
	_gusts.set_shader_parameter("noise_tex", tex)
	_gusts.set_shader_parameter("wind", dir * wind_speed)
	_gusts.set_shader_parameter("dust_color", dust_color)
	_gusts.set_shader_parameter("strength", gust_strength)
	_gusts.set_shader_parameter("coverage", gust_coverage)
	overlay.material = _gusts
	layer.add_child(overlay)
	if _biome_source.is_valid():
		_weights = _biome_source.call()
	_apply_weights()


var _extents := Vector2.ZERO


func _process(delta: float) -> void:
	if _camera == null:
		return
	var center := _camera.get_screen_center_position()
	global_position = center
	var seen := get_viewport_rect().size / _camera.zoom
	_gusts.set_shader_parameter("view_origin", center - seen * 0.5)
	_gusts.set_shader_parameter("view_scale", 1.0 / _camera.zoom.x)
	var extents := seen * 0.5 + Vector2(40, 30)
	if extents != _extents:                   # only changes when the window or the zoom does
		_extents = extents
		for l in _layers:
			l.emission_rect_extents = extents
	if _biome_source.is_valid():
		var w: Vector3 = _biome_source.call()
		_weights = _weights.lerp(w, 1.0 - exp(-1.5 * delta))
		_apply_weights()


func _apply_weights() -> void:
	var w := [_weights.x, _weights.y, _weights.z]
	for i in 3:
		_lands[i].modulate.a = clampf(w[i] * 1.2, 0.0, 1.0)
		_lands[i].visible = w[i] > 0.02
	var col := dust_color * _weights.x + spore_haze * _weights.y + snow_haze * _weights.z
	col.a = 1.0
	_gusts.set_shader_parameter("dust_color", col)
	_gusts.set_shader_parameter("strength", gust_strength * _weights.x + 0.1 * _weights.y + 0.22 * _weights.z)
	_gusts.set_shader_parameter("coverage", gust_coverage * _weights.x + 0.4 * _weights.y + 0.62 * _weights.z)


func _add(land: int, p: CPUParticles2D) -> void:
	_lands[land].add_child(p)
	_layers.append(p)


func _make_layer(amount: int, lifetime: float, speed: Vector2, tex: Texture2D, alpha: float,
		view: Vector2, dir: Vector2, spread: float, colors: Array, glow := false) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.preprocess = lifetime
	p.local_coords = false
	p.texture = tex
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = view * 0.5 + Vector2(40, 30)
	p.direction = dir
	p.spread = spread
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = speed.x
	p.initial_velocity_max = speed.y
	var ramp := Gradient.new()
	if glow:   # spores pulse brighter and dimmer as they drift
		ramp.offsets = PackedFloat32Array([0.0, 0.12, 0.3, 0.45, 0.62, 0.8, 1.0])
		ramp.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, alpha), Color(1, 1, 1, alpha * 0.35),
				Color(1, 1, 1, alpha), Color(1, 1, 1, alpha * 0.4), Color(1, 1, 1, alpha), Color(1, 1, 1, 0.0)])
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		p.material = mat
	else:
		ramp.offsets = PackedFloat32Array([0.0, 0.15, 0.8, 1.0])
		ramp.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, alpha), Color(1, 1, 1, alpha), Color(1, 1, 1, 0.0)])
	p.color_ramp = ramp
	if colors.size() == 1:
		p.color = colors[0]
	else:
		var pick := Gradient.new()
		pick.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
		var offs := PackedFloat32Array()
		var cols := PackedColorArray()
		for i in colors.size():
			offs.append(float(i) / colors.size())
			cols.append(colors[i])
		pick.offsets = offs
		pick.colors = cols
		p.color_initial_ramp = pick
	return p


static func _dot(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)
