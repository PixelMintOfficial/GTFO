extends Node
## Nursery integration: four-view metadata, solid furniture, reachable approaches,
## real F/X input on the nursery airlocks, camera turns and session continuity.
## Also checks the comms airlock, main-base power gate, SOS and radiation shelter.
## Run: godot --headless --path . res://tests/nursery_test.tscn

const WORLD := "res://scenes/overworld.tscn"
const ROOM := "res://scenes/nursery.tscn"
const MAP := "res://assets/maps/nursery_interior/nursery.json"
const COMMS := "res://scenes/comms.tscn"
const COMMS_ID := 3
var _checks := 0
var _failures := 0


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("NURSERY TEST: " + label)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_data()
	# Keep this runner alive while the real scene-change handlers replace current_scene.
	get_tree().current_scene = null
	GameState.intro_done = true
	GameState.heading = 0
	GameState.clock = 12.
	GameState.suit_light = true
	GameState.tool_out = true
	var water := GameState.item_count("water")
	var world := load(WORLD).instantiate() as Node2D
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	await get_tree().process_frame
	for entry in [1, 5]:
		world = get_tree().current_scene as Node2D
		var outer := _find_door(world, entry)
		_check(outer != null, "nursery exterior door %d exists" % entry)
		if outer == null:
			break
		var player: Player = world.player
		player.teleport(outer.stand_point())
		await _wait(.15)
		_check(outer._prompt, "entry %d offers F prompt" % entry)
		_check(world.multitool.suppressed, "other doors do not release entry suppression")
		var clock := GameState.clock
		await _interact(entry == 5)
		if not await _scene(ROOM):
			break
		var nursery := get_tree().current_scene as Node2D
		await _arrival(nursery)
		_check(nursery.doors.size() == 2, "two nursery exits")
		_check(GameState.door_id == entry, "entered matching nursery doorway")
		var arrival := _find_door(nursery, entry)
		_check(nursery.player.world_pos.distance_to(arrival.stand_point()) < 2., "matching inside arrival")
		_check(GameState.clock > clock, "clock continues through entering")
		_check(GameState.suit_light, "suit light survives entering")
		_check(nursery.player.tool_state == Player.Tool.READY, "equipped tool survives entering")
		_check(nursery.player.camera.zoom_locked, "nursery keeps indoor zoom lock")
		if entry == 1:
			var feet: Vector2 = nursery.player.world_pos
			var scale := float(ViewData.get_json(MAP)["game"]["layout_scale"])
			nursery.player.teleport(_layout(Vector2(0., 430.), scale))
			nursery.player.forced_input = Vector2(0., -1.)
			await _wait(2.)
			nursery.player.forced_input = Vector2.ZERO
			_check(nursery.player.world_pos.y > _layout(Vector2(0, 480), scale).y and nursery.player.world_pos.y < _layout(Vector2(0, 498), scale).y,
				"walk crosses shallow channel and stops at specimen plinth")
			nursery.player.teleport(_layout(Vector2(100., 505.), scale))
			nursery.player.forced_input = Vector2(1., 0.)
			await _wait(1.2)
			nursery.player.forced_input = Vector2.ZERO
			_check(nursery.player.world_pos.x > 108. * scale and nursery.player.world_pos.x < 124. * scale,
				"walk stops at oxygen tank")
			nursery.player.teleport(feet)
			for heading in [1, 2, 3, 0]:
				await _tap(KEY_H)
				for tick in 100:
					if not nursery.view_turn.busy:
						break
					await _wait(.03)
				_check(nursery.terrain.heading == heading, "native camera turn %d" % heading)
				_check(nursery.player.world_pos.distance_to(feet) < .01, "turn retains canonical feet")
				_check(nursery.doors.size() == 2, "turn retains both exits")
				for id in [1, 5]:
					_check(_find_door(nursery, id) != null, "reprojected exit %d" % id)
		var exit_id: int = 5 if entry == 1 else 1
		var inside := _find_door(nursery, exit_id)
		nursery.player.teleport(inside.stand_point())
		await _wait(.15)
		_check(inside._prompt, "opposite exit offers interaction")
		_check(nursery.multitool.suppressed, "both exits jointly suppress tool")
		await _interact(entry == 1)
		if not await _scene(WORLD):
			break
		world = get_tree().current_scene as Node2D
		await _arrival(world)
		var outside := _find_door(world, exit_id)
		_check(GameState.door_id == exit_id, "exit chooses correct outdoor door")
		_check(world.player.world_pos.distance_to(outside.stand_point()) < 2., "matching outside arrival")
		_check(GameState.suit_light, "suit light survives exit")
		_check(world.player.tool_state == Player.Tool.READY, "tool survives exit")
		_check(GameState.item_count("water") == water, "inventory survives both transitions")
	if _failures == 0:
		await _comms_round_trip()
	print("NURSERY TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


func _comms_round_trip() -> void:
	var world := get_tree().current_scene as Node2D
	var entry := _find_door(world, COMMS_ID)
	_check(entry != null, "comms exterior entrance exists")
	if entry == null:
		return
	_check(world.terrain.is_walkable(entry.stand_point()), "comms entrance stands on traversable ground")
	world.player.teleport(entry.stand_point())
	await _wait(.15)
	_check(entry._prompt, "comms exterior offers the enter prompt")
	await _interact(false)
	if not await _scene(COMMS):
		return
	var room := get_tree().current_scene as Node2D
	await _arrival(room, [room.door])
	_check(GameState.door_id == COMMS_ID, "the comms airlock IDs match")
	_check(room.player.world_pos.distance_to(room.door.stand_point()) < 2., "arrives inside comms")
	_check(room.player.camera.zoom_locked, "comms keeps indoor zoom lock")
	var feet: Vector2 = room.player.world_pos
	var heading: int = room.terrain.heading
	await _tap(KEY_H)
	for tick in 100:
		if room.player.controls_enabled and room.terrain.heading != heading:
			break
		await _wait(.03)
	_check(room.terrain.heading == (heading + 1) % 4, "comms turns to the next native view")
	_check(room.player.world_pos.distance_to(feet) < .01, "comms turn keeps the astronaut in place")
	await _comms_repair(room)
	var mission := GameState.comms_mission
	GameState.clock = 10.7
	await _interact(true)
	_check(mission.stage(GameState.clock) == CommsMission.Stage.OUTBOUND, "pad X sends a fresh SOS at the console")
	await _tap(KEY_E)
	var paused_clock := GameState.clock
	await _wait(.15)
	_check(get_tree().paused and GameState.clock == paused_clock, "backpack pauses the signal clock")
	await _tap(KEY_E)
	GameState.clock = mission._sent_at + CommsMission.LEG_HOURS + .01
	GameState.survival.set_value("radiation", 50.)
	await _wait(.2)
	_check(mission.stage(GameState.clock) == CommsMission.Stage.INBOUND and not mission.reply_received,
			"Earth replies after the first leg and the player has to wait for the return")
	_check(GameState.survival.values["radiation"] < 50., "comms pedestal shelters the player during the storm")
	await _interact(false)
	_check(mission.stage(GameState.clock) == CommsMission.Stage.INBOUND, "repeated console input cannot restart the SOS")
	room.player.teleport(room.door.stand_point())
	await _wait(.15)
	await _interact(true)
	if not await _scene(WORLD):
		return
	world = get_tree().current_scene as Node2D
	await _arrival(world)
	var exit := _find_door(world, COMMS_ID)
	_check(exit != null and world.player.world_pos.distance_to(exit.stand_point()) < 2., "returns to the same comms airlock")
	_check(GameState.comms_repair_progress == 1.0, "screen repair survives leaving comms")
	var dose: float = GameState.survival.values["radiation"]
	await _wait(.2)
	_check(GameState.survival.values["radiation"] > dose, "outside the comms shelter, the storm raises exposure")
	GameState.solar_field.toggle_feed(0)
	GameState.clock = mission._sent_at + 2.0 * CommsMission.LEG_HOURS + .01
	await _wait(.1)
	_check(mission.stage(GameState.clock) == CommsMission.Stage.RECEIVER_OFFLINE, "a due reply waits until the receiver has power")
	GameState.solar_field.toggle_feed(0)
	await _wait(.1)
	_check(mission.reply_received and GameState.story.comms_objectives("base")[0]["done"],
			"restoring the receiver completes the SOS even while the player is outside")


func _comms_repair(room: Node2D) -> void:
	_check(DayNight.fixture_power == 0.0, "comms starts dark")
	GameState.repair_for("power").debug_complete(true)
	GameState.solar_field.debug_complete(true)
	await _wait(.1)
	_check(GameState.base_powered() and DayNight.fixture_power == 0.0, "base mains alone leave comms dark")
	GameState.solar_field.toggle_feed(0)
	var stand: Array = ViewData.get_json(room.terrain.view_json)["console_stand"]
	room.player.teleport(Vector2(stand[0], stand[1]))
	await _wait(.15)
	var press := InputEventKey.new()
	press.physical_keycode = KEY_F
	press.pressed = true
	Input.parse_input_event(press)
	await _wait(Multitool.TIMES["fix"] + .35)
	press = InputEventKey.new()
	press.physical_keycode = KEY_F
	Input.parse_input_event(press)
	await _wait(.1)
	_check(GameState.comms_repair_progress == 1.0, "holding F repairs the screen")
	_check(DayNight.fixture_power == 0.0 and "standby" in room.terrain.view_json, "repaired screen waits for full mains")
	await _interact(false)
	_check(not GameState.comms_mission.has_transmitted(), "a repaired but unpowered screen cannot send")
	GameState.solar_field.toggle_feed(0)
	await _wait(.1)
	_check(DayNight.fixture_power == 1.0 and "online" in room.terrain.view_json, "restored mains light the repaired room")
	GameState.solar_field.toggle_feed(0)
	await _wait(.1)
	_check(DayNight.fixture_power == 0.0 and GameState.comms_repair_progress == 1.0, "mains loss keeps the repair")
	GameState.solar_field.toggle_feed(0)
	await _wait(.1)


func _data() -> void:
	for heading in 4:
		var terrain := MapTerrain.new(MAP, heading)
		var meta := ViewData.get_json(terrain.view_json)
		_check(terrain.heading == heading, "four generated headings")
		_check(meta["doors"].size() == 2, "two generated exits")
		_check(terrain.is_walkable(terrain.spawn), "walkable nursery spawn")
		var scale := float(meta["game"]["layout_scale"])
		_check(scale <= .85 and terrain.character_scale == .5, "smaller room keeps the shared astronaut scale")
		for point in [Vector2(0, 480), Vector2(-90, 526), Vector2(102, 505), Vector2(0, 600)]:
			_check(terrain.is_walkable(_layout(point, scale)), "open approach %s" % point)
		for point in [Vector2(0, 522), Vector2(0, 393), Vector2(-123, 526), Vector2(135, 505), Vector2(200, 520)]:
			_check(not terrain.is_walkable(_layout(point, scale)), "solid furniture/shell %s" % point)
		for info in meta["doors"]:
			var stand := Vector2(info["world"][0], info["world"][1]) + Vector2(info["dir"][0], info["dir"][1]) * 26.
			_check(terrain.is_walkable(stand), "walkable exit approach")
			_check(int(info["id"]) in [1, 5], "stable exterior/interior door id")
			_check(is_equal_approx(float(info["sort_y"]), roundf(float(info["sort_y"]))), "whole-pixel sorting")
		var world_meta := ViewData.get_json("res://assets/maps/red_planet/red_planet_map%s.json" % ("" if heading == 0 else "_r%d" % heading))
		var destinations := {0: "res://scenes/interior.tscn", 1: ROOM, 2: "res://scenes/interior.tscn",
				COMMS_ID: COMMS, 5: ROOM}
		for info in ViewData.fx_of("res://assets/maps/red_planet/red_planet_map%s.json" % ("" if heading == 0 else "_r%d" % heading), world_meta)["doors"]:
			_check(info["interior"] == destinations.get(int(info["id"])), "generated destination")
			_check(is_equal_approx(float(info["sort_y"]), roundf(float(info["sort_y"]))), "outside whole-pixel sorting")


func _layout(point: Vector2, scale: float) -> Vector2:
	return Vector2(0, 520) + (point - Vector2(0, 520)) * scale


func _find_door(scene: Node, id: int) -> AirlockDoor:
	for door in scene.doors:
		if int(door.get_meta("id")) == id:
			return door
	return null


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _scene(path: String) -> bool:
	for tick in 320:
		if get_tree().current_scene != null and get_tree().current_scene.scene_file_path == path:
			await get_tree().process_frame
			return true
		await _wait(.05)
	_check(false, "scene transition timed out: " + path)
	return false


func _arrival(scene: Node, doors := []) -> void:
	if doors.is_empty():
		doors = scene.doors
	for tick in 200:
		var busy := false
		for door in doors:
			busy = busy or door.busy()
		if not busy:
			return
		await _wait(.03)
	_check(false, "arrival cutscene timed out")


func _tap(key: int) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.physical_keycode = key
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
		await get_tree().process_frame


func _interact(pad: bool) -> void:
	if not pad:
		await _tap(KEY_F)
		return
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.button_index = JOY_BUTTON_X
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
		await get_tree().process_frame
