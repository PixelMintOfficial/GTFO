extends Node
## Native crack/circuit and scene tests. Run headless with repair_test.tscn.
## Exercises placement, heat/speed/threshold, inventory transactions, real modal input,
## task order, timer expiry, reach, repaired art in all views and session persistence.

var _checks := 0
var _failures := 0


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("REPAIR TEST: " + label)


func _valid_power_path(puzzle: CircuitPuzzle) -> bool:
	var path := puzzle.connected_path
	if path.is_empty() or path[0] != int(puzzle.definition["startRow"]) * puzzle.cols:
		return false
	if path[-1] != int(puzzle.definition["endRow"]) * puzzle.cols + puzzle.cols - 1:
		return false
	var seen := {}
	for step in path.size():
		if seen.has(path[step]):
			return false
		seen[path[step]] = true
		if step == 0:
			continue
		var previous := Vector2i(path[step - 1] % puzzle.cols, path[step - 1] / puzzle.cols)
		var current := Vector2i(path[step] % puzzle.cols, path[step] / puzzle.cols)
		var direction := CircuitPuzzle.STEPS.find(current - previous)
		if direction < 0 or not puzzle.masks[path[step - 1]] & (1 << direction):
			return false
		if not puzzle.masks[path[step]] & (1 << ((direction + 2) % 4)):
			return false
	return true


func _tap(code: int) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame


func _click(panel: CircuitRepairUI, index: int, button := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = panel._canvas.get_global_transform() * panel.cell_center(index)
	event.button_index = button
	event.pressed = true
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
	await get_tree().process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await get_tree().process_frame


func _ready() -> void:
	for machine_id in ["power", "oxygen"]:
		var layouts := CircuitCatalog.for_machine(machine_id)
		_check(layouts.size() == 5, "five circuits per machine")
		for layout in layouts:
			for seed_value in 100:
				var puzzle := CircuitPuzzle.new(layout, seed_value + 1)
				_check(not puzzle.solved, "unsolved start " + layout["id"])
				_check(puzzle.connected_path.is_empty(), "no completion route for an open circuit")
				var before := puzzle.masks.duplicate()
				for p in layout["locked"]:
					var index := int(p[1]) * puzzle.cols + int(p[0])
					_check(not puzzle.rotate(index) and puzzle.masks[index] == before[index], "bolted wire immutable")
				for p in CircuitCatalog.route(layout):
					var index := p.y * puzzle.cols + p.x
					for turn in 4:
						if puzzle.masks[index] == puzzle.solution[index] or puzzle.solved:
							break
						puzzle.rotate(index)
				_check(puzzle.solved, "authored route solves " + layout["id"])
				_check(_valid_power_path(puzzle), "power animation route follows actual connected ports")
				_check(not puzzle.rotate(0), "solved board stops changes")
	var alternate := CircuitPuzzle.new({"cols": 3, "rows": 2, "startRow": 0, "endRow": 0,
		"waypoints": [[0, 0], [2, 0]], "blanks": [], "locked": []}, 4)
	alternate.masks = PackedInt32Array([12, 5, 6, 3, 10, 9])
	alternate.trace()
	_check(alternate.solved and alternate.connected_path == PackedInt32Array([0, 3, 4, 5, 2]), "pulse follows an alternate route rather than the authored top row")
	alternate.masks[2] = 5
	alternate.trace()
	_check(alternate.connected_path.is_empty(), "breaking the output clears the completion route")
	var flow := CircuitPowerFlow.new(PackedVector2Array([Vector2.ZERO, Vector2(12, 0), Vector2(12, 12)]))
	_check(flow.sample(6) == Vector2(6, 0) and flow.sample(18) == Vector2(12, 6), "pulse stays on both legs of a corner")
	_check(flow.section(6, 18) == PackedVector2Array([Vector2(6, 0), Vector2(12, 0), Vector2(12, 6)]), "pulse trail turns through corners")
	flow.advance(CircuitPowerFlow.START_DELAY + CircuitPowerFlow.TRAVEL_SECONDS * 0.5)
	_check(is_equal_approx(flow.progress(), 0.5) and not flow.arrived(), "receiver waits until the pulse arrives")
	flow.advance(CircuitPowerFlow.TRAVEL_SECONDS * 0.5)
	_check(flow.arrived() and not flow.finished() and flow.sample(flow.length) == Vector2(12, 12), "receiver arrival has a separate settling phase")
	flow.advance(100)
	_check(flow.finished() and flow.elapsed == CircuitPowerFlow.DURATION, "completion effect stops once")
	var state := MachineRepair.new("power", 71)
	_check(not state.rotate(0) and not state.complete_task("wiring"), "wiring cannot start before cracks")
	state.advance(90)
	_check(state.remaining == 30 and state.layout_index == 0, "cracks do not run the circuit timer")
	state.complete_task("cracks")
	state.advance(29.999)
	_check(state.layout_index == 0 and state.remaining > 0, "attempt lasts 30 seconds")
	state.advance(0.002)
	_check(state.layout_index == 1 and state.remaining == 30 and not state.puzzle.solved, "timeout swaps layout and timer")
	for i in 4:
		state.advance(30)
	_check(state.layout_index == 0, "five-layout cycle wraps")
	_check(state.progress() == 0.5 and not state.complete_task("invalid"), "timeout gives no extra repair credit")
	_check(state.complete_task("wiring") and state.progress() == 1, "wiring finishes after cracks")
	_check(not state.complete_task("wiring") and state.progress() == 1, "credit is idempotent")
	var finished_index := state.layout_index
	state.advance(90)
	_check(state.layout_index == finished_index and not state.rotate(0), "completed wiring stops timer and input")
	_check(not state.complete_task("cracks") and state.progress() == 1, "cracks credit is idempotent")
	_crack_model_checks()
	GameState.machine_repairs.clear()
	GameState.reset_inventory()
	var room := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await get_tree().process_frame
	await get_tree().process_frame
	var player: Player = room.get_node("Actors/Player")
	var tool: Multitool = room.get_node("Multitool")
	var controller: MachineRepairs = room.repairs
	_check(controller.machines.size() == 2, "both machines attached to real interior")
	var power := GameState.repair_for("power")
	var oxygen := GameState.repair_for("oxygen")
	_check(not controller.open_machine("power") and not get_tree().paused, "missing scrap blocks entry without pausing")
	var scrap_props := tool._props.filter(func(p: WorldProp) -> bool: return p.kind == "scrap")
	_check(scrap_props.size() == 6, "base supplies enough real gatherable scrap for both machines")
	player.set_tool_out(true)
	for prop in scrap_props:
		player.teleport(prop.world + Vector2(0, -5))
		_check(player._can_be(player.world_pos, false), "loose scrap can be reached on foot")
		await get_tree().process_frame
		_check(controller.nearest == -1, "gathering scrap is outside machine F priority")
		tool.forced_use = true
		await get_tree().create_timer(.65).timeout
		tool.forced_use = false
		await get_tree().create_timer(.3).timeout
	_check(GameState.item_count("scrap") == 6, "multitool gathers all six interior scraps")
	GameState.store_item("scrap")
	GameState.store_item("ore_chunk")
	for info in controller.machines:
		var at := Vector2(info["stand_world"][0], info["stand_world"][1])
		_check(player._can_be(at, false), "reachable machine front " + info["id"])
		var body := Vector2(info["world"][0], info["world"][1])
		_check(not player._can_be(body, false), "cannot walk through machine " + info["id"])
		var anchor := Vector2(info["progress_px"][0], info["progress_px"][1])
		var expected: Vector2 = room.terrain.to_screen(body, 43.0)
		_check(anchor.distance_to(expected) < 0.2, "progress bar follows the map projection " + info["id"])
		player.teleport(at + Vector2(0, -10))
		player.forced_input = Vector2.UP
		await get_tree().create_timer(0.3).timeout
		player.forced_input = Vector2.ZERO
		_check(player.world_pos.y > at.y - 10, "walk approaches machine " + info["id"])
		player.teleport(at)
		await get_tree().process_frame
		await _pad(JOY_BUTTON_X)
		_check(controller.crack_panel.opened and not controller.panel.opened, "X opens cracks before circuits")
		var crack_panel := controller.crack_panel
		var crack := crack_panel.model
		_check(Rect2(Vector2.ZERO, crack_panel._machine.get_size()).encloses(crack_panel._source_rect) and crack_panel._source_rect.size == Vector2(642, 219), "original panel wall crop stays inside its unchanged source PNG")
		_check(crack_panel._baked_damage and crack.damage_samples.size() == 3, "placement follows the three holes baked into the supplied image")
		var count := GameState.item_count("scrap")
		var time := GameState.repair_for(info["id"]).remaining
		await _crack_click(crack_panel, CrackRepairUI._slot(0).get_center())
		await _crack_click(crack_panel, crack.sites[0])
		_check(crack.placed[0] == 0, "real pointer picks and places inventory scrap")
		await _tap(KEY_E)
		_check(get_tree().paused and GameState.item_count("scrap") == count, "unfinished placement reserves resources")
		await _tap(KEY_ESCAPE)
		_check(not controller.modal_open() and player.controls_enabled and GameState.item_count("scrap") == count, "closing cracks loses no materials")
		await _tap(KEY_F)
		_check(controller.crack_panel.model == crack and crack.placed[0] == 0, "cracks persist on reopen")
		for i in range(1, 3):
			_check(crack.place(i, crack.sites[i]) == i, "actual machine has room for three separate patches")
		for i in 3:
			_weld(crack, i)
		await get_tree().process_frame
		_check(crack.solved() and GameState.repair_for(info["id"]).task_completed("cracks"), "all three seams finish cracks")
		_check(GameState.item_count("scrap") == count - 3 and GameState.item_count("ore_chunk") == 1, "success consumes three scraps and no ore")
		_check(GameState.repair_for(info["id"]).remaining == time, "welding is untimed and leaves circuit countdown fresh")
		await get_tree().create_timer(1.05).timeout
		_check(crack.glow[0] == 0 and crack.glow[1] == 0 and crack.glow[2] == 0, "teal glow disappears in one second")
		await _crack_click(crack_panel, CrackRepairUI.NEXT.get_center())
		_check(controller.panel.opened and not crack_panel.opened and get_tree().paused, "continue transfers modal ownership to circuits")
		await _pad(JOY_BUTTON_B)
		await _pad(JOY_BUTTON_X)
		_check(controller.panel.opened, "X opens machine on gamepad")
		var selected := controller.panel._focus
		var initial_mask := controller.panel.repair.puzzle.masks[selected]
		await _pad(JOY_BUTTON_A)
		_check(controller.panel.repair.puzzle.masks[selected] == CircuitPuzzle.rotated(initial_mask), "A rotates on gamepad")
		await _pad(JOY_BUTTON_B)
		_check(not controller.panel.opened, "B closes on gamepad")
		await _tap(KEY_F)
		_check(controller.panel.opened and get_tree().paused, "F opens machine " + info["id"])
		_check(controller.panel.repair.machine_id == info["id"], "correct machine state selected")
		_check(tool.repair_suppressed and not player.controls_enabled, "world input suppressed")
		var start := player.world_pos
		await _tap(KEY_E)
		await _tap(KEY_T)
		await _tap(KEY_2)
		await _tap(KEY_SPACE)
		_check(player.world_pos == start and GameState.selected_slot == 0, "repair owns movement and inventory input")
		var panel := controller.panel
		var puzzle := panel.repair.puzzle
		var index := panel._focus
		var mask := puzzle.masks[index]
		await _click(panel, index)
		_check(puzzle.masks[index] == CircuitPuzzle.rotated(mask), "pointer turns clockwise")
		await _click(panel, index, MOUSE_BUTTON_RIGHT)
		_check(puzzle.masks[index] == mask, "right click turns back")
		await _tap(KEY_Q)
		_check(puzzle.masks[index] == CircuitPuzzle.rotated(mask, false), "Q turns back")
		var fixed_index := -1
		for j in puzzle.fixed.size():
			if puzzle.fixed[j]:
				fixed_index = j
				break
		var fixed_mask := puzzle.masks[fixed_index]
		await _click(panel, fixed_index)
		_check(puzzle.masks[fixed_index] == fixed_mask, "bolted module ignores pointer")
		await _tap(KEY_RIGHT)
		_check(puzzle.movable(panel._focus), "keyboard navigation skips bolts and plates")
		var old_puzzle := panel.repair.puzzle
		await _tap(KEY_ESCAPE)
		_check(not panel.opened and not get_tree().paused and player.controls_enabled, "Esc closes and resumes")
		var closed_time := panel.repair.remaining
		await get_tree().create_timer(0.08).timeout
		_check(panel.repair.remaining == closed_time, "closed timer remains paused")
		await _tap(KEY_F)
		_check(panel.repair.puzzle == old_puzzle and panel.opened, "reopening keeps attempt")
		var other_time := oxygen.remaining if info["id"] == "power" else power.remaining
		panel.repair.remaining = 0.001
		await get_tree().process_frame
		await get_tree().process_frame
		_check(panel.repair.puzzle != old_puzzle and panel.repair.layout_index == 1, "active panel changes on expiry")
		_check((oxygen.remaining if info["id"] == "power" else power.remaining) == other_time, "other machine timer untouched")
		for p in CircuitCatalog.route(panel.repair.puzzle.definition):
			index = p.y * panel.repair.puzzle.cols + p.x
			for turns in 4:
				if panel.repair.puzzle.solved or panel.repair.puzzle.masks[index] == panel.repair.puzzle.solution[index]:
					break
				await _click(panel, index)
		_check(panel.repair.task_completed("wiring") and panel.repair.progress() == 1, "real circuit completes both tasks")
		await get_tree().process_frame
		await get_tree().process_frame
		var fixed_meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(room.terrain.view_json))
		_check(fixed_meta["fixed_machines"].has(info["id"]), "completion swaps the machine's actual room art")
		_check(not player._can_be(body, false) and player._can_be(at, false), "fixed machine remains solid and reachable")
		var actual_flow := panel._flow
		_check(actual_flow != null and not panel._receiver_live(), "actual solve starts a pulse before receiving power")
		_check(actual_flow.points[0] == panel._terminal_center(true) + Vector2(5, 0), "pulse starts at the power bank")
		_check(actual_flow.points[-1] == panel._terminal_center(false) + Vector2(2, 0), "pulse ends at the receiving relay")
		actual_flow.advance(CircuitPowerFlow.DURATION)
		_check(panel._receiver_live(), "receiving relay activates on arrival")
		panel.repair.changed.emit()
		_check(panel._flow == actual_flow and panel.repair.progress() == 1, "effect never replays or duplicates repair credit")
		await _tap(KEY_ESCAPE)
		await _tap(KEY_F)
		_check(not panel.opened, "solved machine does not require another circuit")
	_check(power.progress() == 1 and oxygen.progress() == 1 and GameState.item_count("scrap") == 1, "independent repairs spend exactly six scraps")
	for heading in 4:
		room._apply_view(heading, player.facing_dir())
		var variant: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(room.terrain.view_json))
		_check(variant["fixed_machines"].size() == 2 and room.fx._vents.is_empty() and room.fx._spark_points.is_empty(), "both fixed machines persist in view %d without faults" % heading)
	controller.panel.reduced_motion = true
	var accessible_state := MachineRepair.new("power", 17)
	accessible_state.complete_task("cracks")
	controller.panel.open(accessible_state)
	for cell in CircuitCatalog.route(accessible_state.puzzle.definition):
		var tile := cell.y * accessible_state.puzzle.cols + cell.x
		for turn in 4:
			if accessible_state.puzzle.solved or accessible_state.puzzle.masks[tile] == accessible_state.puzzle.solution[tile]:
				break
			accessible_state.rotate(tile)
	_check(controller.panel._flow == null and controller.panel._receiver_live(), "reduced motion activates receiving power immediately")
	controller.panel.close()
	room.queue_free()
	await get_tree().process_frame
	room = load("res://scenes/interior.tscn").instantiate()
	get_tree().root.add_child.call_deferred(room)
	await get_tree().process_frame
	_check(GameState.repair_for("power") == power and GameState.repair_for("oxygen") == oxygen, "repairs persist across scene reload")
	_check(room.terrain.view_json.contains("repaired_both"), "fixed artwork persists across scene reload")
	_check(room.get_node("Multitool")._props.all(func(p: WorldProp) -> bool: return p.kind != "scrap"),
			"collected interior scrap never respawns through the airlock")
	room.queue_free()
	await get_tree().process_frame
	print("Repair: ", _checks, " checks; ", _failures, " failures; 1000 shuffled native circuits.")
	await Audio.quit(1 if _failures else 0)


func _crack_click(panel: CrackRepairUI, point: Vector2) -> void:
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = panel._canvas.get_global_transform() * point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame


func _weld(model: CrackPuzzle, hole: int) -> void:
	var seam := model.seams[hole]
	for j in seam.size():
		var a := seam[j]
		var b := seam[(j + 1) % seam.size()]
		model.stroke(a, b, a.distance_to(b) / 65.0)


func _crack_model_checks() -> void:
	var model := CrackPuzzle.new(PackedVector2Array([Vector2(80, 80), Vector2(180, 80), Vector2(280, 80)]))
	_check(model.place(0, Vector2.ZERO) == -1 and not model.solved(), "uncovered placement rejected")
	_check(not model.can_place(0, model.sites[0] + Vector2(30, 0), 0), "edge coverage and placement margin reject an uncovered crack")
	for i in 3:
		_check(model.place(i, model.sites[i]) == i, "all irregular scraps fit their apertures")
	_check(model.place(0, model.sites[1]) == -1, "scrap cannot be reused")
	model.stroke(model.seams[0][0], model.seams[0][0], 1)
	_check(not model.overheated and model.deposits.is_empty(), "one-second pause stays cool and stationary torch cannot fill a seam")
	model.stroke(model.seams[0][0], model.seams[0][0], 2)
	_check(model.overheated and model.coverage(0) == 0, "holding still burns through a local seam")
	model.stroke(model.seams[0][0], model.seams[0][8], .12)
	_check(model.coverage(0) == 0, "overheated torch must be lifted")
	model.cool(.5)
	_check(not model.overheated, "lifting cools the torch")
	_weld(model, 0)
	_check(not model.deposits.is_empty(), "moving torch leaves persistent rounded metal deposits")
	_check(model.sealed[0] == 1 and not model.solved() and model.glow[0] == 1, "one sealed hole glows but cannot finish whole puzzle")
	var previous := model.seams[0][0]
	var previous_bead: Vector2 = model.deposits.values()[0][0]
	var points := model.sites.duplicate()
	points[0] += Vector2(8, 9)
	model.relocate(points)
	_check(model.seams[0][0] == previous + Vector2(8, 9) and model.sealed[0] == 1, "inspection layout changes preserve placed scrap and completed seam")
	_check(model.deposits.values()[0][0] == previous_bead + Vector2(8, 9), "stroke-aligned weld appearance follows the preserved scrap on reopen")
	model.advance_visuals(.6)
	_check(is_equal_approx(model.glow[0], .4), "teal completion fades")
	model.advance_visuals(.5)
	_check(model.glow[0] == 0, "completion tint is transient")
	var n := model.welded[1].size()
	model.welded[1].fill(0)
	for i in floori(n * .94):
		model.welded[1][i] = 1
	model._refresh_sealed()
	_check(model.sealed[1] == 0, "94 percent is below the per-hole completion threshold")
	for i in ceili(n * .95):
		model.welded[1][i] = 1
	model._refresh_sealed()
	_check(model.sealed[1] == 1 and not model.solved(), "95 percent accepted per seam but all three required")
	model.stroke(model.seams[2][0], model.seams[2][35], .001)
	_check(model.coverage(2) < .5, "fast strokes leave unwelded gaps")
	_weld(model, 2)
	_check(model.solved(), "three individually sealed perimeters complete")
	GameState.reset_inventory()
	GameState.inventory[1] = {"kind": "scrap", "count": 1}
	GameState.inventory[9] = {"kind": "scrap", "count": 2}
	GameState.inventory[10] = {"kind": "ore_chunk", "count": 5}
	_check(not GameState.consume_item("scrap", 4) and GameState.item_count("scrap") == 3, "failed transaction leaves split stacks intact")
	var repair := MachineRepair.new("power")
	repair.cracks = model
	_check(repair.finish_cracks() and GameState.inventory[1].is_empty() and GameState.inventory[9].is_empty() and GameState.item_count("ore_chunk") == 5, "successful crack transaction spans stacks without touching ore")
	_check(not repair.finish_cracks() and repair.progress() == .5, "success spends materials and credits cracks exactly once")
