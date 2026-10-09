class_name Player
extends Node2D
## The astronaut. Lives in world coordinates on the map's ground plane and is drawn at
## the projected pixel position, so the iso projection, ground height and depth
## occlusion all come from one place (MapTerrain).
##
## Controls: WASD / arrow keys / left stick to walk in 8 directions, Shift / right
## shoulder to run, Space / A to jump (hold for a higher, floatier jump). Tilting the
## stick part-way walks slower.
##
## The multitool (see Multitool) rides on the backpack: toggle_tool() draws it with a short
## animation and puts it back by playing that in reverse. While it is out, every animation has
## a version with the tool in hand; while it works on something, the astronaut plants their
## feet, faces the target and holds it out ("use").
##
## Terrain: you walk on WALK ground and glide along anything in the way. STEEP ground
## (crater walls, cliffs, boulders) can't be walked but can be jumped over, onto or down;
## land on it and you skid down to the next safe footing. SOLID things always block.
## Boxes (MapTerrain.platforms): their sides stop you, a held jump lands you on top, and walking
## off the edge drops you back down. If one gives way under you, collapse() knocks you down.

## Every landing from a jump or a fall, with how fast the feet came down (sprite units/s).
signal landed(impact: float)

## Screen-space compass, clockwise from east (screen y points down).
const DIRS: Array[String] = ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]
## A drop this big under the feet (world units), walking off the edge of a box, is a fall.
const LEDGE := 1.5
## Directions tried, in order, when the way ahead is blocked: glide along the obstacle.
const GLIDE_ANGLES: Array[float] = [0.0, 0.4, -0.4, 0.8, -0.8, 1.2, -1.2]

enum Jump { GROUNDED, CROUCH, AIR, LAND, SLIDE }
enum Tool { HOLSTERED, EQUIPPING, READY, HOLSTERING }
const SPRITE_JSON := "res://assets/characters/astronaut/astronaut.json"

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
## Radius around the feet that must be clear, in sprite units.
@export var foot_radius := 3.2
## How far the sprite reaches in front of / behind its feet, in sprite units (occlusion).
@export var body_depth := 6.0
## Speed of skidding down ground too steep to stand on.
@export var slide_speed := 110.0

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
## How long it takes to get back up after collapse() (a box giving way under you).
@export var collapse_time := 0.9
## Horizontal speed multiplier while crouching to jump or recovering from a landing.
@export_range(0.0, 1.0) var squash_speed := 0.6

var terrain: MapTerrain
var world_pos := Vector2.ZERO
var facing := "SE"
## Overrides the controls when non-zero (used by automated test runs).
var forced_input := Vector2.ZERO
var forced_run := false
## Environment adapters can disable suit air or mark the head submerged. Scenery pools
## currently have no swimming volume; the intact suit supplies breathable air by default.
var breathable := true
var head_submerged := false
## Scene callback reports local air safety using authored world metadata.
var air_source: Callable
var sprinting := false
## Off while a cutscene plays: the astronaut stands still and ignores the pad.
var controls_enabled := true
## The camera is turning round the world (ViewTurn): stand and wait.
var turning := false
## A cutscene is moving the astronaut (puppet_walk / puppet_face); physics and input pause.
var puppet := false
## Never shown as a silhouette behind scenery (walking through an airlock door).
var ignore_occlusion := false
## Jump on a timer (automated test runs); 0 = off.
var auto_jump_every := 0.0
## What the boots are hitting, as a sound name ("step_dust", "step_snow", "step_metal", ...).
## The scene sets it: the overworld reads the land under the feet, the interior is always its
## tiled floor. Takes nothing, returns a String.
var step_source: Callable
## The multitool: on the backpack, being drawn, in hand, or being put away.
var tool_state := Tool.HOLSTERED
## While the tool is working on something: the world point to face and aim at (else null).
var work_target: Variant = null

var _scale := 1.0
var _dust: CPUParticles2D
var _jump := Jump.GROUNDED
var _jt := 0.0            # time in the current jump state
var _land_for := 0.0      # how long this landing keeps you crouched
var _downed := false      # knocked down (collapse): no control until back on your feet
var _feet := 0.0          # height of the feet, world units (the ground when standing)
var _vz := 0.0            # vertical speed, sprite units/s
var _jump_buffer := 0.0
var _auto_t := 0.0
var _stuck := 0.0
var _dot2: ImageTexture
var _dot1: ImageTexture
var _step_frame := -1      # last animation frame a footstep was checked against
var _tips := {}           # animation -> direction -> per frame [x, y, visible] of the tool's lens
var _lit_frame := 5       # equip frame where the lens lights
## Equip frames from the device bursting open to the armour locking onto the arm.
var open_frames := Vector2i(-1, -1)

@onready var sprite: AnimatedSprite2D = $Sprite
@onready var shadow: Sprite2D = $Shadow
@onready var camera: GameCamera = $Camera


func can_breathe() -> bool:
	return breathable and not head_submerged and (not air_source.is_valid() or bool(air_source.call()))


func take_damage(amount: float, cause := "INJURY") -> void:
	GameState.survival.damage(amount, cause)


func _ready() -> void:
	_ensure_input_actions()
	_dot1 = _dot_texture(1)
	_dot2 = _dot_texture(2)
	sprite.play("idle_" + facing)
	_load_tool_tips()
	_dust = _make_foot_dust()
	add_child(_dust)
	move_child(_dust, 0)  # under the astronaut


func setup(t: MapTerrain) -> void:
	terrain = t
	var mat := sprite.material as ShaderMaterial
	mat.set_shader_parameter("depth_scale", t.depth_scale)
	refresh_window()
	_scale = t.character_scale
	mat.set_shader_parameter("tolerance", body_depth * _scale)
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = int(t.map_size.x)
	camera.limit_bottom = int(t.map_size.y)
	teleport(t.spawn)


func teleport(p: Vector2) -> void:
	world_pos = p
	_feet = _ground()
	_jump = Jump.GROUNDED
	_downed = false
	_sync()
	camera.snap()


func is_airborne() -> bool:
	return _jump == Jump.AIR


## How high the feet are above the floor under them, world units (on a box: its height).
func height_above_floor() -> float:
	return _feet - terrain.height_at(world_pos)


## Knocked off your feet (a box giving way under you): you drop, land hard, stay down a moment
## (collapse_time) and get back up. The controls wait until you have.
func collapse() -> void:
	_downed = true
	if _jump != Jump.AIR:
		_jump = Jump.AIR
		_jt = 0.07
		_vz = 0.0


## Cutscenes: walk straight toward a world point (no collisions) at a fraction of walking
## speed. Returns true once there.
func puppet_walk(target: Vector2, pace: float, delta: float) -> bool:
	var to := target - world_pos
	var step := walk_speed * pace * _scale * delta
	if to.length() <= step:
		world_pos = target
		_sync()
		return true
	world_pos += to.normalized() * step
	_set_facing(to)
	_animate("walk", walk_anim_scale * pace)
	_sync()
	return false


## Cutscenes: stand still, facing a world direction.
func puppet_face(d: Vector2) -> void:
	_set_facing(d)
	_animate("idle", 1.0)
	_sync()


func _set_facing(d: Vector2) -> void:
	if d.length() > 0.001:
		var v := terrain.view_dir(d) if terrain != null else d
		var sd := Vector2(v.x, -v.y)
		facing = DIRS[posmod(int(round(sd.angle() / (PI / 4.0))), 8)]


## The camera turned: face the same way in the world, and see the new view's depth.
func refresh_view(world_facing: Vector2) -> void:
	refresh_window()
	camera.limit_right = int(terrain.map_size.x)
	camera.limit_bottom = int(terrain.map_size.y)
	_set_facing(world_facing)
	if tool_state == Tool.READY and work_target == null or tool_state == Tool.HOLSTERED:
		_animate("idle", 1.0)
	_sync()


## Take the multitool out, or put it away (only with both feet on the ground).
func toggle_tool() -> void:
	if _jump != Jump.GROUNDED:
		return
	if tool_state == Tool.HOLSTERED:
		tool_state = Tool.EQUIPPING
		sprite.speed_scale = 1.0
		sprite.play("equip_" + facing)
		Audio.play("tool_unfold", global_position)
	elif tool_state == Tool.READY:
		tool_state = Tool.HOLSTERING
		work_target = null
		sprite.speed_scale = 1.3
		sprite.play_backwards("equip_" + facing)
		Audio.play("tool_fold", global_position)


## Put the multitool straight in hand (or away), no animation: after a scene change.
func set_tool_out(on: bool) -> void:
	tool_state = Tool.READY if on else Tool.HOLSTERED
	_animate("idle", 1.0)


## True once the lens has lit during the draw (and until it goes dark while putting it away).
func tool_lit() -> bool:
	match tool_state:
		Tool.READY:
			return true
		Tool.EQUIPPING, Tool.HOLSTERING:
			return sprite.frame >= _lit_frame
	return false


## Map position of the multitool's lens in the current frame; z = 1 if the body doesn't hide it.
func tool_tip() -> Vector3:
	var name := String(sprite.animation)
	var cut := name.rfind("_")
	var table: Dictionary = _tips.get(name.substr(0, cut), {})
	var row: Array = table.get(name.substr(cut + 1), [])
	if row.is_empty():
		var p := global_position + sprite.position + Vector2(0, -22)
		return Vector3(p.x, p.y, 0.0)
	var f: Array = row[clampi(sprite.frame, 0, row.size() - 1)]
	var q := global_position + sprite.position + sprite.offset + Vector2(f[0], f[1])
	return Vector3(q.x, q.y, f[2])


## Unit world direction the astronaut faces.
func facing_dir() -> Vector2:
	var a := DIRS.find(facing) * PI / 4.0
	var v := Vector2(cos(a), -sin(a))
	return terrain.world_dir(v) if terrain != null else v


func _load_tool_tips() -> void:
	var m = JSON.parse_string(FileAccess.get_file_as_string(SPRITE_JSON))
	if m == null:
		return
	for anim in m["animations"]:
		var info: Dictionary = m["animations"][anim]
		if info.has("lit_frame"):
			_lit_frame = int(info["lit_frame"])
		if info.has("open_frames"):
			open_frames = Vector2i(int(info["open_frames"][0]), int(info["open_frames"][1]))
		if not info.has("tool_tip"):
			continue
		var t := {}
		for i in info["directions"].size():
			t[info["directions"][i]] = info["tool_tip"][i]
		_tips[anim] = t


## What the camera follows: halfway between the ground (or the box) and the astronaut in the air.
## The depth map the astronaut is hidden behind is only a window on the view (MapStream), and
## it moves as the camera does. Point the shader at where it is now.
func refresh_window() -> void:
	var mat := sprite.material as ShaderMaterial
	mat.set_shader_parameter("depth_map", terrain.depth_map)
	mat.set_shader_parameter("map_win", MapStream.win_vec(terrain))


func camera_focus() -> Vector2:
	return global_position + (sprite.position + shadow.position) * 0.5


func _physics_process(delta: float) -> void:
	sprinting = false
	if terrain == null or puppet:
		return
	var input := forced_input
	if input == Vector2.ZERO and controls_enabled and not turning:
		input = Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var running := forced_run or (controls_enabled and not turning and Input.is_action_pressed("run"))
	if tool_state == Tool.EQUIPPING or tool_state == Tool.HOLSTERING:
		_step_tool_draw(delta)
		return
	if tool_state == Tool.READY and work_target != null:
		_step_working(delta)
		return
	var tilt := input.length()
	_read_jump_input(delta)

	var moved := false
	var screen_dir := Vector2.ZERO
	var anim_scale := 1.0
	if tilt >= 0.25 and _jump != Jump.SLIDE and not _downed:
		var step := posmod(int(round(input.angle() / (PI / 4.0))), 8)
		facing = DIRS[step]
		screen_dir = Vector2.from_angle(step * PI / 4.0)
		var dir := terrain.world_dir(Vector2(screen_dir.x, -screen_dir.y))  # screen up = away from the camera
		var push := clampf(tilt, 0.0, 1.0)
		var speed := run_cycle_speed * run_pace if running else walk_speed * push
		anim_scale = run_pace if running else walk_anim_scale * push
		if _jump == Jump.CROUCH or _jump == Jump.LAND:
			speed *= squash_speed
		moved = _try_move(dir * speed * _scale * delta)
		sprinting = moved and running

	_step_vertical(delta)
	if _jump == Jump.GROUNDED:
		if moved:
			_animate("run" if running else "walk", anim_scale)
		else:
			_animate("idle", 1.0)
		_kick_dust(moved, running, screen_dir)
		_listen_for_footfall(moved)
	else:
		_dust.emitting = false
		_show_jump_frame()
	_sync()


# ---------------------------------------------------------------- the multitool
## Drawing or putting away the tool: stand still and let the animation play out.
func _step_tool_draw(delta: float) -> void:
	_dust.emitting = false
	_step_vertical(delta)
	if not sprite.is_playing():
		tool_state = Tool.READY if tool_state == Tool.EQUIPPING else Tool.HOLSTERED
		sprite.speed_scale = 1.0
		_animate("idle", 1.0)
	_sync()


## Working: feet planted, turned to the target, tool held out.
func _step_working(delta: float) -> void:
	_dust.emitting = false
	var to: Vector2 = work_target - world_pos
	if to.length() > 0.5:
		_set_facing(to)
	var anim := StringName("use_" + facing)
	if sprite.animation != anim:
		sprite.play(anim)
	sprite.speed_scale = 1.0
	_step_vertical(delta)
	_sync()


# ---------------------------------------------------------------- movement
## Moves if the feet can be at the new spot; when blocked, glides along the obstacle.
func _try_move(motion: Vector2) -> bool:
	if motion.length_squared() < 0.000001:
		return false
	var airborne := _jump == Jump.AIR
	for a in GLIDE_ANGLES:
		var m := motion.rotated(a) * cos(a)
		if _can_be(world_pos + m, airborne):
			world_pos += m
			return true
	# head-on into something round (a tree trunk, a boulder): take the open direction closest
	# to where the stick points, even a little backwards, and work around it
	var dir := motion.normalized()
	var best := Vector2.ZERO
	var best_dot := -0.35
	for k in 16:
		var t := Vector2.from_angle(k * TAU / 16.0)
		var dt := t.dot(dir)
		if dt > best_dot and _can_be(world_pos + t * motion.length() * 0.7, airborne):
			best = t * motion.length() * 0.7
			best_dot = dt
	if best == Vector2.ZERO:
		return false
	world_pos += best
	return true


## On foot every sample around the feet must be walkable and not up the side of a box; in the
## air the ground (or box top) there just has to be below the feet (and not a building).
func _can_be(p: Vector2, airborne: bool) -> bool:
	for k in 5:
		var q := p if k == 4 else p + Vector2.from_angle(k * PI / 2.0) * foot_radius * _scale
		var s := terrain.surface(q)
		if s == MapTerrain.Surface.SOLID:
			return false
		if airborne:
			if terrain.stand_height(q) > _feet + 0.75:
				return false
		elif s != MapTerrain.Surface.WALK or terrain.platform_top(q) > _feet + 1.0:
			return false
	return true


## What the boots stand on: the ground, or the top of a box if either boot is over it.
func _ground() -> float:
	var g := terrain.height_at(world_pos)
	if terrain.platforms.is_empty():
		return g
	for k in 5:
		var q := world_pos if k == 4 else world_pos + Vector2.from_angle(k * PI / 2.0) * foot_radius * _scale
		g = maxf(g, terrain.platform_top(q))
	return g


func _not_solid(p: Vector2) -> bool:
	for k in 5:
		var q := p if k == 4 else p + Vector2.from_angle(k * PI / 2.0) * foot_radius * _scale
		if terrain.surface(q) == MapTerrain.Surface.SOLID:
			return false
	return true


# ---------------------------------------------------------------- jump, fall, skid
func _read_jump_input(delta: float) -> void:
	_jump_buffer = maxf(0.0, _jump_buffer - delta)
	var pressed := controls_enabled and not turning and not _downed and Input.is_action_just_pressed("jump") and work_target == null
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


func _step_vertical(delta: float) -> void:
	var ground := _ground()
	if _jump != Jump.SLIDE and Audio.is_looping("slide"):
		Audio.release("slide")           # however the skid ended, the scrape stops with it
	match _jump:
		Jump.GROUNDED:
			if _feet - ground > LEDGE:   # walked off the edge of a box (or it went): fall
				_jump = Jump.AIR
				_jt = 0.07
				_vz = 0.0
				return
			_feet = ground
			if not _can_be(world_pos, false):
				_start_slide()
		Jump.CROUCH:
			_feet = ground
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
			_feet += _vz * _scale * delta
			if _feet <= ground:
				var impact := -_vz
				_feet = ground
				_vz = 0.0
				if _can_be(world_pos, false):
					_jump = Jump.LAND
					_jt = 0.0
					_land_for = collapse_time if _downed else land_time
					_burst(1.25 if _downed else clampf(impact / jump_velocity, 0.45, 1.25), true)
					if _downed:
						camera.shake(1.8, 0.3)
				else:
					_burst(0.5, true)
					_start_slide()
				landed.emit(impact)
		Jump.LAND:
			_feet = ground
			_jt += delta
			if _jt >= _land_for:
				_jump = Jump.GROUNDED
				_downed = false
		Jump.SLIDE:
			_slide(delta)


func _start_slide() -> void:
	_jump = Jump.SLIDE
	_jt = 0.0
	_stuck = 0.0


## Skid down ground too steep to stand on until there is safe footing.
func _slide(delta: float) -> void:
	_jt += delta
	Audio.loop("slide", "slide", global_position)
	var before := world_pos
	var down := terrain.downhill(world_pos)
	if down != Vector2.ZERO:
		var step := down * slide_speed * _scale * delta
		for a in [0.0, 0.5, -0.5, 1.0, -1.0]:
			var m := step.rotated(a)
			if _not_solid(world_pos + m):
				world_pos += m
				break
	_feet = _ground()
	if _can_be(world_pos, false):
		_jump = Jump.LAND
		_jt = 0.0
		_land_for = collapse_time if _downed else land_time
		_burst(0.35, true)
		return
	_stuck = _stuck + delta if world_pos.distance_squared_to(before) < 0.0001 else 0.0
	if _stuck > 0.4 or _jt > 3.0:
		_rescue()


## Last resort if a skid can't find footing: step to the nearest spot you can stand on.
func _rescue() -> void:
	for r in range(2, 60, 2):
		for k in 16:
			var p := world_pos + Vector2.from_angle(k * TAU / 16.0) * float(r) * _scale
			if _can_be(p, false):
				world_pos = p
				_feet = _ground()
				_jump = Jump.LAND
				_jt = 0.0
				_land_for = collapse_time if _downed else land_time
				return


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
			f = 10 if _jt < _land_for * 0.5 else 11
		Jump.SLIDE:
			f = 10                                      # crouched, arms out: skidding
	var anim := StringName(("jump_tool_" if tool_state == Tool.READY else "jump_") + facing)
	if sprite.animation != anim:
		sprite.animation = anim
	if sprite.is_playing():
		sprite.pause()
	sprite.frame = f


## Dust ring flattened onto the ground plane, plus pebbles kicked up on landing.
func _burst(strength: float, landing: bool) -> void:
	if landing:
		# A short hop and a drop off a cliff are the same animation but not the same sound.
		var hard := strength > 0.8
		Audio.play("land_hard" if hard else "land_soft", global_position, 1.0,
				lerpf(-7.0, 1.0, clampf(strength / 1.25, 0.0, 1.0)))
	else:
		Audio.play("jump", global_position)
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
	ring.position = position + shadow.position      # on whatever the feet are on (a box top)
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
		debris.position = position + shadow.position
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


# ---------------------------------------------------------------- drawing
## Drawn at the floor under the feet (that is the y-sort key); the sprite is raised to the feet and
## the shadow to what is under them. Over a box (or on it), drawn above the box.
func _sync() -> void:
	var base := terrain.height_at(world_pos)
	var ground := maxf(base, _ground())
	position = terrain.to_screen(world_pos, base).round()
	var above := maxf(0.0, _feet - base) * terrain.px_per_unit
	sprite.position.y = -roundf(above)
	shadow.position.y = -roundf((ground - base) * terrain.px_per_unit)
	_dust.position.y = shadow.position.y
	var lift := clampf(maxf(0.0, _feet - ground) * terrain.px_per_unit / 70.0, 0.0, 1.0)
	shadow.scale = Vector2.ONE * lerpf(1.0, 0.55, lift)
	shadow.modulate.a = lerpf(1.0, 0.45, lift)
	var top := terrain.platform_top(world_pos, foot_radius * _scale)
	z_index = 1 if top > -INF and _feet >= top - 0.5 else 0
	(sprite.material as ShaderMaterial).set_shader_parameter("sprite_depth",
			-1.0e6 if ignore_occlusion else terrain.view_depth(world_pos))


func _animate(kind: String, speed_scale: float) -> void:
	if tool_state == Tool.READY:
		kind += "_tool"
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


## A footstep every time a boot lands. The gait puts the left foot's strike at the start of
## the cycle and the right foot's half way through it (see foot_cycle in
## tools/astronaut_sprite_gen.py: stance begins at phase 0 for L, 0.5 for R), so the contact
## frames are frame 0 and the middle frame, whatever length the sheet is. Watching the drawn
## frame rather than a timer means the sound stays on the feet at any speed.
func _listen_for_footfall(moving: bool) -> void:
	if not moving:
		_step_frame = -1
		return
	var anim := String(sprite.animation)
	var running := anim.begins_with("run")
	if not running and not anim.begins_with("walk"):
		_step_frame = -1
		return
	var f := sprite.frame
	if f == _step_frame:
		return
	_step_frame = f
	var count := sprite.sprite_frames.get_frame_count(sprite.animation)
	if f != 0 and f != count / 2:
		return
	var sound := "step_dust"
	if step_source.is_valid():
		sound = step_source.call()
	Audio.play(sound, global_position, 1.06 if running else 1.0, 1.5 if running else -2.0)


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
