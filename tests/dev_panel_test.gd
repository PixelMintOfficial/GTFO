extends Node
## Checks for the master control panel (DevPanel): frozen needs hold still (no drain, recovery
## or damage) and run again when thawed; setting an hour keeps the day; and against the real
## overworld and real keys, F1 opens it and stops the astronaut, the arrows and Enter set the
## time and freeze a need, Esc closes it and gives the controls back, and it never opens in a
## cutscene.
## Task toggles use real keys, clicks and gamepad buttons, bypass inventory/reach, refresh
## broken/restored room/window/solar/nursery art, retain state through scenes and follow manual edits.
## Nursery toggles cover the live UNIT scanner/patrol state and screen-controlled lighting.
## Run: godot --headless --path . res://tests/dev_panel_test.tscn  (failures exit nonzero)
## Native captures: -- --gallery=shots/admin-tasks (run without --headless).

var _checks := 0
var _failures := 0
var _gallery := ""


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("DEV PANEL TEST: " + label)


func _tap(code: int) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
		await get_tree().process_frame


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--gallery="):
			_gallery = arg.trim_prefix("--gallery=")
	if not _gallery.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_gallery))
	_model()
	_clock()
	await _scene()
	await _interior()
	await _nursery()
	print("DEV PANEL TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


func _model() -> void:
	var s := SurvivalState.new()
	s.frozen = {"hunger": true, "oxygen": true}
	s.set_value("oxygen", 40.0)
	s.advance(300.0, false, false)                       # water drains, but stays well above empty
	_check(s.values["hunger"] == 100.0 and s.values["oxygen"] == 40.0, "frozen food and oxygen hold still")
	_check(s.values["thirst"] < 100.0, "water still runs")
	s.set_value("oxygen", 0.0)
	s.advance(60.0, false, false)
	_check(s.values["health"] == 100.0, "an empty frozen oxygen tank does no harm")
	s.advance(10.0, true, false)
	_check(s.values["oxygen"] == 0.0, "frozen oxygen does not refill either")
	s.frozen.erase("oxygen")
	s.advance(1.0, true, false)
	_check(s.values["oxygen"] > 0.0, "thawed, it runs again")


func _clock() -> void:
	var keep := GameState.clock
	GameState.clock = 8.0                                 # day 1, 08:00
	DevPanel.set_hour(22.0)
	_check(is_equal_approx(GameState.clock, 22.0), "evening of the same day")
	DevPanel.set_hour(3.0)
	_check(is_equal_approx(GameState.clock, 27.0), "before dawn is still the same day's night")
	DevPanel.set_hour(5.5)
	_check(is_equal_approx(GameState.clock, 5.5), "dawn of the same day")
	GameState.clock = keep


func _scene() -> void:
	GameState.reset_inventory()
	GameState.machine_repairs.clear()
	GameState.solar_field = SolarFieldState.new()
	GameState.survival.reset()
	GameState.survival.frozen.clear()
	GameState.intro_done = true
	GameState.arrive = ""
	GameState.clock = 8.0
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await get_tree().process_frame
	await get_tree().process_frame
	var player: Player = world.get_node("Actors/Player")
	var panel: DevPanel
	for n in world.get_children():
		if n is DevPanel:
			panel = n
	_check(panel != null and not panel.opened, "the overworld has the panel, closed")
	await _tap(KEY_F1)
	_check(panel.opened and not player.controls_enabled, "F1 opens it and the astronaut stands still")
	await _tap(KEY_RIGHT)
	await get_tree().process_frame
	_check(absf(DayNight.hour - 8.5) < 0.05, "right steps the time half an hour (got %.2f)" % DayNight.hour)
	await _tap(KEY_DOWN)
	await _tap(KEY_RIGHT)
	await _tap(KEY_RIGHT)
	await _tap(KEY_RIGHT)
	await _tap(KEY_ENTER)
	await get_tree().process_frame
	_check(absf(DayNight.hour - 17.0) < 0.05 and DayNight.phase == "EVENING", "a preset sets the evening (got %.2f)" % DayNight.hour)
	await _tap(KEY_DOWN)
	await _tap(KEY_ENTER)
	_check(GameState.survival.frozen.has("hunger"), "Enter freezes food")
	await _tap(KEY_ENTER)
	_check(not GameState.survival.frozen.has("hunger"), "and Enter again lets it run")
	await _tap(KEY_DOWN)
	await _tap(KEY_DOWN)
	await _tap(KEY_ENTER)
	_check(GameState.survival.frozen.has("oxygen"), "oxygen frozen")
	await _tap(KEY_DOWN)
	_check(panel._row == DevPanel.TASK_ROW, "task rows follow needs")
	await _shot("outside-pending")
	var inventory := GameState.inventory.duplicate(true)
	for i in DevPanel.TASKS.size():
		var task: String = DevPanel.TASKS[i][1]
		_check(not DevPanel.task_complete(task), task + " starts pending")
		if i == 1:
			await _click_task(panel, i)
		elif i == 3:
			await _pad(JOY_BUTTON_DPAD_DOWN)
			_check(panel._row == DevPanel.TASK_ROW + i, "gamepad selects solar row (got %d)" % panel._row)
			await _pad(JOY_BUTTON_A)
		else:
			if i > 0:
				await _tap(KEY_DOWN)
			await _tap(KEY_ENTER)
		_check(DevPanel.task_complete(task), task + " completes remotely")
		_check(GameState.inventory == inventory, task + " costs no materials")
	_check(GameState.base_powered() and BasePower.active, "all prerequisites immediately light the base")
	_check((world.get_node("DomeFX") as DomeFX)._glass.size() == 2, "both visible storage holes mend without a camera turn")
	_check(not GameState.suit_light, "task completion never enables the suit lamp")
	GameState.clock = 22.0
	await _frames()
	await _shot("outside-done-night")
	# A real solar control invalidates DONE; toggling solves the actual optics again.
	GameState.solar_field.toggle_feed(0)
	_check(not DevPanel.task_complete("solar"), "solar row follows a manually closed feed")
	await _click_task(panel, 3)
	_check(GameState.solar_field.supplies_power(), "solar toggle repairs a manually changed route")
	for i in DevPanel.TASKS.size() - 4:
		await _tap(KEY_DOWN)
	await _tap(KEY_DOWN)
	_check(panel._row == 0, "down wraps from final task to time")
	await _tap(KEY_UP)
	_check(panel._row == DevPanel.TASK_ROW + DevPanel.TASKS.size() - 1, "up wraps to final task")
	await _click_task(panel, 2)
	_check((world.get_node("DomeFX") as DomeFX)._glass.is_empty(), "outside reset removes glass immediately")
	await _click_task(panel, 2)
	_check((world.get_node("DomeFX") as DomeFX)._glass.size() == 2, "outside toggle restores both visible storage holes again")
	await _pad(JOY_BUTTON_B)
	_check(not panel.opened and player.controls_enabled, "gamepad B closes and restores controls")
	await _tap(KEY_F1)
	await _tap(KEY_ESCAPE)
	_check(not panel.opened and player.controls_enabled, "Esc closes it and gives the controls back")
	_check(GameState.survival.frozen.has("oxygen"), "what it froze stays frozen")
	player.puppet = true
	await _tap(KEY_F1)
	_check(not panel.opened, "it never opens in a cutscene")
	player.puppet = false
	GameState.survival.frozen.clear()
	world.queue_free()
	await get_tree().process_frame


func _pad(button: int) -> void:
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
		await get_tree().process_frame


func _click_task(panel: DevPanel, index: int) -> void:
	await get_tree().process_frame
	for hit in panel._hits:
		if hit[1] != DevPanel.TASK_ROW + index:
			continue
		var rect: Rect2 = hit[0]
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = panel._canvas.get_global_transform_with_canvas() * rect.get_center()
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = pressed
			get_viewport().push_input(event, true)        # local viewport pixels, including stretched native windows
			await get_tree().process_frame
			await get_tree().process_frame
		return
	_check(false, "clickable task row exists")


func _frames(count := 6) -> void:
	for i in count:
		await get_tree().process_frame


func _shot(label: String) -> void:
	if _gallery.is_empty():
		return
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(_gallery.path_join(label + ".png")) == OK, "capture " + label)


func _interior() -> void:
	GameState.clock = 12.0
	GameState.story.skip_intro()
	var base := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(base)
	await _frames()
	base.day_night.speed = 0.0
	var panel: DevPanel
	var objectives: ObjectiveHUD
	for n in base.get_children():
		if n is DevPanel:
			panel = n
		if n is ObjectiveHUD:
			objectives = n
	for task in DevPanel.TASKS:
		_check(DevPanel.task_complete(task[1]), task[1] + " persists on entering base")
	_check(base._repair_mask == 3 and base.fx._shafts.is_empty(), "repaired room and sealed windows persist")
	var inventory := GameState.inventory.duplicate(true)
	var box_state := [GameState.window_repair.box_broken, GameState.window_repair.box_cracks.duplicate()]
	await _tap(KEY_F1)
	await _shot("inside-done-day")
	# Reset every row by clicking its real hitbox; reset in place preserves subscribers.
	for i in DevPanel.TASKS.size():
		await _click_task(panel, i)
		_check(not DevPanel.task_complete(DevPanel.TASKS[i][1]), DevPanel.TASKS[i][1] + " resets")
	_check(base._repair_mask == 0, "machine reset restores broken room art live")
	_check(not BasePower.active, "reset removes full electrical light")
	_check(not base.fx._shafts.is_empty() and not base.cracks._patches.is_empty(), "glass reset restores shafts and scan sprites")
	_check(GameState.window_repair.dome_mended == "" and GameState.window_repair.puzzles.is_empty(), "glass reset clears dome and puzzles")
	_check(GameState.solar_field.orientations == GameState.solar_field._initial_orientations and GameState.solar_field.connected_count() == 0,
			"solar reset restores original angles and closes feeds")
	_check(GameState.window_repair.box_broken == box_state[0] and GameState.window_repair.box_cracks == box_state[1], "task reset preserves cargo-box history")
	_check(objectives._all_done_t == -1.0, "reset brings objectives back after completion")
	await _shot("inside-reset-day")
	for i in DevPanel.TASKS.size():
		await _click_task(panel, i)
	_check(base._repair_mask == 3 and base.fx._shafts.is_empty() and base.cracks._patches.is_empty(), "toggles refresh room art, shafts and scan sprites live")
	_check(BasePower.active and base.fx._reserve.visible, "remote solar completion powers the interior")
	_check(GameState.inventory == inventory, "roundtrip toggles never spend or grant items")
	_check(not base.repairs.modal_open() and not base.cracks.panel.opened, "task toggles never open repair puzzles")
	_check(not base.player.controls_enabled and panel.opened, "room refresh leaves F1 menu in control")
	GameState.clock = 22.0
	await _frames()
	await _shot("inside-done-night")
	# Broken glass under full power must still use the sunlight-free nighttime reference.
	await _click_task(panel, 2)
	_check(BasePower.active and base.terrain.no_sun_map != null, "broken windows retain powered-night fix")
	await _shot("inside-glass-reset-night")
	await _click_task(panel, 2)
	await _tap(KEY_ESCAPE)
	_check(base.player.controls_enabled, "closing after room refresh returns player controls")
	for heading in [1, 2]:
		GameState.heading = heading
		base._apply_view(heading, base.player.facing_dir())
		await _frames()
		_check(base.fx._shafts.is_empty() and BasePower.active, "completed tasks survive view %d" % heading)
		await _tap(KEY_F1)
		await _shot("inside-view-%d-night" % heading)
		await _tap(KEY_ESCAPE)
	base.queue_free()
	await _frames()
	GameState.heading = 0
	# Returning outdoors uses the same completed solar field and dome glass.
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await _frames()
	_check(BasePower.active and (world.get_node("DomeFX") as DomeFX)._glass.size() == 2, "completed tasks survive leaving the base")
	world.queue_free()
	await _frames()


func _nursery() -> void:
	GameState.heading = 0
	GameState.clock = 22.
	var room := load("res://scenes/nursery.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await _frames()
	room.day_night.speed = 0.
	var panel: DevPanel
	for node in room.get_children():
		if node is DevPanel: panel = node
	_check(room._repair_mask == 7 and room.bot.state == Bot.State.PATROL, "remote nursery repairs persist on entry")
	_check(DayNight.fixture_power == 1., "completed screen powers the nursery")
	var inventory := GameState.inventory.duplicate(true)
	var base_story := [GameState.story.bot_awake, GameState.story.named, GameState.story.objectives_given]
	await _tap(KEY_F1)
	await _shot("nursery-all-done-night")
	await _click_task(panel, 5)
	_check(not GameState.nursery_powered() and DayNight.fixture_power == 0. and room._repair_mask == 6, "screen reset switches lights and screen art off live")
	await _shot("nursery-screen-reset-night")
	await _click_task(panel, 5)
	_check(GameState.nursery_powered() and DayNight.fixture_power == 1. and room._repair_mask == 7, "screen completion restores power without closing master control")
	for index in [6, 7]:
		await _click_task(panel, index)
		var id: String = DevPanel.TASKS[index][1].trim_prefix("nursery_")
		_check(not GameState.cultivation.repaired(id) and not GameState.cultivation.repair_progress.has(id), id + " reset clears its scanner progress")
		_check(DayNight.fixture_power == 1., id + " reset leaves console power intact")
		await _click_task(panel, index)
		_check(GameState.cultivation.repaired(id) and room._repair_mask == 7, id + " completion refreshes nursery art")
	await _click_task(panel, 4)
	_check(room.bot.state == Bot.State.DORMANT and room.bot._anim == "dormant", "UNIT reset returns live body to dormant animation")
	_check(not room.bot._fix.is_empty() and room.bot._fix["progress"] == 0., "UNIT reset reinstates its repair scanner")
	_check(GameState.cultivation.repairs == 7 and DayNight.fixture_power == 1., "UNIT reset does not reset other nursery systems")
	await _shot("nursery-unit-reset-night")
	await _click_task(panel, 4)
	_check(room.bot.state == Bot.State.PATROL and room.bot._fix.is_empty() and not room.dialogue.opened, "UNIT completion resumes patrol without interrupting F1")
	_check(base_story == [GameState.story.bot_awake, GameState.story.named, GameState.story.objectives_given], "nursery controls preserve main story progress")
	_check(GameState.inventory == inventory, "nursery controls never spend or grant items")
	_check(panel.opened and not room.player.controls_enabled, "nursery art refresh retains master-control ownership")
	await _shot("nursery-controls-restored-night")
	await _tap(KEY_ESCAPE)
	room.queue_free()
	await _frames()
