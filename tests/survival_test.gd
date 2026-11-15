extends Node
## Model and scene integration regression: headless, real inventory/input/modal/death.
## Run godot --headless --path . res://tests/survival_test.tscn.
var checks := 0
var failures := 0


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("SURVIVAL TEST: " + label)


func tap(key: int) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame


func _ready() -> void:
	var state := SurvivalState.new()
	state.config["oxygen"]["depletion"] = 5. # accelerated fixture for depletion-boundary checks
	for kind in SurvivalState.KINDS:
		if kind == "radiation":
			continue
		state.set_value(kind, 1000)
		check(state.values[kind] == 100, kind + " upper clamp")
	state.set_value("hunger", -4)
	check(state.values["hunger"] == 0, "lower clamp")
	state.reset()
	state.damage(-2)
	state.damage(NAN)
	check(state.values["health"] == 100, "invalid damage")
	state.damage(25)
	check(state.values["health"] == 75, "damage")
	state.advance(20, false, false)
	check(state.values["oxygen"] == 0 and state.values["health"] == 75, "depletion before damage")
	state.advance(2, false, false)
	check(state.values["health"] == 70, "suffocation interval")
	state.advance(5, true, false)
	check(state.values["oxygen"] == 100 and state.values["health"] == 70, "air recovery")
	state.reset()
	state.advance(10, true, false)
	check(is_equal_approx(state.values["hunger"], 99.2), "hunger rate")
	check(is_equal_approx(state.values["thirst"], 98.8), "thirst rate")
	state.reset()
	state.advance(10, true, true)
	check(is_equal_approx(state.values["hunger"], 98.6) and is_equal_approx(state.values["thirst"], 97.6), "sprint rates")
	state.set_value("hunger", 0)
	state.set_value("thirst", 0)
	state.advance(5, true, false)
	check(state.values["health"] == 95, "starvation plus dehydration")
	var deaths := [0]
	state.died.connect(func(_cause: String) -> void: deaths[0] += 1)
	state.damage(1000)
	state.damage(10)
	state.advance(100, false, true)
	check(state.dead and state.values["health"] == 0 and deaths[0] == 1, "death exactly once")
	check(not state.restore("health", 10), "dead cannot heal")
	state.reset()
	check(not state.dead and state.values["health"] == 100, "reset")
	var changes := [0]
	state.changed.connect(func() -> void: changes[0] += 1)
	state.set_value("oxygen", 10)
	check(changes[0] == 1, "immediate change signal")
	check(not state.restore("oxygen", NAN), "invalid restore rejected")
	state.set_value("oxygen", 0)
	state.advance(1, false, false)
	state.set_value("oxygen", 10)
	state.set_value("oxygen", 0)
	state.advance(1, false, false)
	check(state.values["health"] == 100, "repeated depletion clears old damage time")
	state.reset()
	var other := SurvivalState.new()
	other.config["oxygen"]["depletion"] = 5.
	state.advance(25, false, true)
	for i in 100:
		other.advance(0.25, false, true)
	for kind in SurvivalState.KINDS:
		check(is_equal_approx(state.values[kind], other.values[kind]), kind + " frame partition")
	var solar := SurvivalState.SolarActivity
	check(state.solar_activity(9.99) == solar.QUIET, "quiet before flare")
	check(state.solar_activity(10.0) == solar.WARNING and state.solar_activity(10.8) == solar.WARNING, "DONKI flare warns before particle arrival")
	check(state.solar_activity(10.84) == solar.STORM and state.solar_activity(12.84) == solar.QUIET, "recorded onset and authored storm end")
	check(state.solar_activity(34.0) == solar.WARNING, "storm replays each day")
	check(state.values["radiation"] == 0, "starts without exposure")
	state.advance_radiation(10, false, solar.WARNING)
	check(state.values["radiation"] == 0, "warning does not expose")
	state.advance_radiation(20, false, solar.STORM)
	check(state.values["radiation"] == 50, "active storm raises exposure outdoors")
	state.advance_radiation(10, false, solar.QUIET)
	check(state.values["radiation"] == 50, "outdoors cannot recover even after storm")
	state.advance_radiation(10, true, solar.STORM)
	check(state.values["radiation"] == 10, "shelter recovers even during storm")
	state.advance_radiation(10, true, solar.QUIET)
	check(state.values["radiation"] == 0, "recovery clamps at zero")
	state.advance_radiation(40, false, solar.STORM)
	check(state.dead and state.cause == "RADIATION POISONING" and deaths[0] == 2, "full exposure kills once")
	state.reset()
	check(not state.dead and state.values["radiation"] == 0, "rescue clears exposure")
	GameState.survival.reset()
	GameState.reset_inventory()
	GameState.stock_supplies()
	check(not GameState.consume_slot(1), "full hunger retains ration")
	GameState.survival.set_value("hunger", 90)
	check(GameState.consume_slot(1) and GameState.survival.values["hunger"] == 100 and GameState.inventory[1]["count"] == 5, "consume and clamp")
	check(not GameState.consume_slot(-1) and not GameState.consume_slot(0), "non-consumable rejected")
	GameState.survival.set_value("thirst", 0)
	check(GameState.consume_slot(2) and GameState.survival.values["thirst"] == 40, "water")
	GameState.inventory[2]["count"] = 1
	GameState.survival.set_value("thirst", 0)
	check(GameState.consume_slot(2) and GameState.inventory[2].is_empty(), "last consumable clears slot")
	GameState.intro_done = true
	GameState.survival.reset()
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await get_tree().process_frame
	await get_tree().process_frame
	get_tree().current_scene = world
	var hud: SurvivalHUD
	var bag: InventoryUI
	for node in world.get_children():
		if node is SurvivalHUD: hud = node
		if node is InventoryUI: bag = node
	check(hud != null and bag != null, "scene UI")
	check(not hud.debug_enabled, "development controls opt in")
	GameState.clock = 11.0
	await get_tree().create_timer(0.1).timeout
	check(GameState.survival.values["radiation"] > 0, "overworld exposes player during storm")
	await tap(KEY_F6)
	check(GameState.survival.values["health"] == 100, "debug damage inactive normally")
	for size in [Vector2i(384, 216), Vector2i(768, 432), Vector2i(1024, 768), Vector2i(1920, 1080)]:
		get_tree().root.size = size
		await get_tree().process_frame
		check(hud._canvas.scale == bag._canvas.scale and hud._panel.position == SurvivalHUD.MARGIN, "compact HUD remains anchored at " + str(size))
	GameState.select_slot(1)
	GameState.survival.set_value("hunger", 30)
	await tap(KEY_C)
	check(GameState.survival.values["hunger"] > 64, "hotbar C input")
	bag.toggle()
	var hunger: float = GameState.survival.values["hunger"]
	var exposure: float = GameState.survival.values["radiation"]
	await get_tree().create_timer(0.1).timeout
	check(GameState.survival.values["hunger"] == hunger, "modal pause")
	check(GameState.survival.values["radiation"] == exposure, "modal pauses radiation")
	bag._focus = 1
	await tap(KEY_C)
	check(GameState.survival.values["hunger"] > hunger, "backpack consumption")
	bag.toggle()
	var astronaut_out: Player = world.get_node("Actors/Player")
	astronaut_out.controls_enabled = false
	hunger = GameState.survival.values["hunger"]
	await get_tree().create_timer(0.1).timeout
	check(GameState.survival.values["hunger"] == hunger, "cutscene pauses survival")
	astronaut_out.controls_enabled = true
	bag.toggle()
	world.get_node("Actors/Player").take_damage(1000)
	await get_tree().process_frame
	await get_tree().process_frame
	check(get_tree().paused and GameState.survival.dead, "death pauses world")
	check(hud.layer == 20, "death above modal UI")
	await tap(KEY_ENTER)
	await get_tree().process_frame
	check(not get_tree().paused and not GameState.survival.dead, "rescue input")
	GameState.survival.set_value("radiation", 50)
	get_tree().change_scene_to_file("res://scenes/interior.tscn")
	await get_tree().process_frame
	await get_tree().process_frame
	var inside: Node = get_tree().current_scene
	var astronaut: Player = inside.get_node("Actors/Player")
	astronaut.teleport(Vector2(-236, 492))
	check(not astronaut.can_breathe(), "damaged oxygen room air")
	await get_tree().create_timer(0.1).timeout
	check(GameState.survival.values["radiation"] > 0 and GameState.survival.values["radiation"] < 50,
			"interior recovers retained exposure even without breathable air")
	GameState.repair_for("oxygen").complete_task("cracks")             # wiring follows cracks
	GameState.repair_for("oxygen").complete_task("wiring")
	check(not astronaut.can_breathe(), "repaired O2 still leaks through broken storage glass")
	for pane in ["burst", "crescent", "gash"]: GameState.window_repair.fix(pane)
	check(astronaut.can_breathe(), "sealed glass retains reserve O2")
	astronaut.head_submerged = true
	check(not astronaut.can_breathe(), "submerged head overrides air")
	astronaut.head_submerged = false
	astronaut.teleport(astronaut.terrain.spawn)
	check(astronaut.can_breathe(), "safe spawn")
	check(GameState.survival.values["health"] == 100, "scene preserves health")
	print("SURVIVAL: %d checks, %d failures" % [checks, failures])
	await Audio.quiet()
	get_tree().quit(1 if failures else 0)
