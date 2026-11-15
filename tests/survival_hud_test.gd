extends Node
## Focused real-input HUD tests. Uses its own ConfigFile so player preferences stay intact.
## Default-size assertions use isolated options regardless of the player's saved GUI size.
## Real-input compact HUD tests: five live meters stay fixed at the top left.
## Covers pointer/keyboard/pad attempts, resizing, UI-only previews and modal visibility.
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


func _ready() -> void:
	GameState.settings = GameSettings.new("res://.godot/hud-default-options.cfg")
	GameState.intro_done = true
	GameState.survival.reset()
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await get_tree().process_frame
	await get_tree().process_frame
	for node in world.get_children():
		if node is SurvivalHUD:
			hud = node
	check(hud != null and hud.meters.size() == 5 and hud.meters[4].kind == "radiation", "fifth meter shows radiation")
	check(hud._panel.position == SurvivalHUD.MARGIN, "stats fixed top left")
	check(SurvivalHUD.toast_position(hud._canvas, Vector2(20, 14), 60).y > SurvivalHUD.PANEL_SIZE.y, "overlapping toast avoids stats")
	check(SurvivalHUD.toast_position(hud._canvas, Vector2(20, 70), 60) == Vector2(20, 70), "unrelated toast stays put")
	for meter in hud.meters:
		for value in [0, 25, 50, 75, 100]:
			meter.preview = value
			check(meter.displayed_value() == value, meter.kind + " number " + str(value))
			check(meter.active_segments() == value * 12 / 100, meter.kind + " segments " + str(value))
		check(meter._ring_pixels.size() > 100, "inactive ring geometry retained")
		meter.preview = -1
	GameState.survival.set_value("radiation", 99.9)
	check(hud.meters[4].displayed_value() == 99 and hud.meters[4].active_segments() == 11, "radiation wheel only fills at lethal exposure")
	GameState.survival.set_value("radiation", 0)
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
	check(hud._panel.position == initial, "pointer cannot drag stats")
	for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		await mouse(button, initial + Vector2(5, 12))
		await motion(Vector2(200, 150))
		await mouse(button, Vector2(200, 150), false)
		check(hud._panel.position == initial, "old grip cannot move stats")
	for screen in [Vector2i(384, 216), Vector2i(768, 432), Vector2i(1024, 768), Vector2i(1920, 1080), Vector2i(900, 300)]:
		get_tree().root.size = screen
		await get_tree().process_frame
		check(hud._panel.position == SurvivalHUD.MARGIN, "resize retains top left " + str(screen))
		check(hud._bounds.encloses(Rect2(hud._panel.position, SurvivalHUD.PANEL_SIZE)), "stats fit viewport")
	check(player.controls_enabled and not world.get_node("Multitool").inventory_suppressed, "stats never capture gameplay input")
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
	check(not hud._panel.visible, "modal hides stats")
	get_tree().paused = false
	print("HUD: %d checks, %d failures" % [checks, failures])
	await Audio.quiet()
	get_tree().quit(1 if failures else 0)
