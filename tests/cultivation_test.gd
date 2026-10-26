extends Node
## Cultivation model and real-scene input regression. Exercises night-only wild seeds,
## independent repairs, atomic full-bag harvests, seed costs, growth/regrowth, fruit use,
## real F/gamepad X, release guards, map variants, camera views and session continuity.
## Run through make check, or godot --headless --path . res://tests/cultivation_test.tscn.
## Optional native-render evidence: omit --headless and pass -- --cultivation-captures=ABSOLUTE_DIR.
## Flush synthetic events and allow process frames: native texture uploads can outlast a short timer.
## Nursery scans require the real equipped tool, use_* pose, held F/X and resumable progress.

var _checks := 0
var _failures := 0
var _captures := ""


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("CULTIVATION TEST: " + label)


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--cultivation-captures="):
			_captures = arg.trim_prefix("--cultivation-captures=")
			DirAccess.make_dir_recursive_absolute(_captures)
	_run.call_deferred()


func _model() -> void:
	GameState.reset_inventory()
	_check(not GameState.cultivation.repair("console"), "nursery UNIT must be repaired first")
	GameState.story.nursery_awake = true
	GameState.story.nursery_introduced = true
	var state := GameState.cultivation
	_check(not CultivationState.is_night(19.99) and CultivationState.is_night(20.), "night begins at 20")
	_check(CultivationState.is_night(28.99) and not CultivationState.is_night(29.), "night closes at next dawn")
	_check(not state.gather("moonwell_00", "moonwell", 12.), "daytime Moonwell seeds unavailable")
	_check(GameState.item_count("dewpod_seed") == 0, "daytime attempt changes no inventory")
	_check(state.gather("moonwell_00", "moonwell", 22.), "nighttime Moonwell yields seeds")
	_check(GameState.item_count("dewpod_seed") == 3, "one handful covers two water silos")
	_check(not state.gather("moonwell_00", "moonwell", 22.), "same wild plant cannot be collected twice")
	_check(state.gather("cindercoil_00", "cindercoil", 12.), "Cindercoil available by day")
	_check(GameState.item_count("emberpod_seed") == 3, "one handful covers three food racks")
	_check(not state.plant("rack0", 12.), "broken nursery cannot be planted")
	for id in ["rack", "console", "light"]:
		_check(state.repair(id), "independent repair " + id)
		_check(not state.repair(id), "repaired system cannot repeat " + id)
	_check(state.repairs == 7 and not state.repair("unknown"), "repair mask and unknown IDs")
	_check(state.plant("rack0", 12.), "plant a food rack")
	_check(GameState.item_count("emberpod_seed") == 2, "planting spends one seed")
	_check(not state.plant("rack0", 12.) and GameState.item_count("emberpod_seed") == 2, "repeat planting cannot spend more seeds")
	_check(state.stage("rack0", 35.99) == 1 and not state.harvest("rack0", 35.99), "crops cannot be harvested before a full game day")
	_check(state.stage("rack0", 36.) == 2, "first crop ready exactly one day after planting")
	for i in GameState.inventory.size():
		GameState.inventory[i] = {"kind": "scrap", "count": 99}
	GameState.inventory[1] = {"kind": "emberpod", "count": 98}
	_check(not state.harvest("rack0", 36.), "whole harvest rejected when only one slot unit fits")
	_check(state.stage("rack0", 36.) == 2 and GameState.item_count("emberpod") == 98, "full bag keeps crop and existing stack untouched")
	GameState.inventory[2] = {}
	_check(state.harvest("rack0", 36.), "harvest fits across stacks")
	_check(GameState.item_count("emberpod") == 101, "whole configured yield stored")
	_check(state.stage("rack0", 59.99) == 1 and state.stage("rack0", 60.) == 2, "regrowth takes another full game day without more seeds")
	GameState.survival.set_value("hunger", 40.)
	_check(GameState.consume_slot(1) and GameState.survival.values["hunger"] == 60., "Emberpod restores hunger")
	GameState.inventory[3] = {"kind": "dewpod", "count": 1}
	GameState.survival.set_value("thirst", 40.)
	_check(GameState.consume_slot(3) and GameState.survival.values["thirst"] == 65., "Dewpod restores thirst")
	for i in GameState.inventory.size():
		GameState.inventory[i] = {"kind": "scrap", "count": 99}
	_check(not state.gather("moonwell_full", "moonwell", 22.), "full bag rejects seed handful")
	_check(not state.wild_ready_at.has("moonwell_full"), "full bag leaves wild seed source untouched")
	GameState.reset_inventory()
	GameState.stock_supplies()
	GameState.survival.reset()


func _run() -> void:
	_model()
	get_tree().current_scene = null
	GameState.intro_done = true
	GameState.heading = 0
	GameState.clock = 12.
	var scene := load("res://scenes/nursery.tscn").instantiate() as Node2D
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	await _wait(.2)
	_check(scene.terrain.view_json.ends_with("nursery.json"), "nursery starts with damaged art")
	_check(scene.cultivation.visuals["rack1"].sprite.frame == 3, "broken centre rack crops follow its sagging shelf")
	for id in ["console", "light", "rack"]:
		scene.player.teleport(scene.cultivation.interaction_point(id))
		await _wait(.12)
		_check(scene.cultivation.nearest == id, "reachable repair target " + id)
		if id == "console":
			await _capture("nursery-broken")
			await _tap()
			_check(not GameState.cultivation.repaired(id), "holstered F cannot repair nursery")
			_check(not scene.multitool._working, "holstered F cannot start scanner")
			await _toggle_tool()
			_check(scene.player.tool_state == Player.Tool.READY, "real T equips multitool")
			_use_event(false, true)
			await _wait(.55)
			_check(scene.multitool._working and scene.player.work_target != null, "equipped hold runs existing fix job")
			_check(str(scene.player.sprite.animation).begins_with("use_"), "scanner uses astronaut fixing pose")
			_check(not GameState.cultivation.repaired(id), "brief scan cannot complete repair")
			await _capture("nursery-scanning")
			_use_event(false, false)
			await _wait(.12)
			var partial := float(GameState.cultivation.repair_progress[id])
			_check(partial > 0.0 and partial < 1.0 and not scene.multitool._working, "release pauses unfinished scan")
			scene.player.teleport(Vector2(0., 520.))
			await _wait(.12)
			_check(scene.multitool._fixables.is_empty(), "out of reach removes scanner target")
			scene._apply_view(1, scene.player.facing_dir())
			scene.player.teleport(scene.cultivation.interaction_point(id))
			await _wait(.12)
			_check(is_equal_approx(float(scene.cultivation._fixable["progress"]), partial), "camera turn preserves unfinished scan")
			scene.queue_free()
			await get_tree().process_frame
			GameState.tool_out = true # The airlock normally carries the equipped state.
			scene = load("res://scenes/nursery.tscn").instantiate() as Node2D
			get_tree().root.add_child(scene)
			get_tree().current_scene = scene
			scene.player.teleport(scene.cultivation.interaction_point(id))
			await _wait(.12)
			_check(is_equal_approx(float(scene.cultivation._fixable["progress"]), partial), "returning to nursery restores unfinished scanner progress")
			await _toggle_tool()
			await _tap()
			_check(not GameState.cultivation.repaired(id) and is_equal_approx(float(GameState.cultivation.repair_progress[id]), partial), "unequipping blocks repair and retains progress")
			await _toggle_tool()
		if id == "light":
			await _capture("grower-cleaned")
		if id == "rack":
			await _capture("rack-broken")
		_use_event(id == "light", true)
		await _wait(Multitool.TIMES["fix"] + .3)
		_use_event(id == "light", false)
		await _wait(.12)
		_check(GameState.cultivation.repaired(id), "held multitool F/X repairs " + id)
		_check(GameState.cultivation.repair_progress[id] == 1.0, "completed scan stored " + id)
		if id == "rack":
			await _capture("rack-repaired")
	_check(scene.terrain.view_json.contains("nursery_repairs_7"), "completed repairs replace colour/depth/walk/light together")
	_check(scene.doors.size() == 2, "repairs preserve both airlocks")
	_check(GameState.cultivation.beds.is_empty(), "finishing held repair cannot also plant")
	_check(scene.multitool._fixables.is_empty(), "completed repairs leave no tool targets")
	_check(scene.cultivation.visuals["rack1"].sprite.frame == 0, "rack repair restores crop alignment before reseeding")
	GameState.store_items("emberpod_seed", 3)
	GameState.store_items("dewpod_seed", 3)
	for id in ["rack0", "rack1", "rack2", "silo0", "silo1"]:
		scene.player.teleport(scene.cultivation.interaction_point(id))
		await _wait(.12)
		_check(scene.terrain.is_walkable(scene.player.world_pos), "walkable planting approach " + id)
		var input_probe := [scene.cultivation._nearest(), scene.cultivation._release_guard,
			Input.is_action_pressed("interact"), scene.cultivation._can_interact()]
		await _tap(id == "silo1")
		if not GameState.cultivation.beds.has(id):
			print("PLANT INPUT PROBE %s: target/guard/held/can=%s" % [id, input_probe])
		_check(GameState.cultivation.beds.has(id), "real input plants " + id)
	_check(GameState.item_count("emberpod_seed") == 0 and GameState.item_count("dewpod_seed") == 1, "all five beds spend expected seeds")
	await _capture("nursery-growing")
	GameState.clock += 24.1
	await _wait(.05)
	for heading in [1, 2, 3, 0]:
		scene._apply_view(heading, scene.player.facing_dir())
		await _wait(.02)
		_check(scene.cultivation.visuals.size() == 5, "five reprojected crops in view %d" % heading)
		_check(scene.terrain.heading == heading, "repaired view heading %d" % heading)
		for visual in scene.cultivation.visuals.values():
			_check(visual.sprite.frame == 2, "ripe art survives camera view")
	scene.player.teleport(scene.cultivation.interaction_point("rack0"))
	await _wait(.1)
	await _capture("nursery-ripe")
	await _tap()
	_check(GameState.item_count("emberpod") == 3, "native input harvest stores fruit")
	if not _captures.is_empty():
		for i in GameState.inventory.size():
			if GameState.inventory[i].get("kind", "") == "emberpod":
				GameState.select_slot(i)
		for child in scene.get_children():
			if child is InventoryUI:
				child.toggle()
				await _capture("harvest-backpack")
				child.toggle()
	var state := GameState.cultivation
	scene.queue_free()
	await get_tree().process_frame
	GameState.clock = 12.
	scene = load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child(scene)
	get_tree().current_scene = scene
	await _wait(.2)
	_check(GameState.cultivation == state and state.repairs == 7, "airlock lifetime preserves nursery session state")
	_check(scene.cultivation.visuals.size() == 32, "all dispersed wild plants exist")
	for id in scene.cultivation.targets:
		scene.player.teleport(scene.cultivation.interaction_point(id))
		await _wait(.12)
		_check(scene.terrain.is_walkable(scene.player.world_pos), "stable wild approach " + id)
		_check(scene.cultivation._nearest() == id, "actual interaction reachable " + id)
	scene.player.teleport(scene.cultivation.interaction_point("moonwell_00"))
	await _wait(.12)
	await _capture("moonwell-day-closed")
	await _tap()
	_check(GameState.item_count("dewpod_seed") == 1, "real daytime F cannot gather Moonwell")
	GameState.clock = 22.
	await _wait(1.3)
	_check(scene.cultivation._bloom >= .99, "Moonwell opens during night")
	_check(scene.cultivation._nearest() == "moonwell_00", "night flower has a reachable interaction")
	await _capture("moonwell-night-open")
	await _tap(true)
	_check(GameState.item_count("dewpod_seed") == 4, "real gamepad X collects night seeds")
	_check(scene.cultivation.visuals["moonwell_00"].sprite.frame == 17, "collected open flower loses seed cluster")
	await _capture("moonwell-collected")
	GameState.clock = 29.
	await _wait(1.3)
	_check(scene.cultivation._bloom <= .01, "Moonwell closes at dawn")
	scene.player.teleport(scene.cultivation.interaction_point("cindercoil_00"))
	await _wait(.12)
	await _capture("cindercoil-day")
	await _tap()
	_check(GameState.item_count("emberpod_seed") == 3, "real F gathers daytime food seeds")
	# Holding F while moving to another plant must not auto-collect or let X bypass release.
	var held := InputEventKey.new()
	held.physical_keycode = KEY_F
	held.pressed = true
	Input.parse_input_event(held)
	Input.flush_buffered_events()
	await get_tree().process_frame
	await _wait(.08)
	scene.player.teleport(scene.cultivation.interaction_point("cindercoil_01"))
	await _wait(.12)
	await _tap(true)
	_check(GameState.item_count("emberpod_seed") == 3, "held F owns release guard across targets and gamepad input")
	held = InputEventKey.new()
	held.physical_keycode = KEY_F
	Input.parse_input_event(held)
	Input.flush_buffered_events()
	await get_tree().process_frame
	await _wait(.08)
	await _tap()
	_check(GameState.item_count("emberpod_seed") == 6, "releasing F allows the next plant collection")
	print("CULTIVATION TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	# A slow upload frame can finish several timers before the next world _process.
	await get_tree().process_frame
	await get_tree().process_frame


func _toggle_tool() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_T
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await _wait(.05)
	event = InputEventKey.new()
	event.physical_keycode = KEY_T
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await _wait(1.5)


func _use_event(pad: bool, pressed: bool) -> void:
	if pad:
		var event := InputEventJoypadButton.new()
		event.button_index = JOY_BUTTON_X
		event.pressed = pressed
		Input.parse_input_event(event)
	else:
		var event := InputEventKey.new()
		event.physical_keycode = KEY_F
		event.pressed = pressed
		Input.parse_input_event(event)
	Input.flush_buffered_events()


func _capture(label: String) -> void:
	if _captures.is_empty():
		return
	await _wait(.2)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_captures.path_join(label + ".png"))
	print("CULTIVATION CAPTURE: " + label)


func _tap(pad := false) -> void:
	if pad:
		var event := InputEventJoypadButton.new()
		event.button_index = JOY_BUTTON_X
		event.pressed = true
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await get_tree().process_frame
		await get_tree().process_frame
		await _wait(.07)
		event = InputEventJoypadButton.new()
		event.button_index = JOY_BUTTON_X
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	else:
		var event := InputEventKey.new()
		event.physical_keycode = KEY_F
		event.pressed = true
		Input.parse_input_event(event)
		Input.flush_buffered_events()
		await get_tree().process_frame
		await get_tree().process_frame
		await _wait(.07)
		event = InputEventKey.new()
		event.physical_keycode = KEY_F
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await get_tree().process_frame
	await get_tree().process_frame
	await _wait(.12)
