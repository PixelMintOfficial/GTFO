extends Node
## End-to-end glass repair: real pickups, inventory, live reach/physics, quarter-turn placement,
## resumable scans, atomic cost, independent panes, view/variant/airlock persistence and the
## final box collapse. Drives the production UI/model rather than an alternate puzzle.
## Paused scans must also compose the paired nighttime pixels, not only the daylight map.

var _checks := 0
var _failures := 0
var _catalog: Dictionary


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("WINDOW GLASS TEST: " + label)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _ready() -> void:
	_catalog = JSON.parse_string(FileAccess.get_file_as_string(GlassRepairUI.DIR + "catalog.json"))
	_model()
	await get_tree().process_frame
	await _scene()
	print("WINDOW GLASS TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


func _model() -> void:
	_check(_catalog.size() == 3, "all three authored shapes included")
	for id in _catalog:
		var puzzle := GlassPuzzle.new(_catalog[id])
		_check(puzzle.placed.size() == 6 and puzzle.definition["cost"] == 6, id + " has six fragments")
		_check(not puzzle.place(0, puzzle.target(0)), id + " rejects wrong rotation at correct position")
		while puzzle.rotations[0] != 0:
			puzzle.rotate(0)
		_check(not puzzle.place(0, puzzle.target(0) + Vector2(12, 0)), id + " rejects wrong position")
		_check(puzzle.place(0, puzzle.target(0)) and not puzzle.place(0, puzzle.target(0)), id + " fits exactly once")
		_check(not puzzle.advance(3) and puzzle.scan == 0, id + " incomplete board never scans")
		for i in range(1, 6):
			puzzle.rotations[i] = 0
			puzzle.place(i, puzzle.target(i))
		_check(puzzle.scanning() and not puzzle.advance(.6) and absf(puzzle.scan - .25) < .001, id + " scan follows authored duration")
		var damage := (load(GlassRepairUI.DIR + puzzle.definition["damage"]) as Texture2D).get_image()
		var clipped := true
		for x in damage.get_width():
			clipped = clipped and damage.get_pixel(x, 0).a == 0 and damage.get_pixel(x, 95).a == 0
		_check(clipped, id + " damage stays inside pane")


func _key(key: int, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = key
	e.pressed = pressed
	Input.parse_input_event(e)
	await _wait(.05)


func _mouse(p: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	Input.parse_input_event(e)
	await _wait(.05)


func _pad(button: int) -> void:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = true
	Input.parse_input_event(e)
	await _wait(.05)
	e = InputEventJoypadButton.new()
	e.button_index = button
	e.pressed = false
	Input.parse_input_event(e)
	await _wait(.05)


func _room() -> Node2D:
	var room := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child(room)
	return room


func _fit(panel: GlassRepairUI, count: int) -> void:
	for i in count:
		if panel.puzzle.placed[i]:
			continue
		panel.choose(i)
		while panel.puzzle.rotations[i] != 0:
			panel.rotate()
		panel.point = GlassRepairUI.PANE.position + panel.puzzle.target(i)
		_check(panel.place(), "production panel places correct fragment")


func _scene() -> void:
	GameState.reset_inventory()
	GameState.heading = 0
	GameState.intro_done = true
	var room := _room()
	await get_tree().process_frame
	var player: Player = room.player
	var tool: Multitool = room.multitool
	var cracks: WindowCracks = room.cracks
	var glass: Array = tool._props.filter(func(p: WorldProp) -> bool: return p.kind == "glass")
	_check(glass.size() == 18, "exactly enough world glass for three windows")
	for p in glass:
		_check(room.terrain.surface(p.world) == MapTerrain.Surface.WALK, "glass pickup is on reachable floor: %s" % p.world)
	# Gather an actual world prop through the real multitool.
	player.set_tool_out(true)
	player.teleport(glass[0].world + Vector2(0, -3))
	player._set_facing(glass[0].world - player.world_pos)
	tool.forced_use = true
	await _wait(.8)
	tool.forced_use = false
	tool._forced_pressed = false
	await _wait(.2)
	_check(GameState.item_count("glass") == 1, "multitool gathers the generated glass asset")
	player.teleport(cracks.place_box_under("crescent"))
	player.landed.emit(0)
	_check(not cracks.open_window("crescent"), "insufficient glass does not open or spend")
	for i in 17:
		GameState.store_item("glass")
	await _wait(.05)
	await _key(KEY_F, true)
	await _key(KEY_F, false)
	_check(cracks.panel.opened and not get_tree().paused and not player.controls_enabled, "F opens a live modal from the stable box")
	var panel := cracks.panel
	var initial_clock := GameState.clock
	var initial_hunger: float = GameState.survival.values["hunger"]
	# Actual pointer drag and R input, through the normal viewport, fit the first fragment.
	await _mouse(panel._canvas.get_global_transform() * panel._slot(0).get_center().floor(), true)
	for i in 3:
		await _key(KEY_R, true)
		await _key(KEY_R, false)
	var motion := InputEventMouseMotion.new()
	motion.position = panel._canvas.get_global_transform() * (GlassRepairUI.PANE.position + panel.puzzle.target(0))
	Input.parse_input_event(motion)
	await _wait(.05)
	await _mouse(motion.position, false)
	_check(panel.puzzle.placed[0], "pointer drag plus quarter-turn keyboard input fits glass")
	_fit(panel, 2)
	await _wait(.2)
	_check(GameState.clock > initial_clock, "world clock keeps running")
	_check(GameState.survival.values["hunger"] < initial_hunger, "live window panel keeps survival running")
	_check(player.height_above_floor() > 14 and not player.is_airborne(), "player remains stable on set-down box")
	_check(GameState.item_count("glass") == 18, "fitting consumes nothing")
	panel.close()
	_check(player.controls_enabled and tool.window_suppressed, "close restores controls and requires F release")
	Input.action_press("tool_use")
	await _wait(.1)
	_check(cracks._release_guard and tool.window_suppressed, "holding F after close cannot gather, lift or reopen")
	Input.action_release("tool_use")
	await _wait(.05)
	_check(not cracks._release_guard, "released input clears the guard")
	_check(cracks.open_window("crescent") and panel.puzzle.fitted() == 2, "fitted pieces survive closing")
	_fit(panel, 6)
	await _wait(.5)
	var kept_scan := panel.puzzle.scan
	_check(kept_scan > .1 and kept_scan < 1 and GameState.item_count("glass") == 18, "scan runs without early spend")
	panel.close()
	await _wait(.2)
	_check(is_equal_approx(panel.puzzle.scan, kept_scan), "closed scan pauses")
	var model := panel.puzzle
	var untouched: Texture2D = load("res://assets/maps/base_interior/base_interior.png")
	_check(room.terrain.map_texture.get_image().get_data() != untouched.get_image().get_data(), "paused scan rows are included in the turn's map")
	var no_sun := (load("res://assets/maps/base_interior/base_interior_no_sun.png") as Texture2D).get_image()
	no_sun.convert(Image.FORMAT_RGBA8)
	_check(room.terrain.no_sun_map.get_image().get_data() != no_sun.get_data(), "paused scan rows are included in the turn's nighttime map")
	room._apply_view(1, player.facing_dir())
	_check(is_equal_approx(model.scan, kept_scan), "partial scan survives changing camera views")
	room.queue_free()
	await get_tree().process_frame
	room = _room()
	await get_tree().process_frame
	player = room.player
	tool = room.multitool
	cracks = room.cracks
	player.set_tool_out(true)
	player.teleport(cracks.box.world)
	_check(cracks.open_window("crescent") and cracks.panel.puzzle == model, "airlock retains the same puzzle and scan")
	await _wait(2.1)
	_check(model.done and GameState.window_repair.fixed.has("crescent") and GameState.item_count("glass") == 12, "sealing spends six once")
	await _wait(.2)
	_check(GameState.item_count("glass") == 12, "finished panel cannot spend twice")
	cracks.panel.close()
	await get_tree().process_frame
	_check(not cracks.open_window("crescent"), "sealed pane cannot reopen")
	var unsealed := GameState.window_repair.puzzle_for("burst", _catalog["burst"])
	_check(unsealed.fitted() == 0 and unsealed.scan == 0, "second window has independent puzzle state")
	_check(not GameState.window_repair.box_broken and cracks.box.top > 0, "first repair keeps box usable")
	# A floor jump reaches the prompt temporarily; real gravity must close the panel on falling.
	var pane: Dictionary = cracks.panes.filter(func(p: Dictionary) -> bool: return p["id"] == "burst")[0]
	var inward := (pane["world"] as Vector2) - (pane["hole"] as Vector2)
	player.teleport(pane["world"] + inward.normalized() * 16)
	player.auto_jump_every = .05
	var jump_open := false
	for i in 180:
		await get_tree().physics_frame
		if cracks.in_reach("burst"):
			jump_open = cracks.open_window("burst")
			if jump_open:
				break
	player.auto_jump_every = 0
	_check(jump_open and player.is_airborne(), "jump can briefly open the window")
	await _wait(2)
	_check(not cracks.panel.opened and player.height_above_floor() < .1 and player.controls_enabled, "falling closes it; gravity and controls recover")
	# Repair second pane, then prove a third worn landing cannot break the box.
	player.teleport(cracks.place_box_under("burst"))
	player.landed.emit(0)
	await get_tree().process_frame
	_check(cracks.open_window("burst"), "second window opens from the box")
	_fit(cracks.panel, 6)
	await _wait(2.6)
	cracks.panel.close()
	await get_tree().process_frame
	room._apply_view(2, player.facing_dir())
	player.teleport(cracks.place_box_under("gash"))
	player.landed.emit(0)
	await _wait(.8)
	_check(GameState.window_repair.damage() == 3 and not GameState.window_repair.box_broken and player.controls_enabled, "third landing leaves box usable for final puzzle")
	_check(cracks.open_window("gash"), "third window is reachable in its visible camera view")
	await _pad(JOY_BUTTON_A)
	_check(cracks.panel.active == 0, "gamepad A selects the first fragment")
	for i in 3:
		await _pad(JOY_BUTTON_LEFT_SHOULDER)
	cracks.panel.point = GlassRepairUI.PANE.position + cracks.panel.puzzle.target(0)
	await _pad(JOY_BUTTON_X)
	_check(cracks.panel.puzzle.placed[0], "gamepad shoulder rotates and X places glass")
	_fit(cracks.panel, 6)
	await _wait(2.2)
	_check(not GameState.window_repair.box_broken and GameState.item_count("glass") == 6, "third scan retains platform until complete")
	await _wait(.8)
	_check(GameState.window_repair.box_broken and not cracks.panel.opened and GameState.item_count("glass") == 0, "third completed scan closes modal and breaks box")
	await _wait(1.6)
	_check(player.controls_enabled and not player._downed and player.height_above_floor() < .1, "collapse restores working player controls")
	var rations := tool._props.filter(func(p: WorldProp) -> bool: return p.kind == "ration" and not p.gone)
	_check(rations.size() == 4, "final repair spills exactly four rations")
	room._apply_view(0, player.facing_dir())
	var base: Texture2D = load("res://assets/maps/base_interior/base_interior.png")
	_check(room.terrain.map_texture.get_image().get_data() != base.get_image().get_data(), "repaired map persists through camera views")
	GameState.repair_for("power").complete_task("cracks")
	GameState.repair_for("power").complete_task("wiring")
	await _wait(.1)
	_check(room.terrain.view_json.contains("repaired_power") and GameState.window_repair.fixed.size() == 3, "machine art refresh retains sealed windows")
	room.queue_free()
	await get_tree().process_frame
