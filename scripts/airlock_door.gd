class_name AirlockDoor
extends Node2D
## An airlock door the astronaut can go through.
##
## Walk up to it and an "E" prompt appears over it. Press E and a little cutscene plays: the
## camera moves in behind the astronaut, they step up to the door, its warning light blinks,
## the door unseals and its halves slide away into their pockets with a blast of venting gas,
## they walk in, it closes behind them, and the screen fades out (then `entered` is emitted).
## arrive() plays it the other way round: fade in, the door open, the astronaut walking out
## of it, the door closing behind them.
##
## The door is a sprite sheet from the map generator (closed -> open). It sits in the y-sorted
## actors node, keyed on the door's foot, so the astronaut passes behind it going in.

signal entered
signal arrived

enum State { IDLE, APPROACH, UNLOCK, OPEN, HOLD, WALK_IN, CLOSE, FADE_OUT, ARRIVE_IN, WALK_OUT, CLOSE_OUT }

## How close (world units, from where you stand to use it) the prompt appears.
@export var reach := 30.0
## How far in front of the door you stand to use it (world units).
@export var stand_off := 26.0

const VAPOR: Array[Color] = [Color("#8ea8c4"), Color("#c8dcec"), Color("#f2f8ff")]
const AMBER := Color("#ffb24a")
const KEY := Color("#f2f0f8")

var label := "OPEN"
var world := Vector2.ZERO       # the door's foot, world
var dir := Vector2.ZERO         # outward: from the door to where you stand
var lamp := Vector2.ZERO        # the warning light, map px
var door_height := 30.0         # world units
var player: Player
var camera: GameCamera
var terrain: MapTerrain
var multitool: Multitool
var sprite: Sprite2D
var state := State.IDLE

var _frames := 12
var _st := 0.0
var _t := 0.0
var _prompt := false
var _was_prompt := false
var _lamp_on := false
var _puffs: Array = []          # [pos, vel, r, growth, age, life, drag]
var _glints: Array = []         # [pos, vel, age, life]
var _air: Node2D
var _fade: ColorRect
var _discs := {}


func setup(info: Dictionary, base_dir: String, p: Player, cam: GameCamera, t: MapTerrain, tool: Multitool,
		prompt_label := "OPEN") -> void:
	player = p
	camera = cam
	terrain = t
	multitool = tool
	label = prompt_label
	world = Vector2(info["world"][0], info["world"][1])
	dir = Vector2(info["dir"][0], info["dir"][1]).normalized()
	lamp = Vector2(info["lamp_px"][0], info["lamp_px"][1])
	door_height = float(info.get("height", 30.0))
	_frames = int(info["frames"])
	position = Vector2(0.0, float(info["sort_y"]))
	sprite = Sprite2D.new()
	sprite.texture = load(base_dir.path_join(info["file"]))
	sprite.hframes = _frames
	sprite.centered = false
	sprite.position = Vector2(info["position"][0], info["position"][1]) - position
	sprite.visible = false
	add_child(sprite)
	_air = Node2D.new()
	_air.z_index = 40
	_air.position = -position                            # draws in map pixels
	_air.draw.connect(_draw_air)
	add_child(_air)
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_fade = ColorRect.new()
	_fade.color = Color(0.02, 0.016, 0.04, 0.0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_fade)
	_ensure_action()


func stand_point() -> Vector2:
	return world + dir * stand_off


func busy() -> bool:
	return state != State.IDLE


## Coming out of this door (after a scene change): fade in, walk out, the door closes.
func arrive() -> void:
	state = State.ARRIVE_IN
	_st = 0.0
	_fade.color.a = 1.0
	sprite.visible = true
	sprite.frame = _frames - 1
	player.puppet = true
	player.ignore_occlusion = true
	player.controls_enabled = false
	player.world_pos = world - dir * 6.0
	player.modulate.a = 0.0
	player.puppet_face(dir)
	camera.focus_override = _focus()
	camera.snap_to(_focus())
	camera.set_level(0)
	Audio.play("door_vent", _sound_at(), 0.9, -4.0)
	_burst(10)


func _process(delta: float) -> void:
	if player == null:
		return
	_t += delta
	_st += delta
	match state:
		State.IDLE:
			_prompt = _in_reach()
			if _prompt and not _was_prompt:
				Audio.play("door_prompt")
			_was_prompt = _prompt
			if multitool != null:
				multitool.suppressed = _prompt
			if _prompt and Input.is_action_just_pressed("interact"):
				_start()
		State.APPROACH:
			if player.puppet_walk(stand_point(), 1.0, delta):
				player.puppet_face(-dir)
				_go(State.UNLOCK)
		State.UNLOCK:
			if _st > 0.6:
				sprite.visible = true
				sprite.frame = 0
				Audio.play("door_unseal", _sound_at())
				Audio.play("door_vent", _sound_at())
				_burst(28)
				camera.shake(1.4, 0.3)
				_go(State.OPEN)
		State.OPEN:
			var k := clampf(_st / 0.75, 0.0, 1.0)
			Audio.loop("door_slide", "door", _sound_at())
			sprite.frame = mini(_frames - 1, int(k * (_frames - 1) + 0.5))
			if randf() < 40.0 * delta:
				_burst(2)
			if k >= 1.0:
				_go(State.HOLD)
		State.HOLD:
			Audio.release("door")
			if randf() < 10.0 * delta:
				_burst(1)
			if _st > 0.35:
				player.ignore_occlusion = true
				_go(State.WALK_IN)
		State.WALK_IN:
			var inside := world - dir * 10.0
			var done := player.puppet_walk(inside, 0.8, delta)
			var depth := (player.world_pos - world).dot(dir)
			player.modulate.a = clampf((depth + 2.0) / 9.0, 0.0, 1.0)
			if done:
				_go(State.CLOSE)
		State.CLOSE:
			var k := clampf(_st / 0.6, 0.0, 1.0)
			Audio.loop("door_slide", "door", _sound_at())
			sprite.frame = mini(_frames - 1, int((1.0 - k) * (_frames - 1) + 0.5))
			if k >= 1.0:
				Audio.release("door")
				Audio.play("door_close", _sound_at())
				_burst(5)
				camera.shake(1.0, 0.15)
				_go(State.FADE_OUT)
		State.FADE_OUT:
			_fade.color.a = clampf(_st / 0.55, 0.0, 1.0)
			if _st > 0.7:
				state = State.IDLE
				entered.emit()
		State.ARRIVE_IN:
			_fade.color.a = 1.0 - clampf(_st / 0.6, 0.0, 1.0)
			if randf() < 18.0 * delta:
				_burst(1)
			if _st > 0.5:
				_go(State.WALK_OUT)
		State.WALK_OUT:
			_fade.color.a = maxf(0.0, _fade.color.a - delta / 0.3)
			var done2 := player.puppet_walk(stand_point(), 0.85, delta)
			var depth2 := (player.world_pos - world).dot(dir)
			player.modulate.a = clampf((depth2 + 2.0) / 9.0, 0.0, 1.0)
			if done2:
				player.modulate.a = 1.0
				player.ignore_occlusion = false
				_go(State.CLOSE_OUT)
		State.CLOSE_OUT:
			var k := clampf(_st / 0.6, 0.0, 1.0)
			Audio.loop("door_slide", "door", _sound_at())
			sprite.frame = mini(_frames - 1, int((1.0 - k) * (_frames - 1) + 0.5))
			if k >= 1.0:
				sprite.visible = false
				Audio.release("door")
				Audio.play("door_close", _sound_at())
				_burst(4)
				player.puppet = false
				player.controls_enabled = true
				camera.release_focus()
				state = State.IDLE
				arrived.emit()
	_tick_lamp()
	_update_gas(delta)
	_air.queue_redraw()


## Where the door's sounds come from: the foot of the door, in map pixels.
func _sound_at() -> Vector2:
	return terrain.to_screen(world, terrain.height_at(world)).round()


## The amber lamp blinks on the same schedule _draw_air() draws it on; tick with it.
func _tick_lamp() -> void:
	var working := state != State.IDLE and state != State.APPROACH
	var on := working and fmod(_t, 0.5) < 0.3
	if on and not _lamp_on:
		Audio.play("door_lamp", lamp)
	_lamp_on = on


func _start() -> void:
	_prompt = false
	if multitool != null:
		multitool.suppressed = true
	player.controls_enabled = false
	player.puppet = true
	camera.focus_override = _focus()
	camera.set_level(0)
	_go(State.APPROACH)


func _go(s: State) -> void:
	state = s
	_st = 0.0


func _focus() -> Vector2:
	var a := terrain.to_screen(world, terrain.height_at(world))
	var b := terrain.to_screen(stand_point(), terrain.height_at(stand_point()))
	return (a + b) * 0.5 + Vector2(0, -door_height * 0.45)


func _in_reach() -> bool:
	if not player.controls_enabled or player.is_airborne():
		return false
	var to := player.world_pos - world
	return to.dot(dir) > 4.0 and player.world_pos.distance_to(stand_point()) < reach


# ---------------------------------------------------------------- venting gas
func _screen_dir() -> Vector2:
	var a := terrain.to_screen(world, 0.0)
	var b := terrain.to_screen(world + dir, 0.0)
	return (b - a).normalized()


func _burst(n: int) -> void:
	var sd := _screen_dir()
	var base := terrain.to_screen(world, terrain.height_at(world))
	for i in n:
		var h := randf_range(0.1, 0.95) * door_height * terrain.px_per_unit
		var side := Vector2(-sd.y, sd.x) * randf_range(-10.0, 10.0)
		var p := base + Vector2(0, -h) + side + sd * 2.0
		var spread := Vector2(-sd.y, sd.x) * randf_range(-34.0, 34.0)
		var v := sd * randf_range(60.0, 125.0) + spread + Vector2(0, randf_range(-26.0, 2.0))
		_puffs.append([p, v, randf_range(1.5, 3.0), randf_range(7.0, 13.0), 0.0, randf_range(1.3, 2.4), randf_range(1.3, 2.0)])
		if randf() < 0.5:
			_glints.append([p, v * 1.3 + Vector2(0, -6), 0.0, randf_range(0.4, 0.9)])


func _update_gas(delta: float) -> void:
	var i := 0
	while i < _puffs.size():
		var q: Array = _puffs[i]
		q[4] += delta
		if q[4] >= q[5]:
			_puffs.remove_at(i)
			continue
		q[1] = (q[1] as Vector2) * exp(-q[6] * delta) + Vector2(0, -4.0) * delta
		q[0] += q[1] * delta
		i += 1
	i = 0
	while i < _glints.size():
		var g: Array = _glints[i]
		g[2] += delta
		if g[2] >= g[3]:
			_glints.remove_at(i)
			continue
		g[0] += (g[1] as Vector2) * delta
		g[1] = (g[1] as Vector2) * exp(-2.0 * delta)
		i += 1


func _draw_air() -> void:
	for q in _puffs:
		var k: float = q[4] / q[5]
		var r := int(round(q[2] + q[3] * sqrt(k)))
		var a := ceilf((1.0 - k) * 4.0) / 4.0 * 0.75
		var c: Vector2 = (q[0] as Vector2).round()
		_disc(c + Vector2(1, 1), r, Color(VAPOR[0], a * 0.7))
		_disc(c, r, Color(VAPOR[1], a))
		if r >= 2:
			_disc(c - Vector2(r, r) * 0.3, int(r * 0.55), Color(VAPOR[2], a))
	for g in _glints:
		var k2: float = g[2] / g[3]
		_air.draw_rect(Rect2((g[0] as Vector2).round(), Vector2.ONE), Color(1, 1, 1, 1.0 - k2))
	# the door's warning light while it works
	if state in [State.UNLOCK, State.OPEN, State.HOLD, State.WALK_IN, State.CLOSE, State.ARRIVE_IN, State.WALK_OUT, State.CLOSE_OUT]:
		if fmod(_t, 0.5) < 0.3:
			_disc(lamp.round(), 6, Color(AMBER, 0.25))
			_disc(lamp.round(), 3, Color(AMBER, 0.6))
			_disc(lamp.round(), 1, Color(1, 0.95, 0.8, 1.0))
	if _prompt:
		_draw_prompt()


## "[E] OPEN" floating over the door.
func _draw_prompt() -> void:
	var w := PixelFont.width(label) + 13
	var top := (lamp + Vector2(0, -16 + round(sin(_t * 4.0)))).round()
	var box := Rect2(top - Vector2(round(w / 2.0), 0), Vector2(w, 11))
	_air.draw_rect(box.grow(1), Color("#120f1d", 0.9))
	_air.draw_rect(box, Color("#241f36", 0.95))
	var key := Rect2(box.position + Vector2(2, 1), Vector2(8, 9))
	_air.draw_rect(key, KEY)
	_air.draw_rect(Rect2(key.position + Vector2(0, 8), Vector2(8, 1)), Color("#8f8ba8"))
	PixelFont.draw(_air, key.position + Vector2(3, 2), "E", Color("#241f36"))
	PixelFont.draw(_air, box.position + Vector2(12, 3), label, Color("#ffd27a"))
	_air.draw_rect(Rect2(top + Vector2(-1, 12), Vector2(3, 1)), Color("#ffd27a", 0.8))
	_air.draw_rect(Rect2(top + Vector2(0, 13), Vector2(1, 1)), Color("#ffd27a", 0.8))


func _disc(center: Vector2, r: int, col: Color) -> void:
	r = maxi(r, 0)
	if not _discs.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				if Vector2(x - r, y - r).length() <= r + 0.35:
					img.set_pixel(x, y, Color.WHITE)
		_discs[r] = ImageTexture.create_from_image(img)
	_air.draw_texture(_discs[r], center - Vector2(r, r), col)


static func _ensure_action() -> void:
	if InputMap.has_action("interact"):
		return
	InputMap.add_action("interact")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_E
	InputMap.action_add_event("interact", key)
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_X
	InputMap.action_add_event("interact", pad)
