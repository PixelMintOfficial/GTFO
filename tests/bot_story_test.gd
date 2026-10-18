extends Node
## Checks for the opening chapter (scripts/story/): the bulkheads sealing the power and oxygen
## rooms, the bot asleep in its cradle in storage, waking it with the multitool's fix job, its
## conversation driven by real keys, telling it your name on the keyboard and on a gamepad,
## reserve power opening the bulkheads, the objectives and the lore they unlock, the bot
## following you round the base (never in your way, blinking back in when left behind, meeting
## you at the airlock), and all of it surviving a camera turn and a scene reload. The player's
## real profile is never touched.
## Run: godot --headless --path . res://tests/bot_story_test.tscn  (failures exit nonzero)

const TEST_PROFILE := "user://profile_test.cfg"

var _checks := 0
var _failures := 0


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("BOT STORY TEST: " + label)


func _ready() -> void:
	PlayerProfile.path = TEST_PROFILE
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PROFILE))
	_profile()
	_data()
	_model()
	await _scene()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PROFILE))
	print("BOT STORY TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


# ---------------------------------------------------------------- input, as a player gives it
func _key(code: int, pressed := true, unicode := 0) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.unicode = unicode
	event.pressed = pressed
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame


func _tap(code: int, unicode := 0) -> void:
	await _key(code, true, unicode)
	await _key(code, false, unicode)


func _pad(button: int) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = button
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Press Enter through the open conversation until it closes (or a limit).
func _read_through(dialogue: BotDialogue) -> int:
	var presses := 0
	while dialogue.opened and presses < 40:
		await _tap(KEY_ENTER)
		presses += 1
	return presses


# ---------------------------------------------------------------- data and model
func _profile() -> void:
	_check(PlayerProfile.load_name() == "", "no profile yet: no name")
	_check(PlayerProfile.save_name("RIO") == OK and PlayerProfile.load_name() == "RIO", "the name round-trips through the profile")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PROFILE))


func _data() -> void:
	for k in 4:
		var path := "res://assets/maps/base_interior/base_interior%s.json" % ("" if k == 0 else "_r%d" % k)
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		var ids: Array = (meta["bulkheads"] as Array).map(func(b: Dictionary) -> String: return b["id"])
		_check(ids == ["power", "oxygen"], "two bulkheads in view %d" % k)
		_check(meta["game"].has("reserve_png") and FileAccess.file_exists(path.get_base_dir().path_join(meta["game"]["reserve_png"])),
				"the reserve overlay in view %d" % k)
		var st: Dictionary = meta["rooms"]["storage"]
		var cradle := Vector2(meta["bot"]["world"][0], meta["bot"]["world"][1])
		_check(cradle.distance_to(Vector2(st["center"][0], st["center"][1])) < float(st["radius"]) - 20.0,
				"the bot's cradle is in storage in view %d" % k)
		_check(not meta["rooms"].has("bay"), "no room just for the bot in view %d" % k)
	var bot: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Bot.BOT_JSON))
	_check(bot["facings"] == Array(Player.DIRS) and bot["face"].size() == 8, "the bot faces eight ways, like the astronaut")
	_check(bot["animations"].has_all(["dormant", "wake", "idle", "talk", "move"]), "five animations")


func _model() -> void:
	GameState.machine_repairs.clear()
	var s := StoryState.new()
	s.player_name = "ZED"
	var names: Dictionary = s.data["names"]
	_check(s.text("{BOT} {OWNER} {NAME}") == "%s %s ZED" % [names["bot"], names["previous_owner"]], "tokens filled from the names")
	_check(s.objectives().is_empty(), "no objectives before the bot hands them out")
	s.give_objectives()
	_check(s.objectives().size() == 2 and not s.all_done(), "two objectives, neither done")
	var first := s.next_talk()
	_check(first[0] == s.text(s.data["remind"]["both"]) and first.size() > 1, "talking: a reminder and a piece of trivia")
	GameState.repair_for("power").complete_task("cracks")
	GameState.repair_for("power").complete_task("wiring")
	_check(s.objective_done("power") and not s.objective_done("oxygen"), "a repaired reactor restores power")
	var lore := s.next_talk()
	_check(lore[0] == s.text(s.data["lore"][0]["lines"][0]), "its moment come, the power lore is told first")
	_check(s.next_talk()[0] == s.text(s.data["remind"]["oxygen"]), "then only the oxygen is left to remind you of")
	GameState.machine_repairs.clear()


# ---------------------------------------------------------------- in the real interior
func _scene() -> void:
	GameState.reset_inventory()
	GameState.machine_repairs.clear()
	GameState.story = StoryState.new()
	GameState.heading = 0
	GameState.intro_done = true
	var room := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await get_tree().process_frame
	await get_tree().process_frame
	var player: Player = room.get_node("Actors/Player")
	var tool: Multitool = room.get_node("Multitool")
	var terrain: MapTerrain = room.terrain
	var bot: Bot = room.bot
	var dialogue: BotDialogue = room.dialogue
	var names: NameEntry = room.names

	# sealed: the corridor to the power room is closed at its bulkhead
	var power: Bulkhead = room.bulkheads[0]
	_check(power.id == "power" and not power.opened and power.sprite.visible, "the power bulkhead starts sealed")
	_check(terrain.surface(power.world) == MapTerrain.Surface.SOLID, "a sealed bulkhead blocks its corridor")
	player.teleport(power.world + Vector2(-26, 0))
	player.forced_input = Vector2.RIGHT
	await _wait(1.2)
	player.forced_input = Vector2.ZERO
	_check(player.world_pos.x < power.world.x - 4.0, "walking at it, you stop at the bulkhead")

	# the bot only wakes to the tool, and only with the fix job
	player.teleport(bot.world + Vector2(bot.radius + 14.0, 0))
	await get_tree().process_frame
	_check(bot.state == Bot.State.DORMANT and not bot._prompt, "asleep: no talking to it")
	_check(tool._target == null, "with the tool away, nothing to work on")
	player.set_tool_out(true)
	await _wait(0.3)
	var target: Variant = tool._find_target()
	_check(target is Dictionary and target["job"] == "fix", "with the tool out, the bot is a fix job")
	tool.forced_use = true
	for i in 400:
		await get_tree().process_frame
		if GameState.story.bot_awake:
			break
	tool.forced_use = false
	tool._forced_pressed = false
	_check(GameState.story.bot_awake and bot.state == Bot.State.WAKING, "the fix job wakes it")
	for i in 300:
		await get_tree().process_frame
		if dialogue.opened:
			break
	_check(dialogue.opened and get_tree().paused, "awake, it talks; the world waits")
	_check(dialogue._current().contains(GameState.story.data["names"]["previous_owner"]) or
			dialogue._lines.any(func(l: String) -> bool: return l.contains(GameState.story.data["names"]["previous_owner"])),
			"it takes you for the previous owner")

	# Esc only finishes a line of the opening; Enter moves on
	await _tap(KEY_ESCAPE)
	_check(dialogue.opened, "the opening cannot be dismissed")
	await _read_through(dialogue)
	_check(names.opened and get_tree().paused, "then it asks who you are")

	# the name, typed: letters, a Backspace, a stray symbol ignored, Enter
	names.text = ""
	for ch in "zedx":
		await _tap(KEY_A + (ch.unicode_at(0) - "a".unicode_at(0)), ch.unicode_at(0))
	await _tap(KEY_BACKSPACE)
	await _tap(KEY_SLASH, "/".unicode_at(0))
	_check(names.text == "ZED", "typed lower case, shown upper case; backspace works; symbols ignored")
	await _tap(KEY_ENTER)
	_check(not names.opened and GameState.story.player_name == "ZED" and GameState.story.named, "Enter tells it your name")
	_check(PlayerProfile.load_name() == "ZED", "and it is remembered for next time")
	for i in 30:
		await get_tree().process_frame
		if dialogue.opened:
			break
	_check(dialogue._lines.any(func(l: String) -> bool: return l.contains("ZED")), "it calls you by your name")

	# reserve power: the bulkheads open and the corridors with them
	await _read_through(dialogue)
	_check(GameState.story.reserve_power and not get_tree().paused, "reserve power comes on, the world runs")
	await _wait(Bot.RESERVE_BEAT + 0.3)
	_check(room.bulkheads.all(func(b: Bulkhead) -> bool: return b.opened and not b.sprite.visible), "both bulkheads open")
	_check(terrain.surface(power.world) != MapTerrain.Surface.SOLID, "the corridor is clear")
	_check(room.fx._reserve.visible, "the emergency lines are lit")
	for i in 60:
		await get_tree().process_frame
		if dialogue.opened:
			break
	await _read_through(dialogue)
	_check(GameState.story.objectives_given and GameState.story.objectives().size() == 2, "it hands out the objectives")
	await get_tree().process_frame
	_check(bot.state == Bot.State.FOLLOW, "then it comes with you")
	_check(tool.bot_suppressed and bot._prompt, "beside the awake bot, F is its [F] TALK, not the tool's")

	# following: it keeps up, turns with its flight, and is never in your way
	var from := player.world_pos
	var saw_move := [false]
	player.forced_input = Vector2.RIGHT                  # away from the cradle, into the room
	var until := Time.get_ticks_msec() + 1200
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
		if bot._anim == "move":
			saw_move[0] = true
	player.forced_input = Vector2.ZERO
	_check(player.world_pos.distance_to(from) > 25.0, "walking with it about, nothing stops you")
	_check(saw_move[0], "it flies after you")
	await _wait(1.5)
	_check(bot.world.distance_to(player.world_pos) < 30.0, "it keeps close behind")
	_check(not bot._prompt and not tool.bot_suppressed, "behind you, it leaves F to the tool")
	_check(terrain.surface(bot.world) != MapTerrain.Surface.SOLID, "it stays on open floor")
	var look := terrain.view_dir(player.world_pos - bot.world)
	_check(bot._row == posmod(int(round(Vector2(look.x, -look.y).angle() / (PI / 4.0))), 8), "settled, it faces you")
	_check(not terrain.blockers.values().any(func(b: Vector3) -> bool: return Vector2(b.x, b.y).distance_to(bot.world) < 1.0),
			"it is never solid")

	# left far behind (the power room, through the open bulkhead), it blinks back in beside you
	var power_room := Vector2(236.0, 520.0)
	player.teleport(power_room)
	await _wait(0.3)
	_check(bot.world.distance_to(player.world_pos) < 40.0, "left far behind, it catches up")
	_check(GameState.story.bot_world != null and (GameState.story.bot_world as Vector2).distance_to(bot.world) < 1.0,
			"the story knows where it is")

	# the name on a gamepad: right, A, B deletes, A, Start
	var got := [""]
	names.open(GameState.story.data["name_entry"], "", func(v: String) -> void: got[0] = v)
	await get_tree().process_frame
	await _pad(JOY_BUTTON_DPAD_RIGHT)
	await _pad(JOY_BUTTON_A)
	_check(names.text == "B", "d-pad and A pick a letter")
	await _pad(JOY_BUTTON_B)
	_check(names.text == "", "B deletes")
	await _pad(JOY_BUTTON_START)
	_check(names.opened, "an empty name cannot be confirmed")
	await _pad(JOY_BUTTON_A)
	await _pad(JOY_BUTTON_START)
	_check(not names.opened and got[0] == "B", "Start confirms the name")

	# a camera turn keeps the bot on its foot and the bulkheads open
	room._apply_view(1, player.facing_dir())
	await get_tree().process_frame
	_check(bot.position == terrain.to_screen(bot.world, terrain.height_at(bot.world)).round(), "turned, the bot is drawn where it is")
	var v := terrain.view_dir(bot._facing)
	_check(bot._row == posmod(int(round(Vector2(v.x, -v.y).angle() / (PI / 4.0))), 8), "turned, it faces the same way in the world")
	_check(not power.sprite.visible and terrain.surface(power.world) != MapTerrain.Surface.SOLID, "turned, the bulkhead stays open")
	room._apply_view(0, player.facing_dir())

	# through the airlock and back: the story holds
	room.queue_free()
	await get_tree().process_frame
	room = load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(room.bot.state == Bot.State.FOLLOW and room.bulkheads.all(func(b: Bulkhead) -> bool: return b.opened),
			"after a reload: the bot with you, the bulkheads open")
	_check((room.get_node("Multitool") as Multitool)._fixables.is_empty(), "an awake bot is no fix job")

	# back in through the airlock: it meets you at the door
	room.queue_free()
	await get_tree().process_frame
	GameState.arrive = "interior"
	room = load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(room.bot.world.distance_to(room.door.stand_point()) < 40.0, "coming back in, it meets you at the door")
	await _wait(3.0)
	GameState.repair_for("oxygen").complete_task("cracks")
	GameState.repair_for("oxygen").complete_task("wiring")
	_check(GameState.story.objective_done("oxygen"), "a repaired O2 generator restores oxygen")
	room.queue_free()
	await get_tree().process_frame
	GameState.story = StoryState.new()
	GameState.machine_repairs.clear()
