extends Node
## Checks for turning the camera round the world (ViewTurn), against the real scenes and real key
## presses: the projection's turns undo each other, G / H step through the four views, the world
## doesn't move when the view does (the astronaut's place and facing, props, doors, repair bars),
## a turn waits for a calm moment, and a press during a swing is kept.
## Run: godot --headless --path . res://tests/view_turn_test.tscn  (failures exit nonzero)

var _checks := 0
var _failures := 0


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("VIEW TURN TEST: " + label)
		get_tree().quit(1)


func _tap(code: int) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame


func _settle(scene: Node) -> void:
	var turn: ViewTurn = scene.view_turn
	for i in 400:
		if not turn.busy:
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _ready() -> void:
	GameState.intro_done = true
	GameState.heading = 0
	_projection()
	await _overworld()
	await _interior()
	print("VIEW TURN TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


## The view's turn and its undoing, for points and directions, in every view.
func _projection() -> void:
	var t := MapTerrain.new("res://assets/maps/red_planet/red_planet_map.json")
	_check(t.views.size() == 4, "the map has four views")
	var rs := RandomNumberGenerator.new()
	rs.seed = 7
	for k in 4:
		t.load_view(k)
		_check(t.heading == k, "view %d says it is heading %d" % [k, k])
		for i in 20:
			var p := Vector2(rs.randf_range(-1500, 1500), rs.randf_range(100, 3000))
			_check(t.world_point(t.view_point(p)).distance_to(p) < 0.001, "view %d: a point turns back" % k)
			var d := Vector2.from_angle(rs.randf() * TAU)
			_check(t.world_dir(t.view_dir(d)).distance_to(d) < 0.001, "view %d: a direction turns back" % k)
			_check(absf(t.view_depth(p) - t.view_point(p).y) < 0.001, "view %d: depth is the view's y" % k)
	# a quarter turn to the right takes screen-right to what was screen-up
	t.load_view(1)
	_check(t.world_dir(Vector2(1, 0)).distance_to(Vector2(0, 1)) < 0.001, "view 1: screen right is world +Y")
	# the world is 2 * view_center.y deep from every side; the 16-bit depth map must reach all of it
	_check(t.view_center.y * 2.0 * t.depth_scale < 65534.0, "the depth map reaches the far side of the world")


func _overworld() -> void:
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	var player: Player = world.player
	var terrain: MapTerrain = world.terrain
	var start := player.world_pos
	var facing := player.facing_dir()
	(world.get_node("Multitool") as Multitool)._spawn_prop("crate", start + Vector2(30, 10), 0, "lift", 7.0, true)   # the world has no test props
	var props := _props(world)
	_check(not props.is_empty(), "a prop to follow round")
	_check(terrain.heading == 0, "starts on view 0")
	for step in [KEY_H, KEY_H, KEY_G, KEY_H, KEY_H]:
		await _tap(step)
		await _settle(world)
	_check(terrain.heading == 3 and GameState.heading == 3, "H H G H H ends three quarter turns round (got %d)" % terrain.heading)
	_check(player.world_pos.distance_to(start) < 0.01, "the astronaut stays where they were")
	_check(player.facing_dir().distance_to(facing) < 0.01, "and faces the same way in the world")
	_check(player.position == terrain.to_screen(player.world_pos, terrain.height_at(player.world_pos)).round(),
			"the astronaut is drawn where this view puts them")
	_check(world.get_node("Map").texture == terrain.map_texture, "the map shows this view's picture")
	_check(world.doors.size() == 2, "the airlock doors are rebuilt for the view")
	for d in world.doors:
		_check(Rect2(Vector2.ZERO, terrain.map_size).has_point((d as AirlockDoor).sprite.position + d.position),
				"door %d sits on this view's map" % d.get_meta("id"))
	var now := _props(world)
	_check(now.size() == props.size(), "every prop is still there")
	for p in now:
		var wp := p as WorldProp
		_check(wp.position == terrain.to_screen(wp.world, terrain.height_at(wp.world)).round(), "%s redrawn for the view" % wp.kind)
	# a turn waits for a calm moment
	player.controls_enabled = false
	await _tap(KEY_H)
	await _settle(world)
	_check(terrain.heading == 3, "no turning while the controls are taken (a cutscene, a modal)")
	player.controls_enabled = true
	# a press during the swing is kept and played straight after
	await _tap(KEY_G)
	await _tap(KEY_G)
	await _settle(world)
	await _settle(world)
	_check(terrain.heading == 1, "a press during a swing turns again after it (got %d)" % terrain.heading)
	# the swing starts on the view it leaves and ends on the view it arrives at, to the pixel
	var points := []
	for d in [Vector2.ZERO, Vector2(60, 0), Vector2(0, 60), Vector2(-40, 30)]:
		var w: Vector2 = player.world_pos + d
		points.append(Vector3(w.x, w.y, terrain.height_at(w)))
	var before := _on_screen(player, points)
	await _tap(KEY_H)
	var overlay: TurnOverlay = world.view_turn._overlay
	var after := _on_screen(player, points)
	for i in points.size():
		_check(overlay.screen_point(points[i], 0.0).distance_to(before[i]) < 1.0, "the swing starts where the view was (%s)" % points[i])
		_check(overlay.screen_point(points[i], 1.0).distance_to(after[i]) < 1.0, "the swing ends where the view is (%s)" % points[i])
	await _settle(world)
	world.queue_free()
	await get_tree().process_frame


func _interior() -> void:
	GameState.heading = 1
	var base := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(base)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	var terrain: MapTerrain = base.terrain
	_check(terrain.heading == 1, "the base opens on the view the camera was in outside")
	await _tap(KEY_H)
	await _settle(base)
	_check(terrain.heading == 2, "indoors turns too")
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(terrain.view_json))
	for info in meta["repair_machines"]:
		for m in base.repairs.machines:
			if m["id"] == info["id"]:
				_check(m["progress_px"] == info["progress_px"], "the %s bar moves to this view" % info["id"])
	_check(is_instance_valid(base.door) and base.door.get_parent() != null, "the exit door is rebuilt")
	base.queue_free()
	await get_tree().process_frame
	GameState.heading = 0


## Where the live view draws these world points, in map px from the screen's centre.
func _on_screen(player: Player, points: Array) -> Array:
	var cam := player.camera
	cam.force_update_scroll()
	var out := []
	for p in points:
		out.append(player.terrain.to_screen(Vector2(p.x, p.y), p.z) - cam.get_screen_center_position())
	return out


func _props(scene: Node) -> Array:
	var out := []
	for n in scene.get_node("Actors").get_children():
		if n is WorldProp and not (n as WorldProp).gone:
			out.append(n)
	return out
