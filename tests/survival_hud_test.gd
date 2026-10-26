extends Node
## Focused real-input HUD tests. Uses its own ConfigFile so player preferences stay intact.
## Default-size assertions use isolated options regardless of the player's saved GUI size.
## Run: godot --headless --path . res://tests/survival_hud_test.tscn.
var checks := 0
var failures := 0
var hud: SurvivalHUD


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("HUD TEST: " + label)


func mouse(button: int, point: Vector2, pressed := true) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.position = get_tree().root.get_final_transform() * hud._canvas.get_global_transform() * point
	event.pressed = pressed
	Input.parse_input_event(event)
	await get_tree().process_frame


func motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = get_tree().root.get_final_transform() * hud._canvas.get_global_transform() * point
	Input.parse_input_event(event)
	await get_tree().process_frame


func drag(destination: Vector2) -> void:
	var grip := SurvivalHUD.HANDLE.get_center()
	await mouse(MOUSE_BUTTON_LEFT, hud._panel.position + grip)
	check(hud._dragging, "grip starts drag")
	await motion(destination + grip)
	await mouse(MOUSE_BUTTON_LEFT, destination + grip, false)
	check(not hud._dragging, "release ends drag")


func _ready() -> void:
	GameState.settings = GameSettings.new("res://.godot/hud-default-options.cfg")
	# Separate engine processes prove persistence across a full restart, not just objects.
	if OS.get_cmdline_user_args().has("--save-layout-probe"):
		var probe := SurvivalHUDLayout.new("user://hud-restart-test.cfg")
		probe.normalized = Vector2(0.25, 0.75)
		check(probe.save() == OK, "restart save")
		print("HUD PERSISTENCE SAVE: ", failures, " failures")
		get_tree().quit(1 if failures else 0)
		return
	if OS.get_cmdline_user_args().has("--load-layout-probe"):
		var probe := SurvivalHUDLayout.new("user://hud-restart-test.cfg")
		check(probe.normalized == Vector2(0.25, 0.75), "restart load")
		check(probe.reset() == OK, "restart reset")
		check(SurvivalHUDLayout.new("user://hud-restart-test.cfg").normalized == Vector2(1, 0), "restart reset persists")
		print("HUD PERSISTENCE LOAD/RESET: ", failures, " failures")
		get_tree().quit(1 if failures else 0)
		return
	GameState.intro_done = true
	GameState.survival.reset()
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await get_tree().process_frame
	await get_tree().process_frame
	for node in world.get_children():
		if node is SurvivalHUD:
			hud = node
	check(hud != null and hud.meters.size() == 4, "single parent four meters")
	hud.layout = SurvivalHUDLayout.new("user://hud-test.cfg")
	hud.reset_position()
	check(hud.layout.normalized == Vector2(1, 0), "default top right")
	check(SurvivalHUD.toast_position(hud._canvas, Vector2(240, 14), 104).y > SurvivalHUD.PANEL_SIZE.y + 6, "overlapping toast moves below HUD")
	check(SurvivalHUD.toast_position(hud._canvas, Vector2(20, 70), 60) == Vector2(20, 70), "unrelated toast stays put")
	for meter in hud.meters:
		for value in [0, 25, 50, 75, 100]:
			meter.preview = value
			check(meter.displayed_value() == value, meter.kind + " number " + str(value))
			check(meter.active_segments() == value * 12 / 100, meter.kind + " segments " + str(value))
		check(meter._ring_pixels.size() > 100, "inactive ring geometry retained")
		meter.preview = -1
	check(SurvivalMeter.percentage(15, 20) == 75, "normalize different maximum")
	check(SurvivalMeter.percentage(-5, 100) == 0 and SurvivalMeter.percentage(500, 100) == 100, "display clamp")
	check(SurvivalMeter.percentage(3, 0) == 0 and SurvivalMeter.percentage(NAN, 100) == 0, "invalid ranges safe")
	GameState.survival.set_value("oxygen", 25)
	check(hud.meters[1].displayed_value() == 25 and hud.meters[1].active_segments() == 3, "immediate live binding")
	var player: Player = world.get_node("Actors/Player")
	player.breathable = false
	var initial := hud._panel.position
	await mouse(MOUSE_BUTTON_LEFT, initial + hud.meters[0].position + SurvivalMeter.CENTER)
	await motion(Vector2(100, 100))
	await mouse(MOUSE_BUTTON_LEFT, Vector2(100, 100), false)
	check(hud._panel.position == initial and not hud._dragging, "meter cannot drag")
	var far_corner := hud._bounds.end - SurvivalHUD.PANEL_SIZE - SurvivalHUD.MARGIN
	for destination in [Vector2(6, 6), Vector2(6, far_corner.y), far_corner, Vector2(100, 85)]:
		await drag(destination)
		check(hud._panel.position == destination, "drag destination " + str(destination))
		for i in 4:
			check(hud.meters[i].position == SurvivalHUD.METER_ORIGIN + Vector2(i * SurvivalHUD.METER_SPACING, 0), "meter spacing preserved")
	for destination in [Vector2(-1000, 80), Vector2(1000, 80), Vector2(80, -1000), Vector2(80, 1000)]:
		await drag(destination)
		check(hud._bounds.encloses(Rect2(hud._panel.position, SurvivalHUD.PANEL_SIZE)), "screen edge clamping")
	await drag(Vector2(72, 84))
	var saved := SurvivalHUDLayout.new("user://hud-test.cfg")
	check(saved.normalized.is_equal_approx(hud.layout.normalized), "disk round trip")
	for screen in [Vector2i(384, 216), Vector2i(768, 432), Vector2i(1024, 768), Vector2i(1920, 1080), Vector2i(900, 300)]:
		get_tree().root.size = screen
		await get_tree().process_frame
		check(hud._bounds.encloses(Rect2(hud._panel.position, SurvivalHUD.PANEL_SIZE)), "resize stays visible " + str(screen))
	await mouse(MOUSE_BUTTON_RIGHT, hud._panel.position + SurvivalHUD.HANDLE.get_center())
	check(hud.layout.normalized == Vector2(1, 0), "right click reset")
	check(SurvivalHUDLayout.new("user://hud-test.cfg").normalized == Vector2(1, 0), "reset persists")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_HOME
	event.pressed = true
	hud._move_panel(Vector2(80, 80))
	Input.parse_input_event(event)
	await get_tree().process_frame
	check(hud.layout.normalized == Vector2(1, 0), "Home resets")
	event.pressed = false
	Input.parse_input_event(event)
	hud._move_panel(Vector2(80, 80))
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_LEFT_STICK
	pad.pressed = true
	Input.parse_input_event(pad)
	await get_tree().process_frame
	check(hud.layout.normalized == Vector2(1, 0), "gamepad resets")
	pad.pressed = false
	Input.parse_input_event(pad)
	await mouse(MOUSE_BUTTON_LEFT, hud._panel.position + SurvivalHUD.HANDLE.get_center())
	hud._notification(NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	check(not hud._dragging, "focus loss ends drag")
	await mouse(MOUSE_BUTTON_LEFT, hud._panel.position + SurvivalHUD.HANDLE.get_center(), false)
	check(player.controls_enabled and not world.get_node("Multitool").inventory_suppressed, "drag leaves gameplay controls enabled")
	var snapshot: Dictionary = GameState.survival.values.duplicate()
	hud.debug_enabled = true
	var preview_key := InputEventKey.new()
	preview_key.physical_keycode = KEY_F11
	preview_key.pressed = true
	for level in [0, 25, 50, 75, 100]:
		hud._unhandled_input(preview_key)
		for meter in hud.meters:
			check(meter.displayed_value() == level, "F11 preview " + str(level))
	check(GameState.survival.values == snapshot and not GameState.survival.dead, "preview never mutates gameplay")
	preview_key.physical_keycode = KEY_F12
	hud._unhandled_input(preview_key)
	for meter in hud.meters:
		check(meter.preview == -1, "F12 restores live data")
	hud.debug_enabled = false
	get_tree().paused = true
	await get_tree().process_frame
	await mouse(MOUSE_BUTTON_LEFT, hud._panel.position + SurvivalHUD.HANDLE.get_center())
	check(not hud._dragging and not hud._panel.visible, "modal does not capture drag")
	get_tree().paused = false
	var malformed := ConfigFile.new()
	malformed.set_value("layout", "position", "wrong type")
	malformed.save("user://hud-invalid-test.cfg")
	check(SurvivalHUDLayout.new("user://hud-invalid-test.cfg").normalized == Vector2(1, 0), "invalid file defaults")
	check(SurvivalHUDLayout.new("user://hud-missing-test.cfg").normalized == Vector2(1, 0), "missing file defaults")
	print("HUD: %d checks, %d failures" % [checks, failures])
	await Audio.quiet()
	get_tree().quit(1 if failures else 0)
