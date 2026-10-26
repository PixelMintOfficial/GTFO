extends Node
## Real Escape/mouse/keyboard/pad options tests in all three scenes. Verify frozen simulation,
## exclusive modal input, master-bus gain/mute, all four scaled UI surfaces and their hitboxes,
## fixed HUD placement, task-list scaling, airlock continuity and preference persistence. Test files
## live in .godot; no player preferences are written. --gallery=shots/options captures native UI.

const PREFS := "res://.godot/options-test.cfg"
var checks := 0
var failures := 0
var gallery := ""
var prefs_path := PREFS


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("OPTIONS TEST: " + label)


func frames(count := 4) -> void:
	for i in count:
		await get_tree().process_frame


func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	await frames(2)


func tap(code: int) -> void:
	await key(code, true)
	await key(code, false)


func pad(button: int) -> void:
	for pressed in [true, false]:
		var event := InputEventJoypadButton.new()
		event.button_index = button
		event.pressed = pressed
		Input.parse_input_event(event)
		await frames(2)


func pointer(canvas: CanvasItem, point: Vector2, pressed := true) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = canvas.get_global_transform_with_canvas() * point
	event.pressed = pressed
	get_viewport().push_input(event, true)
	await frames(2)


func click(canvas: CanvasItem, point: Vector2) -> void:
	await pointer(canvas, point)
	await pointer(canvas, point, false)


func shot(label: String) -> void:
	if gallery.is_empty():
		return
	await RenderingServer.frame_post_draw
	check(get_viewport().get_texture().get_image().save_png(gallery.path_join(label + ".png")) == OK, "capture " + label)


func find(scene: Node, script: Script) -> Node:
	for child in scene.get_children():
		if child.get_script() == script:
			return child
	return null


func scene(path: String) -> Node2D:
	var node := load(path).instantiate() as Node2D
	get_tree().root.add_child.call_deferred(node)
	await frames(8)
	return node


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--gallery="):
			gallery = arg.trim_prefix("--gallery=")
	if not gallery.is_empty():
		prefs_path = "res://.godot/options-gallery-test.cfg"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(gallery))
	var args := OS.get_cmdline_user_args()
	if args.has("--save-options-probe"):
		var settings := GameSettings.new("res://.godot/options-restart.cfg")
		settings.set_volume(.35)
		settings.set_gui_size("medium")
		check(settings.save() == OK, "save restart preferences")
	elif args.has("--load-options-probe"):
		var settings := GameSettings.new("res://.godot/options-restart.cfg")
		check(settings.gui_size == "medium" and is_equal_approx(settings.volume, .35), "restart loads both preferences")
	else:
		await run()
	print("OPTIONS TESTS: %d checks, %d failures" % [checks, failures])
	await Audio.quit(1 if failures else 0)


func run() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prefs_path))
	GameState.settings = GameSettings.new(prefs_path)
	GameState.settings.apply_volume()
	check(GameState.settings.gui_size == "small" and GameState.settings.volume == 1.0, "defaults preserve compact HUD and full master volume")
	GameState.settings.set_gui_size("large")
	GameState.intro_done = true
	GameState.clock = 12.0
	GameState.reset_inventory()
	GameState.survival.reset()
	var world := await scene("res://scenes/overworld.tscn")
	var menu := find(world, PauseMenu) as PauseMenu
	var bag := find(world, InventoryUI) as InventoryUI
	var hud := find(world, SurvivalHUD) as SurvivalHUD
	var dev := find(world, DevPanel) as DevPanel
	check(menu != null and not menu.opened, "overworld has closed options")
	var large := bag._canvas.scale.x
	var clock_large: Vector2 = world.day_night.clock_panel._panel.scale
	var anchored := hud._panel.position
	var objectives := find(world, ObjectiveHUD) as ObjectiveHUD
	await tap(KEY_ESCAPE)
	check(menu.opened and get_tree().paused, "Escape pauses and opens options")
	var at: Vector2 = world.player.world_pos
	var clock := GameState.clock
	var vitals := GameState.survival.values.duplicate()
	var slot := GameState.selected_slot
	await key(KEY_W, true)
	await key(KEY_F, true)
	await tap(KEY_E)
	await tap(KEY_M)
	await tap(KEY_L)
	await tap(KEY_H)
	await tap(KEY_3)
	await tap(KEY_F1)
	await get_tree().create_timer(.25, true).timeout
	check(GameState.clock == clock and world.player.world_pos == at and GameState.survival.values == vitals, "pause freezes movement, clock and survival")
	check(not bag.opened and not world.map_screen.visible and not dev.opened and not GameState.suit_light and GameState.selected_slot == slot,
			"options consume inventory/map/lamp/hotbar/dev input")
	await key(KEY_W, false)
	# Master volume includes ambience, effects and interface, preserving individual bus levels.
	var buses: Array = []
	for name in ["amb", "sfx", "ui"]:
		buses.append(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(name)))
	await pointer(menu._canvas, PauseMenu.SLIDER.position + Vector2(42, 7))
	var drag := InputEventMouseMotion.new()
	drag.position = menu._canvas.get_global_transform_with_canvas() * (PauseMenu.SLIDER.end + Vector2(40, 0))
	get_viewport().push_input(drag, true)
	await frames()
	check(GameState.settings.volume == 1.0, "dragging beyond slider clamps at full volume")
	await pointer(menu._canvas, PauseMenu.SLIDER.end, false)
	await click(menu._canvas, PauseMenu.SLIDER.position + Vector2(0, 7))
	check(AudioServer.is_bus_mute(0) and GameState.settings.volume == 0.0, "slider zero mutes Master")
	await click(menu._canvas, PauseMenu.SLIDER.position + Vector2(84, 7))
	check(not AudioServer.is_bus_mute(0) and absf(db_to_linear(AudioServer.get_bus_volume_db(0)) - .5) < .001, "slider midpoint controls real Master gain")
	await tap(KEY_RIGHT)
	check(is_equal_approx(GameState.settings.volume, .55), "keyboard adjusts volume")
	var after: Array = []
	for name in ["amb", "sfx", "ui"]:
		after.append(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(name)))
	check(after == buses, "authored mix stays intact")
	await shot("pause-options")
	var previous := 0.0
	for index in 3:
		await click(menu._canvas, PauseMenu._button_rect(index).get_center())
		var size_name: String = GameSettings.SIZES[index]
		check(GameState.settings.gui_size == size_name, size_name + " button selects size")
		check(bag._canvas.scale.x > previous, size_name + " has distinct ascending size")
		previous = bag._canvas.scale.x
		check(bag._canvas.scale.is_equal_approx(hud._canvas.scale), size_name + " scales backpack/hotbar and stats together")
		var ratio := bag._canvas.scale.x / large
		check(world.day_night.clock_panel._panel.scale.is_equal_approx(clock_large * ratio), size_name + " scales the clock")
		check(hud._panel.position == anchored, size_name + " preserves fixed top-left stats")
		check(objectives._panel.scale.is_equal_approx(hud._canvas.scale), size_name + " scales the task checklist with the stats")
		check(hud._bounds.encloses(Rect2(hud._panel.position, SurvivalHUD.PANEL_SIZE)), size_name + " keeps stats on screen")
		await tap(KEY_ESCAPE)
		check(not get_tree().paused and world.multitool.options_suppressed, "resume waits for held F to release")
		await key(KEY_F, false)
		await frames()
		check(not world.multitool.options_suppressed, "release clears options suppression")
		await get_tree().create_timer(.25).timeout
		await shot("hud-" + size_name)
		# Actual hotbar click and E backpack, with scaled hitboxes.
		await click(bag._canvas, bag._slot_rect(2).get_center())
		check(GameState.selected_slot == 2, size_name + " hotbar click hits resized slot")
		await tap(KEY_E)
		await get_tree().create_timer(.2, true).timeout
		check(bag.opened and get_tree().paused, size_name + " E opens scaled backpack")
		await click(bag._canvas, bag._slot_rect(1).get_center())
		check(bag._focus == 1, size_name + " backpack hitbox matches art")
		await shot("backpack-" + size_name)
		await tap(KEY_ESCAPE)
		check(not bag.opened and not menu.opened and not get_tree().paused, "Escape closes backpack before options")
		await tap(KEY_ESCAPE)
		await key(KEY_F, true)
	check(is_equal_approx(bag._canvas.scale.x, large), "Large restores original size")
	# Pad navigation selects Small; B closes without toggling suit lamp.
	await pad(JOY_BUTTON_DPAD_DOWN)
	await pad(JOY_BUTTON_A)
	check(GameState.settings.gui_size == "small", "pad selects Small")
	await pad(JOY_BUTTON_B)
	await key(KEY_F, false)
	check(not menu.opened and not GameState.suit_light, "pad B resumes without suit-light leakage")
	var saved := GameSettings.new(prefs_path)
	check(saved.gui_size == "small" and is_equal_approx(saved.volume, .55), "resume persists both settings")
	# Existing map and F1 cancellations retain ownership of Escape.
	await tap(KEY_M)
	await tap(KEY_ESCAPE)
	check(not world.map_screen.visible and not menu.opened and not get_tree().paused, "Escape closes map first")
	await tap(KEY_F1)
	await tap(KEY_ESCAPE)
	check(not dev.opened and not menu.opened, "Escape closes F1 first")
	world.player.puppet = true
	await tap(KEY_ESCAPE)
	check(not menu.opened, "cutscene owns input")
	world.player.puppet = false
	world.queue_free()
	await frames()
	for path in ["res://scenes/interior.tscn", "res://scenes/nursery.tscn"]:
		var inside := await scene(path)
		menu = find(inside, PauseMenu)
		bag = find(inside, InventoryUI)
		check(GameState.settings.gui_size == "small" and bag._canvas.scale.x < large, "GUI preference carries into " + path)
		var tasks := find(inside, ObjectiveHUD) as ObjectiveHUD
		check(tasks._panel.scale.is_equal_approx(bag._canvas.scale), "task checklist shares GUI scale in " + path)
		await tap(KEY_ESCAPE)
		check(menu.opened and get_tree().paused, "Escape pauses " + path)
		await tap(KEY_ESCAPE)
		check(not get_tree().paused, "Escape resumes " + path)
		if path.ends_with("interior.tscn"):
			for i in 3:
				GameState.store_item("scrap")
			check(inside.repairs.open_machine("power"), "open machine repair")
			await tap(KEY_ESCAPE)
			check(not inside.repairs.modal_open() and not menu.opened and not get_tree().paused, "repair owns Escape before options")
			inside.dialogue.open("BOT", ["HELLO"], true, Callable())
			await tap(KEY_ESCAPE)
			check(not inside.dialogue.opened and not menu.opened and not get_tree().paused, "dialogue owns Escape before options")
		if path.ends_with("nursery.tscn"):
			inside.player.teleport(inside.cultivation.interaction_point("console"))
			await frames()
			check(inside.cultivation._can_interact(), "nursery repair area accepts ordinary interaction")
			await tap(KEY_ESCAPE)
			await key(KEY_F, true)
			await tap(KEY_ESCAPE)
			check(inside.multitool.options_suppressed and not inside.cultivation._can_interact(), "held F after options cannot trigger nursery work")
			await key(KEY_F, false)
			await frames()
			check(inside.cultivation._can_interact(), "F release restores nursery interactions")
			await tap(KEY_ESCAPE)
			await click(menu._canvas, PauseMenu.SLIDER.position + Vector2(42, 7))
		inside.queue_free()
		await frames()
	check(not get_tree().paused and is_equal_approx(GameSettings.new(prefs_path).volume, .25), "scene exit saves options and releases its pause")
	GameState.settings.set_volume(1.0)
	GameState.settings.set_gui_size("large")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prefs_path))
