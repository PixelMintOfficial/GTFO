class_name WindFX
extends Node2D
## Dusty wind for the overworld: soft gusts sweeping across the screen (a dithered
## shader overlay), fine dust motes drifting past and quick wind streaks. Everything is
## anchored in world space, so it parallaxes naturally as the camera follows the player.

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

var _camera: Camera2D
var _gusts: ShaderMaterial


func setup(camera: Camera2D) -> void:
	_camera = camera
	z_index = 50  # above the map and the astronaut
	var view := get_viewport_rect().size
	var dir := wind_dir.normalized()
	add_child(_make_layer(mote_count, 6.0, Vector2(24, 46), _dot(1, 1), 0.9, view, dir, mote_color))
	add_child(_make_layer(mote_count / 3, 5.0, Vector2(38, 70), _dot(2, 1), 0.6, view, dir, mote_color))
	add_child(_make_layer(streak_count, 1.4, Vector2(150, 220), _dot(5, 1), 0.45, view, dir, mote_color))

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


func _process(_delta: float) -> void:
	if _camera == null:
		return
	var center := _camera.get_screen_center_position()
	global_position = center
	_gusts.set_shader_parameter("view_origin", center - get_viewport_rect().size * 0.5)


func _make_layer(amount: int, lifetime: float, speed: Vector2, tex: Texture2D, alpha: float,
		view: Vector2, dir: Vector2, col: Color) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = amount
	p.lifetime = lifetime
	p.preprocess = lifetime
	p.local_coords = false
	p.texture = tex
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = view * 0.5 + Vector2(40, 30)
	p.direction = dir
	p.spread = 6.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = speed.x
	p.initial_velocity_max = speed.y
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.15, 0.8, 1.0])
	ramp.colors = PackedColorArray([Color(col, 0.0), Color(col, alpha), Color(col, alpha), Color(col, 0.0)])
	p.color_ramp = ramp
	return p


static func _dot(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)
