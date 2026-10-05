class_name Player
extends Node2D
## The astronaut. Lives in world coordinates on the map's ground plane and is drawn at
## the projected pixel position, so the iso projection, ground height and depth
## occlusion all come from one place (MapTerrain).
##
## Controls: WASD / arrow keys / left stick to walk in 8 directions, Shift / right
## shoulder to run, Space / A to jump (hold for a higher, floatier jump). Tilting the
## stick part-way walks slower.

## Screen-space compass, clockwise from east (screen y points down).
const DIRS: Array[String] = ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]

enum Jump { GROUNDED, CROUCH, AIR, LAND }

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

@export_group("Low-gravity jump")
## Upward speed at take-off, sprite units/s. Height is in sprite units = screen pixels.
@export var jump_velocity := 160.0
## Gravity while the jump button is held on the way up.
@export var gravity_rise := 230.0
## Gravity on the way up after letting go early (a shorter hop).
@export var gravity_cut := 560.0
## Gravity on the way down.
@export var gravity_fall := 250.0
## Gravity multiplier near the top of the jump, for that floaty moon hang.
@export_range(0.1, 1.0) var apex_float := 0.45
## Vertical speed (either way) counted as "near the top".
@export var apex_band := 40.0
@export var crouch_time := 0.09
@export var land_time := 0.16
## Horizontal speed multiplier while crouching to jump or recovering from a landing.
@export_range(0.0, 1.0) var squash_speed := 0.6

var terrain: MapTerrain
var world_pos := Vector2.ZERO
var facing := "SE"
## Overrides the controls when non-zero (used by automated test runs).
var forced_input := Vector2.ZERO
var forced_run := false
## Jump on a timer (automated test runs); 0 = off.
var auto_jump_every := 0.0

var _scale := 1.0
var _dust: CPUParticles2D
var _jump := Jump.GROUNDED
var _jt := 0.0            # time in the current jump state
var _z := 0.0             # height above the ground, sprite units
var _vz := 0.0
var _jump_buffer := 0.0
var _auto_t := 0.0
var _dot2: ImageTexture
var _dot1: ImageTexture

@onready var sprite: AnimatedSprite2D = $Sprite
@onready var shadow: Sprite2D = $Shadow
@onready var camera: GameCamera = $Camera


func _ready() -> void:
	_ensure_input_actions()
	_dot1 = _dot_texture(1)
	_dot2 = _dot_texture(2)
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
	camera.snap()


func is_airborne() -> bool:
	return _jump == Jump.AIR


func _physics_process(delta: float) -> void:
	if terrain == null:
		return
	var input := forced_input
	if input == Vector2.ZERO:
		input = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var running := forced_run or Input.is_action_pressed("run")
	var tilt := input.length()
	_read_jump_input(delta)

	var moved := false
	var screen_dir := Vector2.ZERO
	var anim_scale := 1.0
	if tilt >= 0.25:
		var step := posmod(int(round(input.angle() / (PI / 4.0))), 8)
		facing = DIRS[step]
		screen_dir = Vector2.from_angle(step * PI / 4.0)
		var dir := Vector2(screen_dir.x, -screen_dir.y)  # screen up = away from the camera
		var push := clampf(tilt, 0.0, 1.0)
		var speed := run_cycle_speed * run_pace if running else walk_speed * push
		anim_scale = run_pace if running else walk_anim_scale * push
		if _jump == Jump.CROUCH or _jump == Jump.LAND:
			speed *= squash_speed
		moved = _try_move(dir * speed * _scale * delta)

	_step_jump(delta)
	if _jump == Jump.GROUNDED:
		if moved:
			_animate("run" if running else "walk", anim_scale)
		else:
			_animate("idle", 1.0)
		_kick_dust(moved, running, screen_dir)
	else:
		_dust.emitting = false
		_show_jump_frame()
	_sync()


# ---------------------------------------------------------------- jump
func _read_jump_input(delta: float) -> void:
	_jump_buffer = maxf(0.0, _jump_buffer - delta)
	var pressed := Input.is_action_just_pressed("jump")
	if auto_jump_every > 0.0:
		_auto_t += delta
		if _auto_t >= auto_jump_every:
			_auto_t = 0.0
			pressed = true
	if pressed:
		_jump_buffer = 0.15  # a press just before landing still counts
	if _jump_buffer > 0.0 and _jump == Jump.GROUNDED:
		_jump_buffer = 0.0
		_jump = Jump.CROUCH
		_jt = 0.0


func _step_jump(delta: float) -> void:
	match _jump:
		Jump.CROUCH:
			_jt += delta
			if _jt >= crouch_time:
				_jump = Jump.AIR
				_jt = 0.0
				_vz = jump_velocity
				_burst(0.45, false)
		Jump.AIR:
			_jt += delta
			var held := Input.is_action_pressed("jump") or auto_jump_every > 0.0
			var g := gravity_fall if _vz < 0.0 else (gravity_rise if held else gravity_cut)
			if absf(_vz) < apex_band:
				g *= apex_float
			_vz -= g * delta
			_z += _vz * delta
			if _z <= 0.0:
				var impact := -_vz
				_z = 0.0
				_vz = 0.0
				_jump = Jump.LAND
				_jt = 0.0
				_burst(clampf(impact / jump_velocity, 0.45, 1.25), true)
		Jump.LAND:
			_jt += delta
			if _jt >= land_time:
				_jump = Jump.GROUNDED


## Frames of the jump sheet are poses; pick the one that matches the physics.
func _show_jump_frame() -> void:
	var f := 0
	match _jump:
		Jump.CROUCH:
			f = 0 if _jt < crouch_time * 0.5 else 1
		Jump.AIR:
			if _jt < 0.07:
				f = 2                                   # take-off stretch
			elif _vz > jump_velocity * 0.55:
				f = 3                                   # rising
			elif _vz > apex_band:
				f = 4                                   # tucking in
			elif _vz > -apex_band:
				f = 5 + int(_jt * 8.0) % 3              # floating at the top
			elif _vz > -jump_velocity * 0.6:
				f = 8                                   # starting to fall
			else:
				f = 9                                   # legs reaching for the ground
		Jump.LAND:
			f = 10 if _jt < land_time * 0.5 else 11
	var anim := StringName("jump_" + facing)
	if sprite.animation != anim:
		sprite.animation = anim
	if sprite.is_playing():
		sprite.pause()
	sprite.frame = f


## Dust ring flattened onto the ground plane, plus pebbles kicked up on landing.
func _burst(strength: float, landing: bool) -> void:
	var root := get_parent()
	var ring := CPUParticles2D.new()
	ring.one_shot = true
	ring.explosiveness = 1.0
	ring.amount = 36 if landing else 14
	ring.lifetime = 0.7
	ring.local_coords = true
	ring.texture = _dot2
	ring.spread = 180.0
	ring.direction = Vector2.RIGHT
	ring.gravity = Vector2(0, -24)
	ring.initial_velocity_min = 34.0 * strength
	ring.initial_velocity_max = 72.0 * strength
	ring.damping_min = 70.0
	ring.damping_max = 110.0
	ring.scale_amount_min = 1.0
	ring.scale_amount_max = 3.0
	ring.color_ramp = _fade(Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.0))
	ring.color_initial_ramp = _fade(Color("#fff0dc"), Color("#a5664f"))  # reads on light and dark ground
	ring.position = position
	ring.scale = Vector2(1.0, 0.5)  # iso ground plane
	_spawn(root, ring)
	if landing:
		var debris := CPUParticles2D.new()
		debris.one_shot = true
		debris.explosiveness = 0.9
		debris.amount = 9
		debris.lifetime = 0.55
		debris.local_coords = true
		debris.texture = _dot1
		debris.direction = Vector2.UP
		debris.spread = 65.0
		debris.gravity = Vector2(0, 170)
		debris.initial_velocity_min = 22.0 * strength
		debris.initial_velocity_max = 52.0 * strength
		debris.scale_amount_min = 1.0
		debris.scale_amount_max = 2.0
		debris.color_ramp = _fade(Color(0.42, 0.24, 0.24, 1.0), Color(0.42, 0.24, 0.24, 0.0))
		debris.position = position
		_spawn(root, debris)


func _spawn(root: Node, p: CPUParticles2D) -> void:
	root.add_child(p)
	root.move_child(p, get_index())  # just under the astronaut
	p.emitting = true
	p.finished.connect(p.queue_free)


static func _fade(from: Color, to: Color) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, from)
	g.set_color(1, to)
	return g


# ---------------------------------------------------------------- movement
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
	sprite.position.y = -roundf(_z)
	var lift := clampf(_z / 70.0, 0.0, 1.0)
	shadow.scale = Vector2.ONE * lerpf(1.0, 0.55, lift)
	shadow.modulate.a = lerpf(1.0, 0.45, lift)
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
	p.texture = _dot2
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(5, 1.5)
	p.spread = 35.0
	p.gravity = Vector2(0, -6)
	p.damping_min = 8.0
	p.damping_max = 14.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	p.color_ramp = _fade(Color(0.88, 0.66, 0.52, 0.75), Color(0.80, 0.56, 0.46, 0.0))
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
		"jump": [KEY_SPACE],
	}
	var axes := {
		"move_left": [JOY_AXIS_LEFT_X, -1.0],
		"move_right": [JOY_AXIS_LEFT_X, 1.0],
		"move_up": [JOY_AXIS_LEFT_Y, -1.0],
		"move_down": [JOY_AXIS_LEFT_Y, 1.0],
	}
	var buttons := {"run": JOY_BUTTON_RIGHT_SHOULDER, "jump": JOY_BUTTON_A}
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
		if buttons.has(action):
			var b := InputEventJoypadButton.new()
			b.button_index = buttons[action]
			InputMap.action_add_event(action, b)
