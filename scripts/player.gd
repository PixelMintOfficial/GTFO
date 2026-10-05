class_name Player
extends Node2D
## The astronaut. Lives in world coordinates on the map's ground plane and is drawn at
## the projected pixel position, so the iso projection, ground height and depth
## occlusion all come from one place (MapTerrain).
##
## Controls: WASD / arrow keys / left stick to walk in 8 directions, Shift / right
## shoulder to run. Tilting the stick part-way walks slower.

## Screen-space compass, clockwise from east (screen y points down).
const DIRS: Array[String] = ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]

## Speeds are in sprite units/s (1 unit = 1 sprite pixel of height) and are converted to
## map units with the map's character_scale.
## Walking speed at full stick / keyboard.
@export var walk_speed := 71.0
## Playback speed of the walk cycle while walking. The drawn stride covers 19.6 units per
## second at 1x, so this keeps a brisk, natural cadence rather than a frantic one.
@export var walk_anim_scale := 2.4
## Ground speed of the drawn run cycle (from astronaut.json).
@export var run_cycle_speed := 47.368
## How much faster than the drawn run cycle to move when running. The animation speeds up
## by the same factor, so the run keeps its feet planted.
@export var run_pace := 1.8
## Radius around the feet that must be walkable, in sprite units.
@export var foot_radius := 3.2
## How far the sprite reaches in front of / behind its feet, in sprite units (occlusion).
@export var body_depth := 6.0

var terrain: MapTerrain
var world_pos := Vector2.ZERO
var _scale := 1.0
var _dust: CPUParticles2D
var facing := "SE"
## Overrides the controls when non-zero (used by automated test runs).
var forced_input := Vector2.ZERO
var forced_run := false

@onready var sprite: AnimatedSprite2D = $Sprite
@onready var camera: Camera2D = $Camera


func _ready() -> void:
	_ensure_input_actions()
	sprite.play("idle_" + facing)
	_dust = _make_foot_dust()
	add_child(_dust)
	move_child(_dust, 0)  # under the astronaut


func setup(t: MapTerrain, depth_map: Texture2D) -> void:
	terrain = t
	var mat := sprite.material as ShaderMaterial
	mat.set_shader_parameter("depth_map", depth_map)
	mat.set_shader_parameter("map_size", t.map_size)
	mat.set_shader_parameter("depth_scale", t.depth_scale)
	_scale = t.character_scale
	mat.set_shader_parameter("tolerance", body_depth * _scale)
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(t.map_size.x)
	camera.limit_bottom = int(t.map_size.y)
	teleport(t.spawn)


func teleport(p: Vector2) -> void:
	world_pos = p
	_sync()
	camera.reset_smoothing()


func _physics_process(delta: float) -> void:
	if terrain == null:
		return
	var input := forced_input
	if input == Vector2.ZERO:
		input = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var running := forced_run or Input.is_action_pressed("run")
	var tilt := input.length()
	if tilt < 0.25:
		_animate("idle", 1.0)
		_dust.emitting = false
		return

	var step := posmod(int(round(input.angle() / (PI / 4.0))), 8)
	facing = DIRS[step]
	var screen_dir := Vector2.from_angle(step * PI / 4.0)
	var dir := Vector2(screen_dir.x, -screen_dir.y)  # screen up = away from the camera
	var push := clampf(tilt, 0.0, 1.0)
	var speed := run_cycle_speed * run_pace if running else walk_speed * push
	var anim_scale := run_pace if running else walk_anim_scale * push
	var moved := _try_move(dir * speed * _scale * delta)
	if moved:
		_animate("run" if running else "walk", anim_scale)
	else:
		_animate("idle", 1.0)
	_kick_dust(moved, running, screen_dir)
	_sync()


## Moves if the feet would land on walkable ground, sliding along obstacles.
func _try_move(motion: Vector2) -> bool:
	for m in [motion, Vector2(motion.x, 0.0), Vector2(0.0, motion.y)]:
		if m.length_squared() > 0.0001 and _can_stand(world_pos + m):
			world_pos += m
			return true
	return false


func _can_stand(p: Vector2) -> bool:
	if not terrain.is_walkable(p):
		return false
	for k in 4:
		if not terrain.is_walkable(p + Vector2.from_angle(k * PI / 2.0) * foot_radius * _scale):
			return false
	return true


func _sync() -> void:
	position = terrain.to_screen(world_pos, terrain.height_at(world_pos)).round()
	(sprite.material as ShaderMaterial).set_shader_parameter("sprite_depth", world_pos.y)


func _animate(kind: String, speed_scale: float) -> void:
	var anim := "%s_%s" % [kind, facing]
	if sprite.animation != StringName(anim):
		var keep_phase := String(sprite.animation).begins_with(kind + "_")
		var f := sprite.frame
		var progress := sprite.frame_progress
		sprite.play(anim)
		if keep_phase:
			sprite.set_frame_and_progress(f, progress)
	elif not sprite.is_playing():
		sprite.play(anim)
	sprite.speed_scale = speed_scale


## Little puffs of dust behind the boots while walking, more while running.
func _kick_dust(moving: bool, running: bool, screen_dir: Vector2) -> void:
	_dust.emitting = moving
	if not moving:
		return
	_dust.color = Color(1, 1, 1, 1.0 if running else 0.55)
	_dust.direction = Vector2(-screen_dir.x, -0.6 - absf(screen_dir.y) * 0.2)
	_dust.initial_velocity_min = 6.0 if running else 3.0
	_dust.initial_velocity_max = 16.0 if running else 8.0


func _make_foot_dust() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = 18
	p.lifetime = 0.75
	p.local_coords = false
	p.emitting = false
	p.texture = _dot_texture(2)
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(5, 1.5)
	p.spread = 35.0
	p.gravity = Vector2(0, -6)
	p.damping_min = 8.0
	p.damping_max = 14.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	var fade := Gradient.new()
	fade.set_color(0, Color(0.88, 0.66, 0.52, 0.75))
	fade.set_color(1, Color(0.80, 0.56, 0.46, 0.0))
	p.color_ramp = fade
	return p


static func _dot_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)


static func _ensure_input_actions() -> void:
	var keys := {
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"move_up": [KEY_W, KEY_UP],
		"move_down": [KEY_S, KEY_DOWN],
		"run": [KEY_SHIFT],
	}
	var axes := {
		"move_left": [JOY_AXIS_LEFT_X, -1.0],
		"move_right": [JOY_AXIS_LEFT_X, 1.0],
		"move_up": [JOY_AXIS_LEFT_Y, -1.0],
		"move_down": [JOY_AXIS_LEFT_Y, 1.0],
	}
	for action in keys:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.25)
		for key in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
		if axes.has(action):
			var motion := InputEventJoypadMotion.new()
			motion.axis = axes[action][0]
			motion.axis_value = axes[action][1]
			InputMap.action_add_event(action, motion)
	var shoulder := InputEventJoypadButton.new()
	shoulder.button_index = JOY_BUTTON_RIGHT_SHOULDER
	InputMap.action_add_event("run", shoulder)
