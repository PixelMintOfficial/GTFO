extends Node
## Checks for Earth's reply (ReplyCutscene) in the real comms room with real key presses: a reply
## logged while the player is away waits for the room, plays once the astronaut is free, walks
## them to the console, types the message and the ETA, folds the terminal, gives the astronaut
## their line, hands the controls back only after F is let go, and never plays twice. Esc skips.
## Run: godot --headless --path . res://tests/reply_cutscene_test.tscn  (failures exit nonzero)

const COMMS := "res://scenes/comms.tscn"

var _checks := 0
var _failures := 0


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("REPLY TEST: " + label)


func _key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame


func _tap(code: int) -> void:
	await _key(code, true)
	await _key(code, false)


func _scene() -> Node:
	var scene: Node = load(COMMS).instantiate()
	get_tree().root.add_child.call_deferred(scene)
	await get_tree().process_frame
	await get_tree().process_frame
	return scene


func _cutscene(scene: Node) -> ReplyCutscene:
	for n in scene.get_children():
		if n is ReplyCutscene:
			return n
	return null


func _until(what: Callable, seconds: float) -> bool:
	var t := 0.0
	while t < seconds:
		if what.call():
			return true
		await get_tree().process_frame
		t += get_process_delta_time()
	return what.call()


func _ready() -> void:
	GameState.reset_inventory()
	GameState.repair_for("power").debug_complete(true)
	GameState.solar_field.debug_complete(true)
	GameState.comms_repair_progress = 1.0
	var mission := GameState.comms_mission
	_check(mission.transmit(GameState.clock - 2.0 * CommsMission.LEG_HOURS - 0.01, GameState.comms_powered()),
			"the powered screen sends the SOS")
	mission.advance(GameState.clock, GameState.comms_powered)
	_check(mission.reply_received and not mission.reply_shown, "the reply is logged before the player is in the room")
	var label: String = GameState.story.comms_objectives("base")[0]["label"]
	_check(label == GameState.story.data["comms"]["unread"], "the objective sends the player to read it at comms")

	var room := await _scene()
	var player: Player = room.player
	var reply := _cutscene(room)
	_check(reply != null, "the comms room has the reply cutscene")
	_check(await _until(func() -> bool: return reply.playing, 1.0), "the waiting reply plays on arrival")
	_check(mission.reply_shown and not player.controls_enabled and player.puppet, "it takes the astronaut and marks the reply read")
	_check(await _until(func() -> bool: return reply.step == ReplyCutscene.Step.MESSAGE, 8.0), "it walks, opens the terminal and decodes")
	var stand: Array = ViewData.get_json(room.terrain.view_json)["console_stand"]
	_check(player.world_pos.distance_to(Vector2(stand[0], stand[1])) < 1.0, "the astronaut stands at the console")
	await _tap(KEY_F)
	_check(reply._eta_shown and reply._shown >= reply._message().length(), "F finishes the message and shows the ETA")
	await _tap(KEY_F)
	_check(reply.step == ReplyCutscene.Step.SHUT, "F again folds the terminal")
	_check(await _until(func() -> bool: return reply.step == ReplyCutscene.Step.SPEAK, 2.0), "the astronaut gets their line")
	await _tap(KEY_F)
	_check(reply._shown >= reply._speech().length(), "F finishes the astronaut's line")
	await _key(KEY_F, true)
	_check(reply.step == ReplyCutscene.Step.END, "F closes the cutscene")
	_check(await _until(func() -> bool: return not reply.playing, 2.0), "the bars slide away")
	await get_tree().process_frame
	_check(not player.controls_enabled, "controls wait for F to be let go")
	await _key(KEY_F, false)
	await get_tree().process_frame
	_check(player.controls_enabled and not player.puppet, "letting go of F hands the controls back")
	label = GameState.story.comms_objectives("base")[0]["label"]
	_check(label == GameState.story.data["comms"]["received"], "the objective shows the rescue ETA")
	for i in 30:
		await get_tree().process_frame
	_check(not reply.playing, "the reply never plays twice")
	room.queue_free()
	await get_tree().process_frame

	# Esc skips straight to the end
	mission.reply_shown = false
	room = await _scene()
	reply = _cutscene(room)
	_check(await _until(func() -> bool: return reply.playing, 1.0), "an unread reply plays again in a fresh room")
	await _tap(KEY_ESCAPE)
	_check(reply.step == ReplyCutscene.Step.END, "Esc skips to the end")
	_check(await _until(func() -> bool: return room.player.controls_enabled, 2.0), "a skip hands the controls back")
	room.queue_free()
	print("REPLY TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)
