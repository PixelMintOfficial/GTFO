extends Node
## Checks for storage's smashed panes and the cargo box (WindowCracks, WindowRepair), against the
## real interior and real jumps: the box blocks you from the floor, a held jump lands you on top,
## walking off the edge drops you, the tool lifts it but never from under your own feet; standing
## on it under a pane only cracks it once; only finishing all three repairs makes it give way,
## you go down with it, and its rations spill to be gathered; all of it survives a scene reload.
## Outside, the storage room's dome gets its glass back once all three windows are mended.
## Run: godot --headless --path . res://tests/window_crack_test.tscn  (failures exit nonzero)

var _checks := 0
var _failures := 0


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("WINDOW CRACK TEST: " + label)


func _ready() -> void:
	_model()
	_data()
	await _scene()
	await _outside()
	print("WINDOW CRACK TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


## One crack per pane, none while a pane waits to be mended, and the break.
func _model() -> void:
	var r := WindowRepair.new()
	_check(r.crack_box("burst") and r.damage() == 1, "the box cracks under a pane")
	_check(not r.crack_box("burst") and r.damage() == 1, "not twice for the same pane")
	_check(not r.crack_box("crescent") and r.pending() == "burst", "not again until that pane is mended")
	_check(r.fix("burst") and not r.fix("burst") and r.pending() == "", "mending is once")
	_check(not r.crack_box("burst"), "a mended pane never cracks it again")
	_check(r.crack_box("crescent") and r.fix("crescent") and r.crack_box("gash") and r.damage() == 3, "one crack per pane")
	_check(not r.all_fixed(["burst", "crescent", "gash"]), "the third pane is still open")
	r.fix("gash")
	_check(r.all_fixed(["burst", "crescent", "gash"]) and not r.box_broken, "all mended; the box waits for you to stand on it")
	r.break_box()
	_check(r.box_broken and not r.crack_box("other"), "a broken box takes no more cracks")


## Three panes in every view; the third is out of sight in the view you come in by.
func _data() -> void:
	var seen := {}
	for k in 4:
		var path := "res://assets/maps/base_interior/base_interior%s.json" % ("" if k == 0 else "_r%d" % k)
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		var panes: Array = meta["window_cracks"]
		_check(panes.size() == 3, "three panes in view %d" % k)
		for p in panes:
			if p["seen"]:
				seen[p["id"]] = seen.get(p["id"], []) + [k]
	_check(seen.get("burst", []).has(0) and seen.get("crescent", []).has(0), "two panes face you as you come in")
	_check(not seen.get("gash", [0]).has(0) and not seen.get("gash", []).is_empty(), "the third only shows once you turn")


func _hop(player: Player) -> void:
	player.auto_jump_every = 0.05
	await player.landed
	player.auto_jump_every = 0.0
	for i in 3:
		await get_tree().physics_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _scene() -> void:
	GameState.reset_inventory()
	GameState.heading = 0
	GameState.intro_done = true
	var room := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await get_tree().process_frame
	await get_tree().process_frame
	var player: Player = room.get_node("Actors/Player")
	var tool: Multitool = room.get_node("Multitool")
	var terrain: MapTerrain = room.terrain
	var cracks: WindowCracks = room.cracks
	var box := cracks.box
	_check(box != null and box.job == "lift" and is_equal_approx(box.top, 14.4), "the cargo box is a liftable prop you can stand on")
	_check(terrain.platforms.size() == 1 and is_equal_approx(terrain.stand_height(box.world), 14.4), "it is a platform")
	_check(box.get_meta("contents", {}).get("kind", "") == "ration", "rations packed inside")

	# from the floor: its side stops you; a held jump lands you on top
	var front := box.world + Vector2(0, -box.half.y - 6.0)
	player.teleport(front)
	_check(not player._can_be(box.world, false), "you can't walk into its side")
	player.forced_input = Vector2(0, -1)                # up the screen: toward the box
	await _wait(0.6)
	_check(player.height_above_floor() < 0.1 and not box.covers(player.world_pos), "walking at it, you stop at its side")
	player.auto_jump_every = 0.05
	for i in 300:
		await get_tree().physics_frame
		if box.covers(player.world_pos):                # over the top: let go of the stick and the button
			player.forced_input = Vector2.ZERO
			player.auto_jump_every = 0.0
		if player.forced_input == Vector2.ZERO and not player.is_airborne() and player.height_above_floor() > 1.0:
			break
	player.forced_input = Vector2.ZERO
	player.auto_jump_every = 0.0
	for i in 12:
		await get_tree().physics_frame
	_check(box.covers(player.world_pos, 2.0) and absf(player.height_above_floor() - 14.4) < 0.1, "a held jump lands you on top")
	_check(player.z_index == 1, "on top, drawn over the box")
	_check(GameState.window_repair.damage() == 0, "standing on it away from the panes cracks nothing")
	_check(player.shadow.position.y < -20.0, "your shadow falls on the box top")

	# the tool never lifts the box under your own feet; from the floor, it does
	player.set_tool_out(true)
	await get_tree().process_frame
	_check(tool._find_target() != box, "no lifting the box you stand on")
	player.forced_input = Vector2(0, 1)                 # walk off its front edge
	await _wait(1.0)
	player.forced_input = Vector2.ZERO
	_check(player.height_above_floor() < 0.1 and not box.covers(player.world_pos), "walking off the edge drops you to the floor")
	player.teleport(front)
	await get_tree().process_frame
	_check(tool._find_target() == box, "from the floor, the tool picks the box to lift")
	tool.forced_use = true
	await _wait(0.1)
	tool.forced_use = false
	tool._forced_pressed = false
	await _wait(0.5)
	_check(tool._lifted == box and terrain.platforms.is_empty(), "lifted, it is nothing to stand on")
	var before := box.world
	player.forced_input = Vector2(-1, 0)
	await _wait(0.6)
	player.forced_input = Vector2.ZERO
	_check(box.world.distance_to(before) > 5.0, "it follows you")
	tool.forced_use = true
	await _wait(0.1)
	tool.forced_use = false
	tool._forced_pressed = false
	await _wait(0.5)
	_check(tool._lifted == null and terrain.platforms.size() == 1 and box.lift == 0.0, "set down, you can stand on it again")
	_check(GameState.window_repair.box_world == box.world, "where it was set down is kept")

	# under each pane: wear alone never repairs the glass or collapses the box
	cracks.place_box_under("burst")
	player.teleport(box.world)
	await _hop(player)
	_check(GameState.window_repair.damage() == 1 and box.sprite.frame == 1, "under the first pane the box cracks")
	_check(not GameState.window_repair.fixed.has("burst"), "landing never mends the pane")
	await _hop(player)
	_check(GameState.window_repair.damage() == 1, "jumping on it again there cracks nothing more")
	cracks.fix("burst")
	cracks.place_box_under("crescent")
	player.teleport(box.world)
	await _hop(player)
	_check(GameState.window_repair.damage() == 2 and box.sprite.frame == 2, "the second pane: the second crack")
	cracks.fix("crescent")

	# leave and come back: the box is where you left it, as cracked as it was
	var kept := box.world
	room.queue_free()
	await get_tree().process_frame
	room = load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child(room)
	await get_tree().process_frame
	player = room.get_node("Actors/Player")
	tool = room.get_node("Multitool")
	cracks = room.cracks
	box = cracks.box
	player.set_tool_out(true)
	_check(box.world == kept and box.sprite.frame == 2, "the box and its cracks survive the airlock")

	# the third pane: the box gives way, you go down with it, the rations spill
	var rations := GameState.item_count("ration")
	cracks.place_box_under("gash")
	player.teleport(box.world)
	await _hop(player)
	_check(GameState.window_repair.damage() == 3 and not GameState.window_repair.all_fixed(cracks._pane_ids()), "the third landing leaves its window open")
	await _wait(WindowCracks.GROAN + .2)
	_check(not GameState.window_repair.box_broken and box.top > 0 and player.controls_enabled, "the box stays usable at third wear until the final repair")
	_check(GameState.window_repair.dome_mended == "", "two panes mended: the dome outside is still broken")
	cracks.fix("gash")
	_check(GameState.window_repair.dome_mended == "command", "all three mended: so is the storage room's dome outside")
	await _wait(.05)
	_check(not player.controls_enabled, "it groans under you")
	await _wait(WindowCracks.GROAN + 0.2)
	_check(GameState.window_repair.box_broken and box.job == "" and box.sprite.frame == box.sprite.hframes - 1, "it gives way")
	_check(player.controls_enabled and player._downed, "you go down with it")
	await _wait(1.6)
	_check(player.height_above_floor() < 0.1 and not player._downed, "and get back up on the floor")
	var spilled := []
	for p in tool._props:
		if is_instance_valid(p) and not p.gone and p.kind == "ration":
			spilled.append(p)
	_check(spilled.size() == 4, "four ration packs spill out")
	_check(tool._find_target() != box, "the wreck is nothing for the tool")
	for p in spilled:
		_check(not box.covers(p.world, 4.0), "a ration lands clear of the wreck")
	for attempt in 20:                                  # nearby glass is also legitimate salvage; gather until rations are gone
		var left := spilled.filter(func(p: Variant) -> bool: return is_instance_valid(p) and not p.gone)
		if left.is_empty():
			break
		var p: WorldProp = left[0]
		player.teleport(p.world + Vector2(0, -5))
		player._set_facing(p.world - player.world_pos)
		await get_tree().process_frame
		tool.forced_use = true
		await _wait(0.7)
		tool.forced_use = false
		await _wait(0.3)
	_check(GameState.item_count("ration") == rations + 4, "the tool gathers them into the backpack")

	# and after the airlock: still broken, nothing respawns
	room.queue_free()
	await get_tree().process_frame
	room = load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child(room)
	await get_tree().process_frame
	box = room.cracks.box
	var left := 0
	for p in room.get_node("Multitool")._props:
		if p.kind == "ration":
			left += 1
	_check(box.sprite.frame == box.sprite.hframes - 1 and box.job == "" and left == 0, "the wreck stays; gathered rations stay gathered")
	room.queue_free()
	await get_tree().process_frame


## Outside, the mended room's holes get their glass back, in every view that shows them, and
## stand in the camera's swing; nothing is mended outside until the windows are.
func _outside() -> void:
	GameState.intro_done = true
	GameState.arrive = ""
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child(world)
	await get_tree().process_frame
	var terrain: MapTerrain = world.terrain
	var domes: DomeFX = world.dome_fx
	for k in 4:
		terrain.load_view(k)
		domes.load_view(terrain.view_json)
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(terrain.view_json))
		var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(terrain.view_json.get_base_dir().path_join(meta["fx"])))
		var holes := (fx["cracks"] as Array).filter(func(c: Dictionary) -> bool: return c["room"] == "command")
		_check(domes._glass.size() == holes.size(), "view %d: glass over every hole of the mended room" % k)
		for i in mini(holes.size(), domes._glass.size()):
			_check(domes._glass[i].position == Vector2(holes[i]["patch_pos"][0], holes[i]["patch_pos"][1]),
					"view %d: the glass sits where its hole was" % k)
		_check(domes.boards().size() >= holes.size(), "view %d: the mended glass stands in the camera's swing" % k)
	GameState.window_repair.dome_mended = ""
	domes.load_view(terrain.view_json)
	_check(domes._glass.is_empty(), "nothing mended outside until the windows are")
	world.queue_free()
	await get_tree().process_frame
