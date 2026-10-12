extends Node
## Checks for turning the camera round the world (ViewTurn), against the real scenes and real key
## presses: the projection's turns undo each other, G / H step through the four views, the world
## doesn't move when the view does (the astronaut's place and facing, props, doors, repair bars),
## the widest zoom follows the astronaut in every view, a turn waits for a calm moment,
## and a press during a swing is kept.
## View preloads overlap streamed-window texture uploads and release cleanly at scene teardown.
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
	await _preload_windows()
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


## Exercise the same preload/window-upload overlap that exposed the dummy renderer's RID race.
func _preload_windows() -> void:
	var turn := ViewTurn.new()
	turn.terrain = MapTerrain.new("res://assets/maps/red_planet/red_planet_map.json")
	add_child(turn)
	var image := Image.create(32, 32, false, Image.FORMAT_RGB8)
	image.fill(Color.WHITE)
	for step in 32:
		turn._preload_around(step % 4)
		for i in 40:
			var texture := ImageTexture.create_from_image(image)
			var uploaded := texture.get_image()
			_check(uploaded != null and not uploaded.is_empty() and uploaded.get_pixel(0, 0).is_equal_approx(Color.WHITE), "window texture remains valid while view sprites preload")
		await get_tree().process_frame
	turn.queue_free()
	for i in 4: await get_tree().process_frame


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
	# Reproduce walking beside a base at the widest zoom, where dome framing used to take over.
	player.camera.set_level(player.camera.levels.size() - 1)
	await get_tree().create_timer(1.2).timeout
	_camera_centered(player, "widest zoom beside the base")
	player.forced_input = Vector2.RIGHT
	await get_tree().create_timer(0.8).timeout
	player.forced_input = Vector2.ZERO
	_check(player.world_pos.distance_to(start) > 5.0, "the astronaut walks at widest zoom")
	await get_tree().create_timer(1.2).timeout
	_camera_centered(player, "widest zoom after walking")
	player.teleport(start)
	player.puppet_face(facing)
	(world.get_node("Multitool") as Multitool)._spawn_prop("crate", start + Vector2(30, 10), 0, "lift", 7.0, true)   # the world has no test props
	var props := _props(world)
	_check(not props.is_empty(), "a prop to follow round")
	_check(terrain.heading == 0, "starts on view 0")
	for step in [KEY_H, KEY_H, KEY_G, KEY_H, KEY_H]:
		await _tap(step)
		await _settle(world)
		_camera_centered(player, "widest zoom after turning to view %d" % terrain.heading)
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
	_camera_centered(player, "widest zoom at the end of the swing")
	player.camera.set_level(0)
	await get_tree().create_timer(0.4).timeout
	_camera_centered(player, "zooming back in keeps the astronaut centered")
	var cutscene_focus := player.camera_focus() + Vector2(140, 80)
	player.camera.focus_override = cutscene_focus
	player.camera.snap_to(cutscene_focus)
	await get_tree().process_frame
	player.camera.force_update_scroll()
	_check(player.camera.get_screen_center_position().distance_to(cutscene_focus) < 2.0, "cutscenes can still override the focus")
	player.camera.release_focus()
	await get_tree().create_timer(2.5).timeout
	_camera_centered(player, "releasing cutscene focus returns to the astronaut")
	world.queue_free()
	for i in 4:                                          # let the scene and its textures go
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
	_check(base.player.camera.zoom_locked and base.player.camera.levels.size() == 1, "indoors stays at its locked zoom")
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
	for i in 4:
		await get_tree().process_frame
	GameState.heading = 0


## Preserve the normal torso offset; allow only whole-pixel snapping at rest.
func _camera_centered(player: Player, label: String) -> void:
	player.camera.force_update_scroll()
	var expected := player.camera_focus() + player.camera.offset
	var error := player.camera.get_screen_center_position().distance_to(expected)
	_check(error < 2.0, "%s: camera follows the astronaut (offset %.2f px)" % [label, error])


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
