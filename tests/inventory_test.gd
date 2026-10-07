extends Node
## Integration checks against real scenes, input events, and the existing multitool jobs.
## Run: godot --headless --path . res://tests/inventory_test.tscn
## Failures exit nonzero; no external test framework or generated assets required.

var _checks := 0
var _failures := 0


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("INVENTORY TEST: " + label)
		get_tree().quit(1)


func _key(code: int, pressed := true, echo := false) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	event.echo = echo
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame


func _tap(code: int) -> void:
	await _key(code)
	await _key(code, false)


func _mouse(ui: InventoryUI, index: int) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = ui._canvas.position + ui._slot_rect(index).get_center() * ui._canvas.scale
	event.pressed = true
	Input.warp_mouse(event.position)
	Input.parse_input_event(event)
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame


func _pad(button: int) -> void:
	var event := InputEventJoypadButton.new()
	event.button_index = button
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame


func _ui(scene: Node) -> InventoryUI:
	for child in scene.get_children():
		if child is InventoryUI:
			return child
	return null


func _ready() -> void:
	GameState.intro_done = true
	GameState.reset_inventory()
	_check(GameState.inventory.size() == 24 and GameState.inventory[0]["kind"] == "multitool", "initial bag")
	_check(not GameState.store_item("invalid") and not GameState.store_item("multitool"), "unknown/duplicate tool rejected")
	for i in 100:
		GameState.store_item("ore_chunk")
	_check(GameState.inventory[1]["count"] == 99 and GameState.inventory[2]["count"] == 1, "stack limit and overflow")
	GameState.swap_slots(1, 6)
	_check(GameState.inventory[6]["count"] == 99 and GameState.inventory[1].is_empty(), "backpack/hotbar swap")
	GameState.select_slot(5)
	GameState.select_slot(-1)
	GameState.select_slot(24)
	_check(GameState.selected_slot == 5, "invalid selection bounded")
	GameState.swap_slots(-1, 99)
	GameState.reset_inventory()
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await get_tree().process_frame
	await get_tree().process_frame
	var player: Player = world.get_node("Actors/Player")
	var tool: Multitool = world.get_node("Multitool")
	var ui := _ui(world)
	_check(ui != null and not ui.opened, "overworld hotbar attached")
	var start := player.world_pos
	for i in 12:
		await _tap(KEY_E)
		_check(ui.opened and get_tree().paused, "E opens and pauses")
		await _key(KEY_E, true, true)
		_check(ui.opened, "key repeat ignored")
		await _key(KEY_E, false)
		await _tap(KEY_M)
		await _tap(KEY_I)
		await _tap(KEY_T)
		await _tap(KEY_F)
		await _tap(KEY_SPACE)
		player.forced_input = Vector2.RIGHT
		await get_tree().create_timer(0.04).timeout
		_check(player.world_pos == start and player.tool_state == Player.Tool.HOLSTERED, "modal blocks movement/tool/jump")
		_check(not world.get_node("MapScreen").visible, "modal blocks map")
		player.forced_input = Vector2.ZERO
		await _tap(KEY_E)
		_check(not ui.opened and not get_tree().paused, "E closes and resumes")
	await _tap(KEY_M)
	_check(world.get_node("MapScreen").visible, "map still opens")
	await _tap(KEY_E)
	_check(not ui.opened and get_tree().paused, "inventory cannot stack over map")
	await _tap(KEY_M)
	await _pad(JOY_BUTTON_START)
	_check(ui.opened, "gamepad opens backpack")
	await _pad(JOY_BUTTON_A)
	_check(ui._picked == 0, "gamepad picks slot")
	await _pad(JOY_BUTTON_B)
	_check(ui.opened and ui._picked == -1, "gamepad cancels swap")
	await _pad(JOY_BUTTON_B)
	_check(not ui.opened and not get_tree().paused, "gamepad closes backpack")
	await _pad(JOY_BUTTON_LEFT_SHOULDER)
	_check(GameState.selected_slot == 1, "gamepad cycles hotbar")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	Input.parse_input_event(wheel)
	await get_tree().process_frame
	_check(GameState.selected_slot == 0, "wheel selects previous slot")
	await get_tree().create_timer(1.2).timeout
	await _tap(KEY_2)
	await get_tree().create_timer(1.0).timeout
	await _tap(KEY_1)
	await _tap(KEY_2)
	await get_tree().create_timer(2.0).timeout
	_check(player.tool_state == Player.Tool.HOLSTERED and GameState.selected_slot == 1, "rapid selection during equip resolves latest slot")
	await _tap(KEY_1)
	await get_tree().create_timer(1.2).timeout
	_check(player.tool_state == Player.Tool.READY, "select tool equips")
	await _tap(KEY_2)
	await get_tree().create_timer(1.0).timeout
	_check(GameState.selected_slot == 1 and player.tool_state == Player.Tool.HOLSTERED, "empty slot holsters")
	await _tap(KEY_E)
	await _mouse(ui, 0)
	await _mouse(ui, 6)
	_check(GameState.inventory[6].get("kind") == "multitool" and GameState.inventory[0].is_empty(), "UI moves tool into backpack")
	await _tap(KEY_DOWN)
	_check(ui._focus == 12, "keyboard grid navigation")
	await _tap(KEY_UP)
	await _tap(KEY_ENTER)
	_check(ui._picked == 6, "keyboard picks item")
	await _tap(KEY_ESCAPE)
	_check(ui.opened and ui._picked == -1, "Esc cancels pending swap first")
	await _tap(KEY_ESCAPE)
	_check(not ui.opened, "Esc closes")
	GameState.swap_slots(0, 6)
	GameState.select_slot(0)
	player.set_tool_out(true)
	var scrap: WorldProp
	var rock: WorldProp
	var crate: WorldProp
	for prop in tool._props:
		if prop.kind == "scrap":
			scrap = prop
		elif prop.kind == "ore_rock":
			rock = prop
		elif prop.job == "lift":
			crate = prop
	player.teleport(scrap.world + Vector2(0, -10))
	tool._target = scrap
	tool._working = true
	await _key(KEY_F)
	await get_tree().create_timer(0.65).timeout
	await _key(KEY_F, false)
	await get_tree().create_timer(0.25).timeout
	_check(GameState.inventory[1].get("kind") == "scrap", "F gather stores real scrap")
	_check(GameState.removed_props.size() == 1, "gather recorded once")
	player.teleport(rock.world + Vector2(0, -20))
	tool._target = rock
	tool._working = true
	await _key(KEY_F)
	await get_tree().create_timer(1.7).timeout
	await _key(KEY_F, false)
	await get_tree().create_timer(0.8).timeout
	_check(GameState.spawned_props.size() == 3, "mining creates three persistent chunks")
	tool._pick_up(crate)
	await _tap(KEY_F)
	_check(tool._lifted == null, "F sets lifted crate down")
	var lamp: Dictionary = tool._lamps[0]
	player.teleport(lamp["world"] + Vector2(0, -10))
	tool._target = lamp
	tool._working = true
	await _key(KEY_F)
	await get_tree().create_timer(2.5).timeout
	await _key(KEY_F, false)
	_check(lamp["lit"], "F repairs lamp")
	# A full bag must never destroy a world item.
	for i in range(1, 24):
		GameState.inventory[i] = {"kind": "scrap", "count": 99}
	_check(not GameState.can_store("scrap") and not GameState.store_item("scrap"), "full bag rejects without overflow")
	var chunk: WorldProp
	for prop in tool._props:
		if prop.kind == "ore_chunk":
			chunk = prop
	tool._target = chunk
	tool._work(1.0)
	_check(not chunk.gone and chunk.progress == 0.0, "full bag keeps gather target")
	GameState.inventory[1] = {"kind": "scrap", "count": 4}
	GameState.select_slot(1)
	var removed_count := GameState.removed_props.size()
	var prop_count := tool._props.size()
	var door: AirlockDoor = world.doors[0]
	player.teleport(door.stand_point())
	await _tap(KEY_E)
	_check(ui.opened and not door.busy(), "E beside door opens inventory only")
	await _key(KEY_F)
	await _tap(KEY_E)
	_check(tool.inventory_suppressed and not door.busy(), "held F suppressed on close")
	await _key(KEY_F, false)
	await _tap(KEY_F)
	_check(door.busy(), "F starts airlock cutscene")
	await _tap(KEY_E)
	_check(not ui.opened, "inventory unavailable in cutscene")
	# Exercise actual airlock transition, then reload the world with the same autoload.
	get_tree().current_scene = world
	await get_tree().create_timer(12.0).timeout
	var inside := get_tree().current_scene
	_check(inside != world and inside.scene_file_path.ends_with("interior.tscn"), "airlock enters interior")
	await get_tree().create_timer(4.0).timeout
	_check(_ui(inside) != null and GameState.inventory[1]["count"] == 4 and GameState.selected_slot == 1, "inventory persists indoors")
	await _tap(KEY_E)
	_check(_ui(inside).opened, "interior E opens")
	await _tap(KEY_E)
	_check(not get_tree().paused, "interior E closes")
	GameState.arrive = ""
	get_tree().change_scene_to_file("res://scenes/overworld.tscn")
	await get_tree().process_frame
	await get_tree().process_frame
	var returned := get_tree().current_scene
	var returned_tool: Multitool = returned.get_node("Multitool")
	_check(GameState.removed_props.size() == removed_count and returned_tool._props.size() == prop_count, "world ledger reconstructs chunks without duplicates")
	print("INVENTORY TESTS: %d checks, %d failures" % [_checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)
