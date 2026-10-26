class_name Bot
extends Node2D
## UNIT's base/nursery maintenance bodies, sharing StoryState and the existing native sheet.
## Dormant bodies use the equipped multitool's held fix job. The base runs the name/access
## introduction; the nursery introduces the shared mind and crops before systems can be fixed.
## Awake bodies stroll with random pauses, occasionally choosing real unfinished litter to vacuum.
## Timing comes from bot_story.json maintenance; remaining per-body delays live in StoryState.
## Walk-grid paths avoid walls/props. State/progress/position survive airlocks and turns.
## F/X talk uses the existing independent suppression and paused BotDialogue. New advice is
## marked with an exclamation above the body. Eyes and marker stay lit at night.
## NurseryCleanup supplies six real litter jobs in each facility; deploy/sweep/stow follows the native atlas and
## its exported nozzle tips. Cleaning progress changes only while in reach, never remotely.
## F1 nursery-body completion/reset refreshes this body's state and scanner job immediately.

const SHADER := preload("res://shaders/prop_depth.gdshader")
const BOT_JSON := "res://assets/maps/base_interior/bot/bot.json"
const EYES := Color("#7fe6cf")
const KEY := Color("#f2f0f8")
## How close (world units, from its foot) the prompt shows; while patrolling, only when you turn to
## face it this close, so it never takes F from the tool, a door or a machine.
const REACH := 30.0
const FOLLOW_REACH := 22.0
## Mechanical access-release beat before the introduction continues, seconds.
const ACCESS_BEAT := 1.8
const STUCK_TIME := 1.5

enum State { DORMANT, WAKING, AWAKE, PATROL }

var body := "base"
var cleaning := false
var _spots: Array[Vector2] = []
var _spot := 0
var _path := PackedVector2Array()
var _clean_stage := ""
var _clean_wait := 0.0
var _idle_left := 0.0
var _job := -1
var _rng := RandomNumberGenerator.new()
var cleanup: NurseryCleanup
var _clean_fx: Node2D
var _home := Vector2.ZERO
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
	body = str(info.get("body", "base"))
	_rng.randomize()
	_clean_wait = float(GameState.story.maintenance_waits.get(body, _next_clean_wait()))
	world = Vector2(info["world"][0], info["world"][1])
	_home = world
	for point in info.get("cleaning_spots", []):
		_spots.append(Vector2(point[0], point[1]))
	if _spots.is_empty():
		for room in ViewData.get_json(terrain.view_json).get("rooms", {}).values():
			var centre := Vector2(room["center"][0], room["center"][1])
			_spots.append(centre + Vector2(-.3, -.2) * float(room["radius"]))
			_spots.append(centre + Vector2(.3, -.2) * float(room["radius"]))
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
	_clean_fx = Node2D.new()
	_clean_fx.draw.connect(_draw_cleaning)
	add_child(_clean_fx)
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
	var introduced: bool = story.nursery_introduced if body == "nursery" else story.objectives_given
	if story.body_awake(body) and introduced:
		state = State.PATROL
		var saved: Variant = story.nursery_bot_world if body == "nursery" else story.bot_world
		if saved != null:
			world = saved
		_play("idle")
	elif story.body_awake(body):
		state = State.AWAKE
		_play("idle")
	else:
		_fix = {"world": world, "radius": radius, "head": Vector2.ZERO, "base": Vector2.ZERO}
		_tool.add_fixable(_fix, _wake)
		_fix["progress"] = float(story.body_repair_progress.get(body, 0.))
		_play("dormant")
	set_view()
	if body == "nursery":
		story.changed.connect(_sync_nursery_repair)


func _sync_nursery_repair() -> void:
	var story := GameState.story
	if story.nursery_awake:
		if state != State.DORMANT or not story.nursery_introduced:
			return
		if not _fix.is_empty():
			_tool.remove_fixable(_fix)
		_fix = {}
		state = State.PATROL
		_release_guard = true
		_play("idle")
	else:
		if state != State.DORMANT:
			state = State.DORMANT
			world = _home
			velocity = Vector2.ZERO
			_path.clear()
			_clean_stage = ""
			_job = -1
			_idle_left = 0.
			_clean_wait = _next_clean_wait()
			cleaning = false
			_prompt = false
			_was_prompt = false
			Audio.release("bot:hover:" + body)
			Audio.release("bot:vacuum:" + body)
			_tool.bot_suppressed = false
			_fix = {"world": world, "radius": radius, "head": Vector2.ZERO, "base": Vector2.ZERO}
			_tool.add_fixable(_fix, _wake)
			_play("dormant")
		if not _fix.is_empty():
			_fix["progress"] = float(story.body_repair_progress.get(body, 0.))
	_drawn = null
	_place()


## The nursery's actual litter owns job positions and persistent progress.
func set_cleanup(controller: NurseryCleanup) -> void:
	cleanup = controller
	_spots.clear()
	for site in cleanup.sites: _spots.append(cleanup.point(site))
	_spot = _rng.randi_range(0, maxi(0, _spots.size() - 1))
	_path.clear()


## The camera turned: its facing as this view sees it, its foot and its depth.
func set_view() -> void:
	refresh_window()
	_place()


## The depth map it hides behind is a moving window (MapStream): point the shader at it again.
func refresh_window() -> void:
	MapStream.bind(_mat, _terrain)


## Explicit preview helper only; ordinary airlock arrivals leave UNIT on its patrol.
func greet_at(p: Vector2) -> void:
	if state != State.PATROL:
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
	if state == State.PATROL:
		if body == "nursery": GameState.story.nursery_bot_world = world
		else: GameState.story.bot_world = world
	_animate()


## The fix job is done: it boots up, then the opening conversation.
func _wake() -> void:
	_fix = {}
	state = State.WAKING
	GameState.story.wake_body(body)
	_play("wake")
	Audio.play("bot_boot", position + _face)


func _process(delta: float) -> void:
	if _player == null:
		return
	if get_tree().paused and not _talking:               # the backpack, the map: everything waits
		Audio.release("bot:vacuum:" + body)
		Audio.release("bot:hover:" + body)
		return
	cleaning = false
	if not _fix.is_empty():
		GameState.story.body_repair_progress[body] = float(_fix.get("progress", 0.))
	_t += delta
	_anim_t += delta
	_flash = maxf(0.0, _flash - delta * 2.5)
	_hop = maxf(0.0, _hop - delta)
	if state == State.WAKING and _anim_done():
		state = State.AWAKE
		_play("idle")
		_continue_story()
	if state == State.PATROL and not _talking and not get_tree().paused:
		_patrol(delta)
	if state == State.PATROL and not get_tree().paused:
		Audio.loop("bot_hover", "bot:hover:" + body, position)
	else:
		Audio.release("bot:hover:" + body)
	if cleaning and not _talking and not get_tree().paused:
		Audio.loop("bot_vacuum", "bot:vacuum:" + body, position)
	else:
		Audio.release("bot:vacuum:" + body)
	if state == State.AWAKE or state == State.PATROL:
		_prompt = _in_reach() and not _talking
		if _prompt and not _was_prompt:
			Audio.play("door_prompt")
		_was_prompt = _prompt
		if _release_guard and not Input.is_action_pressed("interact") and not Input.is_action_pressed("tool_use"):
			_release_guard = false
		_tool.bot_suppressed = _prompt or _talking or _release_guard
		if _prompt and not _release_guard and not _tool.inventory_suppressed and not _tool.options_suppressed and Input.is_action_just_pressed("interact"):
			talk()
	sprite.position.y = -roundf(sin(PI * clampf(_hop / 0.5, 0.0, 1.0)) * 6.0)
	_place()
	# Redraw only when what its layers show has changed (as DayClock does): it moving needs none,
	# they move with it. The eyes, the prompt and its bob, the talking pulse, the blink-in flash.
	var state := [_row, _eyes_on(), _prompt, roundf(sin(_t * 4.0)) if _prompt else 0.0,
			roundf(sin(_t * 12.0) * 3.0) if _talking else 0.0, ceili(_flash * 10.0), sprite.position.y, GameState.story.has_news(body),
			int(_t * 8) if cleaning else 0]
	if state != _drawn:
		_drawn = state
		_lit.queue_redraw()
		_glow.queue_redraw()
	_clean_fx.queue_redraw()


# ---------------------------------------------------------------- maintenance patrol
func _patrol(delta: float) -> void:
	if _player.turning or not _player.controls_enabled or _player.puppet:
		return
	if not _free(world):
		world = _free_near(world, world) # lift off the solid charging cradle onto its own floor
		_path.clear()
	if _in_reach():
		velocity = Vector2.ZERO
		_set_anim("idle")
		return
	_clean_wait = maxf(0., _clean_wait - delta)
	GameState.story.maintenance_waits[body] = _clean_wait
	if not _clean_stage.is_empty():
		_set_anim(_clean_stage)
		if _clean_stage == "clean_start" and _anim_done():
			_clean_stage = "clean"
		elif _clean_stage == "clean":
			cleaning = true
			if cleanup != null: cleanup.advance(_job, delta, world)
			if cleanup != null and cleanup.done(_job):
				_clean_stage = "clean_end"
		elif _clean_stage == "clean_end" and _anim_done():
			_clean_stage = ""
			_job = -1
			_clean_wait = _next_clean_wait()
			GameState.story.maintenance_waits[body] = _clean_wait
			_next_stroll()
		return
	cleaning = false
	if _spots.is_empty(): return
	if _idle_left > 0.:
		_idle_left -= delta
		_set_anim("idle")
		return
	if _job < 0 and _clean_wait <= 0. and cleanup != null and not cleanup.all_clean():
		var pending := []
		for index in cleanup.sites.size():
			if not cleanup.done(index): pending.append(index)
		_job = pending[_rng.randi_range(0, pending.size() - 1)]
		_spot = _job
		_path.clear()
	if _path.is_empty():
		_path = _floor_path(_spots[_spot])
		if _path.is_empty():
			_defer_job()
			return
	var to := _path[0] - world
	if to.length() < .5:
		world = _path[0]
		_path.remove_at(0)
		if _path.is_empty():
			if _job >= 0 and world.distance_to(_spots[_spot]) <= 6. and not cleanup.done(_job):
				_facing = Vector2(0, -1) # place the deployed intake over the floor ahead
				_clean_stage = "clean_start"
			else:
				_defer_job()
			velocity = Vector2.ZERO
		return
	velocity = to.normalized() * minf(28., to.length() / maxf(delta, .001))
	var next := world + velocity * delta
	if _free(next):
		world = next
		_stuck = 0.
		_facing = velocity.normalized()
		_set_anim("move")
	else:
		_stuck += delta
		if _stuck > STUCK_TIME:
			_path.clear()
			_defer_job()
			_stuck = 0.


## Strolls and little pauses make cleaning an occasional decision. Never vacuum clean floor.
func _next_clean_wait() -> float:
	var seconds: Array = GameState.story.data["maintenance"]["stroll_seconds"]
	return _rng.randf_range(float(seconds[0]), float(seconds[1]))


func _next_stroll() -> void:
	if not _spots.is_empty():
		_spot = (_spot + _rng.randi_range(1, maxi(1, _spots.size() - 1))) % _spots.size()
	var seconds: Array = GameState.story.data["maintenance"]["idle_seconds"]
	_idle_left = _rng.randf_range(float(seconds[0]), float(seconds[1]))
	_path.clear()
	velocity = Vector2.ZERO
	_set_anim("idle")


func _defer_job() -> void:
	if _job >= 0: _clean_wait = _next_clean_wait()
	_job = -1
	_next_stroll()


## A small floor graph in canonical world coordinates, rebuilt between jobs so moving
## crates and opened bulkheads are respected. No relation to the player's location.
func _floor_path(target: Vector2) -> PackedVector2Array:
	const CELL := 6.
	var low := world.min(target)
	var high := world.max(target)
	for point in _spots:
		low = low.min(point)
		high = high.max(point)
	var graph := AStarGrid2D.new()
	var start := Vector2i((low - Vector2.ONE * 80.) / CELL)
	var end := Vector2i((high + Vector2.ONE * 80.) / CELL)
	graph.region = Rect2i(start, end - start + Vector2i.ONE)
	graph.cell_size = Vector2.ONE * CELL
	graph.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	graph.update()
	var from := Vector2i.ZERO
	var finish := Vector2i.ZERO
	var near_from := INF
	var near_end := INF
	var finishes: Array[Vector2i] = []
	for y in range(start.y, end.y + 1):
		for x in range(start.x, end.x + 1):
			var id := Vector2i(x, y)
			var point := Vector2(id) * CELL
			var free := _free(point)
			graph.set_point_solid(id, not free)
			if not free: continue
			if point.distance_squared_to(target) <= 6. * 6.: finishes.append(id)
			if point.distance_squared_to(world) < near_from and point.distance_squared_to(world) <= 30. * 30. and _clear_segment(world, point):
				near_from = point.distance_squared_to(world)
				from = id
			if point.distance_squared_to(target) < near_end:
				near_end = point.distance_squared_to(target)
				finish = id
	if near_from > 30. * 30. or near_end > 30. * 30.: return PackedVector2Array()
	finishes.sort_custom(func(a: Vector2i,b: Vector2i) -> bool:
		return (Vector2(a)*CELL).distance_squared_to(target) < (Vector2(b)*CELL).distance_squared_to(target))
	# A coarse node may be clear on both ends but clip the curved wall between them.
	# Reject that edge's destination and re-route; movement then follows verified clear legs.
	for attempt in 24:
		var ids := graph.get_id_path(from, finish)
		if ids.is_empty(): return PackedVector2Array()
		var out := PackedVector2Array()
		var previous := world
		var blocked := false
		for id in ids:
			var point := Vector2(id) * CELL
			if not _clear_segment(previous, point):
				if id == from: return PackedVector2Array()
				graph.set_point_solid(id, true)
				if id == finish:
					var found := false
					for alternate in finishes:
						if not graph.is_point_solid(alternate):
							finish = alternate
							found = true
							break
					if not found: return PackedVector2Array()
				blocked = true
				break
			out.append(point)
			previous = point
		if not blocked: return out
	return PackedVector2Array()


func _clear_segment(from: Vector2, to: Vector2) -> bool:
	var steps := maxi(1, ceili(from.distance_to(to) * 2.))
	for step in range(1, steps + 1):
		if not _free(from.lerp(to, step / float(steps))): return false
	return true


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
	if (state != State.AWAKE and state != State.PATROL) or _talking:
		return
	var look := _player.world_pos - world
	if look.length() > 1.0:
		_facing = look.normalized()
	velocity = Vector2.ZERO
	if body == "nursery" and not GameState.story.nursery_introduced or body == "base" and not GameState.story.objectives_given:
		_continue_story()
		return
	_say(GameState.story.lines("nursery_remind") if body == "nursery" and not GameState.story.has_news(body) else GameState.story.next_talk(), true, _end_talk)


## The opening, from wherever it got to: who you are, maintenance access, the objectives.
func _continue_story() -> void:
	var story := GameState.story
	if body == "nursery":
		_say(story.lines("nursery_intro"), false, _nursery_ready)
		return
	if not story.named:
		_say(story.lines("wake") + [story.text(story.data["correction"])], false, _ask_name)
	elif not story.access_opened:
		_say(story.lines("named") + [story.lines("access")[0]], false, _unlock_access)
	else:
		_say(story.lines("access").slice(1) + story.guidance(), false, _objectives)


func _nursery_ready() -> void:
	GameState.story.nursery_introduced = true
	GameState.story.changed.emit()
	state = State.PATROL
	_end_talk()


func _ask_name() -> void:
	_talking = true
	_names.open(GameState.story.data["name_entry"], GameState.story.player_name, _named)


func _named(value: String) -> void:
	GameState.story.set_name(value, _names.remember)
	_talking = false
	_continue_story()


## Release maintenance bulkheads mechanically; O2 reserve and main lighting remain separate.
func _unlock_access() -> void:
	_talking = true
	_player.controls_enabled = false
	GameState.story.unlock_access()
	Audio.play("reserve_on")
	_player.camera.shake(1.2, 0.35)
	await get_tree().create_timer(ACCESS_BEAT).timeout
	_player.controls_enabled = true
	_talking = false
	_continue_story()


## The opening is over: it leaves the cradle for independent maintenance.
func _objectives() -> void:
	GameState.story.give_objectives()
	state = State.PATROL
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
	if state != State.PATROL:
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
	return state == State.AWAKE or state == State.PATROL


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
	if GameState.story.has_news(body) and _eyes_on() and not _talking:
		PixelFont.draw(_lit, Vector2(-1, -68 if _prompt else -43), "!", InventoryUI.GOLD, 2, InventoryUI.DARK)
	if _prompt:
		_draw_prompt("F", "TALK")


## Soil and leaf chips travel from the floor into the generated intake, graded with the room.
func _draw_cleaning() -> void:
	if not cleaning or _talking: return
	var tip: Array = _data["nozzle_tips"][_row][sprite.frame_coords.x]
	var intake := Vector2(tip[0], tip[1])
	var floor_px := _terrain.to_screen(_spots[_spot], _terrain.height_at(_spots[_spot])) - position
	for i in 7:
		var phase := fposmod(_t * 1.4 + i * .17, 1.)
		var start := floor_px + Vector2((i % 4 - 1.5) * 3., (i / 4.) * 2.)
		var dust := start.lerp(intake, phase) + Vector2(0, -sin(phase * PI) * 2.)
		_clean_fx.draw_rect(Rect2(dust.round(), Vector2.ONE), Color("#998d86" if i % 2 else "#6d5146"))


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
	Audio.release("bot:hover:" + body)
	Audio.release("bot:vacuum:" + body)
	if _tool != null:
		_tool.bot_suppressed = false
		if not _fix.is_empty():
			_tool.remove_fixable(_fix)
