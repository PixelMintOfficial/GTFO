class_name Bot
extends Node2D
## The base's bot, asleep in its cradle in storage (the opening chapter: StoryState).
##
## Dormant, it is a target for the multitool's fix job (Multitool.add_fixable): hold F with the
## tool out and it boots - eyes flicker on, it straightens and rises off the cradle. Then it
## talks (BotDialogue): it takes you for the base's previous owner, you tell it your name
## (NameEntry), it switches on reserve power (the emergency lines light, the bulkheads open) and
## hands out the objectives. After that it follows you round the base - inside only: it waits
## where you left it when you go out through the airlock, and meets you at the door when you come
## back (GameState.story.bot_world). [F] TALK when you are near: lore whose moment has come, where
## you are with the objectives, a little trivia.
##
## Following: it hovers to a spot behind and beside you, easing up to your running speed, and
## steers round walls and anything solid on the walk grid (MapTerrain.surface). It is never solid
## itself. Stuck, or left far behind, it blinks out and back in beside you.
##
## Its sheet (tools/bot_gen.py, bot/bot.json) has eight facings like the astronaut's, so it turns
## with its flight in every view; it is drawn behind nearer scenery (prop_depth) and y-sorted on
## its foot. Its eyes are a light: kept lit at night in an additive layer.
## F / gamepad X: the prompt owns it through multitool.bot_suppressed, released only when the
## button is let go after a conversation (like the other modals).

const SHADER := preload("res://shaders/prop_depth.gdshader")
const BOT_JSON := "res://assets/maps/base_interior/bot/bot.json"
const EYES := Color("#7fe6cf")
const KEY := Color("#f2f0f8")
## How close (world units, from its foot) the prompt shows; following you, only when you turn to
## face it this close, so it never takes F from the tool, a door or a machine.
const REACH := 30.0
const FOLLOW_REACH := 22.0
## The beat after "switching to reserve": the lights come up and the bulkheads open, seconds.
const RESERVE_BEAT := 1.8
## Following: where it keeps to (world units behind and beside you), how near is near enough,
## how fast it flies and turns, and when it gives up and blinks back in beside you.
const KEEP_BEHIND := 16.0
const KEEP_BESIDE := 14.0
const SETTLE := 8.0
const SPEED := 70.0
const ACCEL := 220.0
const STUCK_TIME := 1.5
const TOO_FAR := 120.0

enum State { DORMANT, WAKING, AWAKE, FOLLOW }

var state := State.DORMANT
var world := Vector2.ZERO
var radius := 7.0
var velocity := Vector2.ZERO
var sprite: Sprite2D

var _player: Player
var _tool: Multitool
var _terrain: MapTerrain
var _dialogue: BotDialogue
var _names: NameEntry
var _mat: ShaderMaterial
var _data: Dictionary = {}
var _faces: Array = []           # per facing: its eyes from the foot (map px)
var _facing := Vector2(0, -1)    # world direction it faces
var _row := 2
var _face := Vector2.ZERO
var _anim := "dormant"
var _anim_t := 0.0
var _fix: Dictionary = {}        # the fix job's target while dormant
var _prompt := false
var _was_prompt := false
var _talking := false
var _release_guard := false
var _stuck := 0.0
var _flash := 0.0                # blinking back in beside you
var _hop := 0.0                  # its little hop of greeting
var _t := 0.0
var _drawn: Variant = null       # what its eyes and prompt showed last time they were drawn
var _lit: Node2D
var _glow: Node2D
var _halos := {}


func setup(info: Dictionary, player: Player, tool: Multitool, terrain: MapTerrain, dialogue: BotDialogue,
		names: NameEntry) -> void:
	_player = player
	_tool = tool
	_terrain = terrain
	_dialogue = dialogue
	_names = names
	process_mode = Node.PROCESS_MODE_ALWAYS              # it talks while the conversation pauses the world
	world = Vector2(info["world"][0], info["world"][1])
	_facing = Vector2(info.get("facing", [0.0, -1.0])[0], info.get("facing", [0.0, -1.0])[1])
	radius = float(info.get("radius", 7.0))
	_data = JSON.parse_string(FileAccess.get_file_as_string(BOT_JSON))
	for f in _data["face"]:
		_faces.append(Vector2(f[0], f[1]))
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("depth_scale", terrain.depth_scale)
	_mat.set_shader_parameter("tolerance", radius + 2.0)
	sprite = Sprite2D.new()
	sprite.centered = false
	sprite.material = _mat
	sprite.texture = load(BOT_JSON.get_base_dir().path_join(_data["file"]))
	sprite.hframes = int(_data["frames"])
	sprite.vframes = (_data["facings"] as Array).size()
	sprite.offset = -Vector2(_data["anchor"][0], _data["anchor"][1])
	add_child(sprite)
	_glow = Node2D.new()
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = add
	_glow.draw.connect(_draw_glow)
	add_child(_glow)
	_lit = Node2D.new()
	_lit.z_index = 41
	_lit.set_meta("dn_unlit", true)                      # its eyes and the prompt: bright by night too
	_lit.draw.connect(_draw_lit)
	add_child(_lit)
	var story := GameState.story
	if story.objectives_given:
		state = State.FOLLOW
		if story.bot_world != null:
			world = story.bot_world
		_play("idle")
	elif story.bot_awake:
		state = State.AWAKE
		_play("idle")
	else:
		_fix = {"world": world, "radius": radius, "head": Vector2.ZERO, "base": Vector2.ZERO}
		_tool.add_fixable(_fix, _wake)
		_play("dormant")
	set_view()


## The camera turned: its facing as this view sees it, its foot and its depth.
func set_view() -> void:
	refresh_window()
	_place()


## The depth map it hides behind is a moving window (MapStream): point the shader at it again.
func refresh_window() -> void:
	MapStream.bind(_mat, _terrain)


## Coming back in through the airlock: it meets you by the door, with a hop and a chirp.
func greet_at(p: Vector2) -> void:
	if state != State.FOLLOW:
		return
	world = _free_near(p, world)
	_hop = 0.5
	Audio.play("bot_chirp", position)
	_place()


## Blink out and back in beside you (stuck, left behind, or a test putting it there).
func warp_near_player() -> void:
	world = _free_near(_player.world_pos, world)
	velocity = Vector2.ZERO
	_stuck = 0.0
	_flash = 1.0
	Audio.play("bot_chirp", position)
	_place()


func _place() -> void:
	var v := _terrain.view_dir(_facing)
	var sd := Vector2(v.x, -v.y)
	_row = posmod(int(round(sd.angle() / (PI / 4.0))), 8)
	_face = _faces[_row] if _row < _faces.size() else Vector2(0, -20)
	position = _terrain.to_screen(world, _terrain.height_at(world)).round()
	_mat.set_shader_parameter("sprite_depth", _terrain.view_depth(world))
	if not _fix.is_empty():
		_fix["base"] = position
		_fix["head"] = position + _face
	if state == State.FOLLOW:
		GameState.story.bot_world = world
	_animate()


## The fix job is done: it boots up, then the opening conversation.
func _wake() -> void:
	_fix = {}
	state = State.WAKING
	GameState.story.wake()
	_play("wake")
	Audio.play("bot_boot", position + _face)


func _process(delta: float) -> void:
	if _player == null:
		return
	if get_tree().paused and not _talking:               # the backpack, the map: everything waits
		return
	_t += delta
	_anim_t += delta
	_flash = maxf(0.0, _flash - delta * 2.5)
	_hop = maxf(0.0, _hop - delta)
	if state == State.WAKING and _anim_done():
		state = State.AWAKE
		_play("idle")
		_continue_story()
	if state == State.FOLLOW and not _talking and not get_tree().paused:
		_follow(delta)
	if state == State.FOLLOW and not get_tree().paused:
		Audio.loop("bot_hover", "bot:hover", position)
	else:
		Audio.release("bot:hover")
	if state == State.AWAKE or state == State.FOLLOW:
		_prompt = _in_reach() and not _talking
		if _prompt and not _was_prompt:
			Audio.play("door_prompt")
		_was_prompt = _prompt
		if _release_guard and not Input.is_action_pressed("interact") and not Input.is_action_pressed("tool_use"):
			_release_guard = false
		_tool.bot_suppressed = _prompt or _talking or _release_guard
		if _prompt and not _release_guard and not _tool.inventory_suppressed and Input.is_action_just_pressed("interact"):
			talk()
	sprite.position.y = -roundf(sin(PI * clampf(_hop / 0.5, 0.0, 1.0)) * 6.0)
	_place()
	# Redraw only when what its layers show has changed (as DayClock does): it moving needs none,
	# they move with it. The eyes, the prompt and its bob, the talking pulse, the blink-in flash.
	var state := [_row, _eyes_on(), _prompt, roundf(sin(_t * 4.0)) if _prompt else 0.0,
			roundf(sin(_t * 12.0) * 3.0) if _talking else 0.0, ceili(_flash * 10.0), sprite.position.y]
	if state != _drawn:
		_drawn = state
		_lit.queue_redraw()
		_glow.queue_redraw()


# ---------------------------------------------------------------- following
func _follow(delta: float) -> void:
	var me := _player.world_pos
	if me.distance_to(world) > TOO_FAR or _stuck > STUCK_TIME:
		warp_near_player()
		return
	var back := -_player.facing_dir()
	var spot := me + back * KEEP_BEHIND + back.orthogonal() * KEEP_BESIDE
	var to := spot - world
	var want := Vector2.ZERO
	if to.length() > SETTLE:
		want = to.normalized() * minf(SPEED, to.length() * 2.4)
	velocity = velocity.move_toward(want, ACCEL * delta)
	var moved := false
	if velocity.length() > 0.5 and not _free(world):     # still over its cradle: it lifts out of it
		world += velocity * delta
		moved = true
	elif velocity.length() > 0.5:
		for turn in [0.0, PI / 4.0, -PI / 4.0, PI / 2.0, -PI / 2.0]:   # round whatever is in the way
			var step: Vector2 = velocity.rotated(turn) * delta
			if _free(world + step):
				world += step
				moved = true
				if turn != 0.0:
					velocity = velocity.rotated(turn) * 0.8
				break
		if not moved:
			velocity = Vector2.ZERO
	_stuck = 0.0 if moved or want == Vector2.ZERO else _stuck + delta
	if velocity.length() > 6.0:
		_facing = velocity.normalized()
		_set_anim("move")
	else:
		var look := me - world
		if look.length() > 1.0:
			_facing = look.normalized()
		_set_anim("idle")


## Open floor for its foot (and a little round it): walls, closed bulkheads and solid props stop it.
func _free(p: Vector2) -> bool:
	for o in [Vector2.ZERO, Vector2(3, 0), Vector2(-3, 0), Vector2(0, 3), Vector2(0, -3)]:
		if _terrain.surface(p + o) == MapTerrain.Surface.SOLID:
			return false
	return true


## The first open spot round `p` (behind it first), or `fallback`.
func _free_near(p: Vector2, fallback: Vector2) -> Vector2:
	var back := -_player.facing_dir() if _player != null else Vector2(0, -1)
	for r in [18.0, 26.0, 12.0, 34.0]:
		for i in 12:
			var q: Vector2 = p + back.rotated(i * TAU / 12.0 * (1 if i % 2 else -1) * 0.5) * r
			if _free(q):
				return q
	return fallback


# ---------------------------------------------------------------- talking
## Talk to it: the rest of the opening if it is not over, else whatever it has to say next.
func talk() -> void:
	if (state != State.AWAKE and state != State.FOLLOW) or _talking:
		return
	var look := _player.world_pos - world
	if look.length() > 1.0:
		_facing = look.normalized()
	velocity = Vector2.ZERO
	if not GameState.story.objectives_given:
		_continue_story()
		return
	_say(GameState.story.next_talk(), true, _end_talk)


## The opening, from wherever it got to: who you are, reserve power, the objectives.
func _continue_story() -> void:
	var story := GameState.story
	if not story.named:
		_say(story.lines("wake") + [story.text(story.data["correction"])], false, _ask_name)
	elif not story.reserve_power:
		_say(story.lines("named") + [story.lines("reserve")[0]], false, _reserve)
	else:
		_say(story.lines("reserve").slice(1) + story.lines("objectives_intro"), false, _objectives)


func _ask_name() -> void:
	_talking = true
	_names.open(GameState.story.data["name_entry"], GameState.story.player_name, _named)


func _named(value: String) -> void:
	GameState.story.set_name(value, _names.remember)
	_talking = false
	_continue_story()


## Reserve power comes on: a beat for the lights to come up and the bulkheads to open.
func _reserve() -> void:
	_talking = true
	_player.controls_enabled = false
	GameState.story.power_reserve()
	Audio.play("reserve_on")
	_player.camera.shake(1.2, 0.35)
	await get_tree().create_timer(RESERVE_BEAT).timeout
	_player.controls_enabled = true
	_talking = false
	_continue_story()


## The opening is over: it leaves the cradle and comes with you.
func _objectives() -> void:
	GameState.story.give_objectives()
	state = State.FOLLOW
	GameState.story.bot_world = world
	_end_talk()


func _say(lines: Array, closable: bool, then: Callable) -> void:
	_talking = true
	_play("talk")
	_dialogue.open(GameState.story.data["names"]["bot"], lines, closable, func() -> void:
		_play("idle")
		_talking = false
		then.call())


func _end_talk() -> void:
	_release_guard = true


func _in_reach() -> bool:
	if not _player.controls_enabled or _player.puppet or _player.is_airborne() or _player.height_above_floor() > 1.0:
		return false
	if _tool.suppressed or _tool.repair_suppressed or _tool.window_suppressed or _tool.solar_suppressed:
		return false                                     # a door, a machine, a window or the field has F
	var to := world - _player.world_pos
	if state != State.FOLLOW:
		return to.length() - radius < REACH
	if _tool._target != null:                            # the tool has work in reach: F is the tool's
		return false
	return to.length() < FOLLOW_REACH and _player.facing_dir().dot(to.normalized()) > 0.6


# ---------------------------------------------------------------- animation
func _play(name: String) -> void:
	_anim = name
	_anim_t = 0.0
	_animate()


func _set_anim(name: String) -> void:
	if _anim != name:
		_play(name)


func _animate() -> void:
	if sprite == null:
		return
	var a: Array = _data["animations"][_anim]
	var i := int(_anim_t * float(a[2]))
	i = posmod(i, int(a[1])) if a[3] else mini(i, int(a[1]) - 1)
	sprite.frame_coords = Vector2i(int(a[0]) + i, _row)


func _anim_done() -> bool:
	var a: Array = _data["animations"][_anim]
	return not a[3] and _anim_t * float(a[2]) >= float(a[1])


## Its eyes are lit once it is awake (the wake animation flickers them on itself).
func _eyes_on() -> bool:
	return state == State.AWAKE or state == State.FOLLOW


## As a billboard for the camera's swing.
func boards() -> Array:
	var tex := sprite.texture
	var w := tex.get_width() / float(sprite.hframes)
	var h := tex.get_height() / float(sprite.vframes)
	return [{"tex": tex, "region": Rect2(sprite.frame_coords.x * w, sprite.frame_coords.y * h, w, h), "anchor": -sprite.offset,
			"world": Vector3(world.x, world.y, _terrain.height_at(world))}]


# ---------------------------------------------------------------- drawing
func _draw_glow() -> void:
	var lift := sprite.position
	if _eyes_on() and _row >= 0 and _row <= 4:              # facing you, more or less: its eyes show
		var talk_pulse := 0.15 * sin(_t * 12.0) if _talking else 0.0
		_halo(_face + lift, 7, Color(EYES, 0.22 + talk_pulse))
	if _flash > 0.0:                                         # blinking back in
		_halo(Vector2(0, -12) + lift, int(6 + 10 * (1.0 - _flash)), Color(EYES, 0.5 * _flash))


func _draw_lit() -> void:
	if _prompt:
		_draw_prompt("F", "TALK")


## "[F] TALK" floating over it, in the door prompt's style.
func _draw_prompt(key_text: String, label: String) -> void:
	var w := PixelFont.width(label) + 13
	var top := (_face + sprite.position + Vector2(0, -22 + round(sin(_t * 4.0)))).round()
	var box := Rect2(top - Vector2(round(w / 2.0), 0), Vector2(w, 11))
	_lit.draw_rect(box.grow(1), Color("#120f1d", 0.9))
	_lit.draw_rect(box, Color("#241f36", 0.95))
	var key := Rect2(box.position + Vector2(2, 1), Vector2(8, 9))
	_lit.draw_rect(key, KEY)
	_lit.draw_rect(Rect2(key.position + Vector2(0, 8), Vector2(8, 1)), Color("#8f8ba8"))
	PixelFont.draw(_lit, key.position + Vector2(3, 2), key_text, Color("#241f36"))
	PixelFont.draw(_lit, box.position + Vector2(12, 3), label, Color("#ffd27a"))
	_lit.draw_rect(Rect2(top + Vector2(-1, 12), Vector2(3, 1)), Color("#ffd27a", 0.8))
	_lit.draw_rect(Rect2(top + Vector2(0, 13), Vector2(1, 1)), Color("#ffd27a", 0.8))


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


func _exit_tree() -> void:
	Audio.release("bot:hover")
	if _tool != null:
		_tool.bot_suppressed = false
		if not _fix.is_empty():
			_tool.remove_fixable(_fix)
