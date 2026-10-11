extends Node
## Checks for the master control panel (DevPanel): frozen needs hold still (no drain, recovery
## or damage) and run again when thawed; setting an hour keeps the day; and against the real
## overworld and real keys, F1 opens it and stops the astronaut, the arrows and Enter set the
## time and freeze a need, Esc closes it and gives the controls back, and it never opens in a
## cutscene.
## Run: godot --headless --path . res://tests/dev_panel_test.tscn  (failures exit nonzero)

var _checks := 0
var _failures := 0


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
	_model()
	_clock()
	await _scene()
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
