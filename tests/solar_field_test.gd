extends Node
## Solar regression suite: finite optics, all-angle physical shortcut search, real F/gamepad
## input, independent suppression, all four camera turns,
## physical footprints/reach and solar/engine state through scene replacement.
## Full base power needs both restored machines as well as the completed solar field.
## Layout regressions also check equipment clearance, graded access and elevated ray geometry.
## Run: godot --headless --path . res://tests/solar_field_test.tscn
## Optional rendered evidence: omit --headless and append -- --gallery=shots/solar --audio-debug.

const RouteSearch = preload("res://tests/solar_route_search.gd")

var _checks := 0
var _failures := 0
var _gallery := ""


func _capture(label: String, delay := .8) -> void:
	if _gallery.is_empty():
		return
	await get_tree().create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	var path := _gallery + "-" + label + ".png"
	_check(get_viewport().get_texture().get_image().save_png(path) == OK, "save " + label)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("SOLAR TEST: " + label)


func _frames(count := 3) -> void:
	for frame in count:
		await get_tree().physics_frame
	# A rendered frame can contain several physics ticks before proximity/audio _process.
	await get_tree().process_frame
	await get_tree().process_frame


func _tap(code: int, pad := false) -> void:
	for pressed in [true, false]:
		var event: InputEvent
		if pad:
			var button := InputEventJoypadButton.new()
			button.button_index = code
			button.pressed = pressed
			event = button
		else:
			var key := InputEventKey.new()
			key.physical_keycode = code
			key.keycode = code
			key.pressed = pressed
			event = key
		Input.parse_input_event(event)
		# Deliver this synthetic press/release before advancing a rendered-frame test.
		Input.flush_buffered_events()
		await get_tree().process_frame
		await get_tree().process_frame
		await _frames()


func _solution(state: SolarFieldState) -> Dictionary:
	var result := {}
	for route in state.field["routes"]:
		for index in route["mirrors"].size():
			var world := SolarOptics.point(route["mirrors"][index])
			var before := SolarOptics.point(route["source"] if index == 0 else route["mirrors"][index - 1])
			var after := SolarOptics.point(state.field["collector"]["world"] if index + 1 == route["mirrors"].size() else route["mirrors"][index + 1])
			result[route["id"] + str(index + 1)] = SolarOptics.alignment(world - before, after - world)
	return result


func _model() -> void:
	var state := SolarFieldState.new()
	_check(is_inf(SolarOptics.collector_distance(Vector3(-1010, 2020, 34), Vector3(1, 1, 0).normalized(), state.field["collector"])), "a ray missing the cone has no false linear intersection")
	var counts := [4, 5, 4] if OS.get_environment("SOLAR_FIELD_LAYOUT") == "v1" else [3, 3, 4]
	_check(state.mirrors.size() == counts[0] + counts[1] + counts[2], "authored reflector count")
	var center := SolarOptics.point(state.field["collector"]["world"])
	var hardware: Array[Vector2] = []
	for group in 3:
		var route: Dictionary = state.field["routes"][group]
		_check(route["mirrors"].size() == counts[group], route["id"] + " reflector count")
		hardware.append(SolarOptics.point(route["source"]))
		for pair in route["mirrors"]:
			var p := SolarOptics.point(pair)
			hardware.append(p)
	for index in hardware.size():
		_check(hardware[index].distance_to(center) > float(state.field["collector"]["radius"]) + 35.0, "equipment clears the receiver")
		for other in range(index + 1, hardware.size()):
			_check(hardware[index].distance_to(hardware[other]) >= 80.0, "equipment has room to breathe")
	for route in state.routes:
		_check(route["segments"].is_empty() and not route["connected"], "closed feed emits no random light")
	# A small geometric margin keeps the beam's drawn width/glow from grazing the surface.
	var receiver: Dictionary = state.field["collector"].duplicate()
	state.field["collector"]["radius"] += 4.0
	state.field["collector"]["top_radius"] += 4.0
	for group in 3:
		var shortcuts: Dictionary = RouteSearch.inspect(state, group)
		_check(shortcuts["witnesses"].is_empty(), "%s incomplete paths clear the receiver by four units across all mirror settings: %s" % [state.field["routes"][group]["id"], shortcuts["witnesses"]])
	state.field["collector"] = receiver
	var solution := _solution(state)
	for id in solution:
		while state.orientations[id] != solution[id]:
			state.rotate(id)
	_check(state.connected_count() == 0, "aligned reflectors alone cannot power closed feeds")
	for group in 3:
		state.toggle_feed(group)
		if OS.get_cmdline_user_args().has("--optics-debug"):
			print("OPTICS DEBUG ", group, " ", solution, " ", state.routes[group])
		_check(state.connected_count() == group + 1, "each feed energizes its full route")
		_check(state.routes[group]["hits"].size() == state.field["routes"][group]["mirrors"].size(), "authored solution uses its exact route")
		var route: Dictionary = state.field["routes"][group]
		for index in route["mirrors"].size():
			var p := SolarOptics.point(route["mirrors"][index])
			var target := Vector3(p.x, p.y, state.field["beam_height"] + SolarOptics.mirror_elevation(route, index))
			_check(state.routes[group]["segments"][index][1].distance_to(target) < .02, "beam meets the elevated mirror's physical center")
		for segment in state.routes[group]["segments"]:
			_check(segment[0].z >= segment[1].z - .01, "solved sunlight descends naturally toward the receiver")
	_check(state.supplies_power(), "three concentrated channels supply power")
	var downhill: Array = state.routes[2]["segments"]
	_check(downhill[0][0].z > downhill[0][1].z + 20.0, "mountain feed sends a descending beam to its first reflector")
	var last_blue: String = "B" + str(state.field["routes"][1]["mirrors"].size())
	for angle in 8:
		while state.orientations[last_blue] != angle:
			state.rotate(last_blue)
		_check(state.routes[1]["connected"] == (angle == solution[last_blue]), "last blue reflector orientation %d must be aligned" % angle)
	while state.orientations[last_blue] != solution[last_blue]:
		state.rotate(last_blue)
	for mirror in state.mirrors:
		var id: String = mirror["id"]
		for angle in 8:
			while state.orientations[id] != angle:
				state.rotate(id)
			for group in 3:
				if state.routes[group]["connected"]:
					for index in state.field["routes"][group]["mirrors"].size():
						_check(state.routes[group]["hits"].has(state.field["routes"][group]["id"] + str(index + 1)), "no incomplete route can count")
		while state.orientations[id] != solution[id]:
			state.rotate(id)
	state.toggle_feed(1)
	_check(state.connected_count() == 2 and state.routes[1]["segments"].is_empty(), "feed shutoff removes light and output immediately")
	_check(not state.toggle_feed(-1) and not state.rotate("unknown"), "invalid controls cannot mutate state")


func _integration() -> void:
	GameState.solar_field = SolarFieldState.new()
	GameState.heading = 0
	GameState.intro_done = true
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await _frames(6)
	var solar: SolarField = world.solar
	var state := GameState.solar_field
	var player: Player = world.player
	var solution := _solution(state)
	if not _gallery.is_empty():
		player.camera.set_level(2)
	var approach := 0
	for path in state.field["access_paths"]:
		player.teleport(SolarOptics.point(path["points"][0]))
		await _frames()
		for point in path["points"].slice(1):
			var destination := SolarOptics.point(point)
			for step in 600:
				var delta := destination - player.world_pos
				if delta.length() < 2.0:
					break
				var direction: Vector2 = world.terrain.view_dir(delta).normalized()
				player.forced_input = Vector2(direction.x, -direction.y)
				await get_tree().physics_frame
			player.forced_input = Vector2.ZERO
			await _frames()
			_check(player.world_pos.distance_to(destination) < 3.0 and not player.is_airborne(), "graded solar access can be walked without jumping")
		await _capture("hill-approach%d" % approach)
		approach += 1
	for id in solar.equipment:
		var point: Vector2 = solar.equipment[id]["world"]
		_check(world.terrain.surface(point) == MapTerrain.Surface.SOLID, id + " has a solid pedestal")
		var stand := solar.interaction_point(id)
		_check(world.terrain.is_walkable(stand), id + " has reachable interaction ground")
		var route: Dictionary = state.field["routes"][solar.equipment[id]["group"]]
		var elevation := float(route.get("source_elevation", 0.0)) if solar.equipment[id]["source"] else SolarOptics.mirror_elevation(route, int(id.substr(1)) - 1)
		_check(absf(world.terrain.height_at(stand) - elevation) < 1.0, id + " stands at its authored elevation")
	for group in 3:
		var id: String = state.field["routes"][group]["id"] + " SUN"
		player.teleport(solar.interaction_point(id))
		await _frames()
		_check(solar.nearest == id and world.multitool.solar_suppressed, "feed owns F without pausing")
		if group == 0:
			await _capture("feed-closed")
		await _tap(KEY_F)
		_check(state.feeds[group], "F activates nearby feed " + id)
		if group == 0:
			await _capture("crystal-rising", .15)
			await _capture("feed-active")
		if group == 2:
			await _capture("mountain-feed")
		_check(player.controls_enabled and not get_tree().paused, "world remains playable during feed operation")
	for mirror in state.mirrors:
		var id: String = mirror["id"]
		player.teleport(solar.interaction_point(id))
		await _frames()
		var initial: int = state.orientations[id]
		await _tap(KEY_Q)
		_check(state.orientations[id] == initial, "Q cannot rotate nearby " + id)
		for step in posmod(int(solution[id]) - int(state.orientations[id]), 8):
			var prior: int = state.orientations[id]
			await _tap(KEY_F)
			_check(state.orientations[id] == posmod(prior + 1, 8), "each F press turns nearby " + id)
	_check(state.supplies_power(), "real F inputs solve the whole field")
	for route in state.routes:
		var clearance := INF
		for segment in route["segments"]:
			var start: Vector3 = segment[0]
			var end: Vector3 = segment[1]
			var steps := ceili(start.distance_to(end) / 4.0)
			for step in steps + 1:
				var point := start.lerp(end, float(step) / steps)
				clearance = minf(clearance, point.z - world.terrain.height_at(Vector2(point.x, point.y)))
		_check(clearance > 3.0, "solved beam clears the reshaped terrain")
	if not _gallery.is_empty():
		player.teleport(SolarOptics.point(state.field["collector"]["world"]) + Vector2(-50, -50))
	await _capture("energize-rise", .15)
	await get_tree().create_timer(1.1).timeout
	_check(solar.fx.energy > .95, "three live routes energize the receiver")
	await _capture("energize-settled", 1.0)
	for group in 3:
		_check(solar.fx.deployment[group] == 1.0, "active feed fully raises its crystal")
	if not _gallery.is_empty():
		player.teleport(solar.interaction_point("C4"))
		await _frames()
	var slot := GameState.selected_slot
	var angle: int = state.orientations["C4"]
	await _tap(JOY_BUTTON_LEFT_SHOULDER, true)
	_check(GameState.selected_slot == (slot + 1) % GameState.HOTBAR_SIZE and state.orientations["C4"] == angle, "left shoulder cycles the hotbar without rotating a reflector")
	await _tap(JOY_BUTTON_X, true)
	_check(state.orientations["C4"] == posmod(angle + 1, 8), "gamepad X turns the reflector forward")
	for step in 7:
		await _tap(JOY_BUTTON_X, true)
	_check(state.supplies_power(), "gamepad X can finish the route")
	state.toggle_feed(0)
	await get_tree().create_timer(.9).timeout
	_check(solar.fx.deployment[0] == 0.0 and solar.fx.energy < .05, "closing a feed retracts its crystal and de-energizes the cone")
	state.toggle_feed(0)
	await get_tree().create_timer(1.1).timeout
	await _tap(KEY_E)
	angle = state.orientations["C4"]
	await _tap(KEY_F)
	_check(state.orientations["C4"] == angle, "backpack owns input over solar")
	await _tap(KEY_E)
	await _frames()
	if not _gallery.is_empty():
		player.teleport(SolarOptics.point(state.field["collector"]["world"]) + Vector2(-50, -50))
		player.camera.set_level(2)
		await _capture("solved-view0")
	var stored := state.orientations.duplicate()
	for heading in 4:
		world.view_turn.request(1)
		await get_tree().create_timer(1.0).timeout
		_check(not world.view_turn.busy, "camera swing finishes with optical geometry")
		_check(state.orientations == stored and state.supplies_power(), "camera changes only the drawing")
		for mirror in state.mirrors:
			var prop: WorldProp = solar.equipment[mirror["id"]]["prop"]
			_check(prop.position == world.terrain.to_screen(mirror["world"], mirror["elevation"]).round(), "equipment projection stays anchored in view %d" % heading)
			var expected: int = stored[mirror["id"]] if mirror["mount"] != Vector2.ZERO else posmod(int(stored[mirror["id"]]) - world.terrain.heading * 4, 8)
			_check(floori(float(prop.sprite.frame) / 4) == expected, "mirror angle rotates with view")
		for group in 3:
			var route: Dictionary = state.field["routes"][group]
			var prop: WorldProp = solar.equipment[route["id"] + " SUN"]["prop"]
			var sheet: Dictionary = solar._info["sheets"][route["id"]]["source"]
			var yaw := floori(float(prop.sprite.frame) / sheet["deploy_frames"]) * PI / 2 + float(sheet.get("yaw_offset", 0.0))
			var ray := SolarOptics.source_direction(state.field, group)
			var projected: Vector2 = world.terrain.view_dir(Vector2(ray.x, ray.y)).normalized()
			_check(Vector2.from_angle(yaw).dot(projected) > .9999, "beacon outlet follows its real ray in every view")
		_check(solar.fx.energy > .95 and solar.fx.startup > 1.0, "turn retains receiver charge without restarting completion")
		var indicator: Vector2 = world.terrain.to_screen(SolarOptics.point(state.field["collector"]["world"]), state.field["collector"]["height"] + 12).round()
		_check(solar._indicator.distance_to(indicator) < 1.0, "receiver indicator matches this view")
		await _capture("solved-view%d" % world.terrain.heading)
		if not _gallery.is_empty():
			# Frame the whole elevated field for evidence, using the generated sprite extents.
			player.camera.set_level(3)
			var frame := Rect2(solar._indicator, Vector2.ZERO)
			for entry in solar.equipment.values():
				var prop: WorldProp = entry["prop"]
				var rect := prop.sprite.get_rect()
				var origin := prop.position + prop.sprite.position
				frame = frame.expand(origin + rect.position).expand(origin + rect.end)
			player.camera.focus_override = frame.get_center()
			player.camera.snap_to(player.camera.focus_override)
			await _capture("layout-view%d" % world.terrain.heading)
			player.camera.focus_override = null
			player.camera.set_level(2)
			player.camera.snap()
	player.teleport(world.terrain.spawn)
	await _frames()
	angle = state.orientations["C4"]
	await _tap(KEY_F)
	_check(state.orientations["C4"] == angle and not world.multitool.solar_suppressed, "remote input never turns a reflector")
	world.queue_free()
	await _frames()
	_check(GameState.solar_field == state and state.supplies_power(), "scene teardown preserves solar routing")
	var base := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(base)
	await _frames(6)
	for machine in base.repairs.machines:
		if machine["id"] == "power":
			base.player.teleport(SolarOptics.point(machine["stand_world"]))
	if not _gallery.is_empty():
		await get_tree().create_timer(3.0).timeout
	await _capture("engine-needs-repair")
	_check(base.solar_input != null and not GameState.base_powered(), "damaged reactor cannot run on solar alone")
	_check(base.solar_input._lights.frame == 7, "wall lenses show all three connected channels")
	GameState.repair_for("power").complete_task("cracks")
	GameState.repair_for("power").complete_task("wiring")
	await _frames(6)
	_check(not GameState.base_powered(), "reactor and solar still need the oxygen machine")
	GameState.repair_for("oxygen").complete_task("cracks")
	_check(not GameState.base_powered(), "partial oxygen repair cannot restore full power")
	GameState.repair_for("oxygen").complete_task("wiring")
	await _frames(6)
	_check(GameState.base_powered(), "both restored machines and three solar inputs power the base")
	_check(Audio.is_looping("solar:engine"), "powered engine starts its existing machine sound")
	await _capture("engine-online")
	for heading in 4:
		base.view_turn.request(1)
		await get_tree().create_timer(1.0).timeout
		_check(not base.view_turn.busy and GameState.base_powered(), "engine remains powered through interior turn")
		var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(base.terrain.view_json))
		_check(base.solar_input._anchor == SolarOptics.point(meta["solar_input"]["anchor"]), "solar inlet stays on the wall in each view")
		await _capture("engine-view%d" % base.terrain.heading)
	if not _gallery.is_empty():
		base.player.camera.focus_override = base.solar_input._anchor + Vector2(0, 50)
		base.player.camera.snap_to(base.player.camera.focus_override)
		await _capture("engine-wall-lights")
	state.toggle_feed(1)
	_check(base.solar_input._lights.frame == 5, "only the Jade wall lens goes dark when its feed closes")
	_check(not GameState.base_powered(), "engine loses output when a sun feed is closed")
	await _frames()
	_check(not Audio.is_looping("solar:engine"), "lost input releases the engine sound")
	await _capture("engine-lost-input")
	state.toggle_feed(1)
	_check(GameState.base_powered(), "engine resumes when the complete feed returns")
	await _frames()
	_check(Audio.is_looping("solar:engine"), "restored input resumes the engine sound")
	base.queue_free()
	await _frames()
	_check(state.supplies_power(), "interior teardown retains the outdoor puzzle")
	_check(not Audio.is_looping("solar:engine"), "engine-room exit releases its positional sound")


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--gallery="):
			_gallery = argument.trim_prefix("--gallery=")
	if not _gallery.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_gallery.get_base_dir()))
	Audio.enter_scene()
	_model()
	if not OS.get_cmdline_user_args().has("--model-only"):
		await _integration()
	print("SOLAR TEST: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)
