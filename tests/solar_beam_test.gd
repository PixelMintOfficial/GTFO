extends Node
## Beam regressions against the real field/map: all individual yaw settings, seeded mixed
## settings, first terrain contacts and escaped rays outside every view's visible envelope.
## Native mode also compares mirror-face pixels with feeds off/on through all four views,
## and renders the production shader against empty-sky/opaque-depth fixtures.
## godot --headless --path . res://tests/solar_beam_test.tscn
## For visual evidence omit --headless and append -- --gallery=shots/beams --time=12|22.

const MAP := "res://assets/maps/red_planet/red_planet_map.json"
const BEAM := preload("res://shaders/solar_beam.gdshader")
var _checks := 0
var _failures := 0
var _gallery := ""
var _views: Array[Dictionary] = []
var _grid_size := 0.0
var _hill_angle := -1
var _hill_distance := INF
var _escape_angle := -1


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("BEAM TEST: " + label)


func _frames() -> void:
	for frame in 3:
		await get_tree().process_frame


func _capture(label: String) -> void:
	if _gallery.is_empty():
		return
	await get_tree().create_timer(.2).timeout
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(_gallery + "-" + label + ".png") == OK, "save " + label)


func _solution(state: SolarFieldState) -> Dictionary:
	var result := {}
	for mirror in state.mirrors:
		var route: Dictionary = state.field["routes"][mirror["group"]]
		var i: int = mirror["index"]
		var p: Vector2 = mirror["world"]
		var before := SolarOptics.point(route["source"] if i == 0 else route["mirrors"][i - 1])
		var after := SolarOptics.point(state.field["collector"]["world"] if i + 1 == route["mirrors"].size() else route["mirrors"][i + 1])
		result[mirror["id"]] = SolarOptics.alignment(p - before, after - p)
	return result


func _contains_ground(p: Vector3) -> bool:
	var grid := Vector2(p.x + p.y, p.y - p.x) / sqrt(2.0)
	return grid.x >= 0 and grid.y >= 0 and grid.x <= _grid_size and grid.y <= _grid_size


func _outside_views(p: Vector3, terrain: MapTerrain) -> bool:
	for view in _views:
		var xy := Vector2(p.x, p.y) - terrain.view_center
		match int(view["game"]["heading"]):
			1: xy = Vector2(xy.y, -xy.x)
			2: xy = -xy
			3: xy = Vector2(-xy.y, xy.x)
		xy += terrain.view_center
		var pixel := Vector2(view["origin_px"][0] + xy.x / terrain.units_per_px,
				view["origin_px"][1] - (xy.y * terrain.depth_to_px + p.z) * terrain.px_per_unit)
		var margin := Vector2(view["zoom"]["max_view_px"][0], view["zoom"]["max_view_px"][1])
		var size := Vector2(view["size"][0], view["size"][1])
		if Rect2(-margin, size + margin * 2).grow(-.1).has_point(pixel):
			return false
	return true


func _check_route(route: Dictionary, terrain: MapTerrain, label: String) -> void:
	for segment in route["segments"]:
		var a: Vector3 = segment[0]
		var b: Vector3 = segment[1]
		var clear := true
		var steps := maxi(ceili(a.distance_to(b)), 1)
		for step in range(1, steps):
			var p := a.lerp(b, float(step) / steps)
			if _contains_ground(p) and terrain.height_at(Vector2(p.x, p.y)) > p.z + .12:
				clear = false
				break
		_check(clear, label + " never continues inside terrain")
	if route["segments"].is_empty():
		return
	var end: Vector3 = route["segments"][-1][1]
	if route["termination"] == "terrain":
		_check(absf(end.z - terrain.height_at(Vector2(end.x, end.y))) < .12, label + " ends on the actual terrain surface")
	elif route["termination"] == "escape":
		_check(_outside_views(end, terrain), label + " escapes beyond all four visible maps")


func _model(terrain: MapTerrain) -> void:
	var state := SolarFieldState.new()
	var solution := _solution(state)
	state.orientations = solution.duplicate()
	state.feeds.fill(true)
	state.bind_world(terrain)
	_check(state.connected_count() == 3, "terrain collisions preserve all authored solutions")
	_check(is_equal_approx(SolarWorldGeometry._root(1, -1, 1), (1 - sqrt(.5)) / 2), "narrow ridge is hit even when both cell ends are clear")
	_check(is_equal_approx(SolarWorldGeometry._root(1, 0, 1), .5), "grazing ray touches the ridge")
	_check(is_inf(SolarWorldGeometry._root(1, 1, 1)), "level ray above flat ground has no false surface hit")
	var sightline := Vector3(0, -1, terrain.depth_to_px).normalized()
	var geometry := SolarWorldGeometry.new(terrain)
	_check(is_finite(geometry.escape_distance(Vector3(-530, 1800, 68), sightline)), "a ray along one camera sightline retains its length for the other views")
	for mirror in state.mirrors:
		for angle in 8:
			state.orientations[mirror["id"]] = angle
			state._evaluate()
			for group in 3:
				_check_route(state.routes[group], terrain, "%s angle %d channel %d" % [mirror["id"], angle, group])
			if mirror["id"] == "B1" and angle != solution["B1"] and state.routes[1]["termination"] == "terrain" and not state.routes[1]["hits"].is_empty() and state.routes[1]["hits"][-1] == "B1":
				var segment: Array = state.routes[1]["segments"][-1]
				var length := (segment[0] as Vector3).distance_to(segment[1])
				if length < _hill_distance:
					_hill_angle = angle
					_hill_distance = length
			if mirror["id"] == "A1" and state.routes[0]["termination"] == "escape":
				_escape_angle = angle
		state.orientations[mirror["id"]] = solution[mirror["id"]]
	var random := RandomNumberGenerator.new()
	random.seed = 20261012
	for pose in 64:
		for id in solution:
			state.orientations[id] = random.randi_range(0, 7)
		state._evaluate()
		for group in 3:
			_check_route(state.routes[group], terrain, "mixed pose %d channel %d" % [pose, group])
	_check(_hill_angle >= 0, "real B1 terrain-hit fixture exists")
	_check(_escape_angle >= 0, "real escaping ray fixture exists")
	# First reported terrain penetration and the old field-boundary cutoff, as exact fixtures.
	for angle in [1, 2]:
		state.orientations = solution.duplicate()
		state.orientations["A1"] = angle
		state._evaluate()
		_check_route(state.routes[0], terrain, "reported Amber fixture %d" % angle)
		if angle == 1:
			_check(state.routes[0]["termination"] == "terrain", "reported penetration stops at the cliff")
		else:
			var segment: Array = state.routes[0]["segments"][-1]
			var start: Vector3 = segment[0]
			var end: Vector3 = segment[1]
			var box: Array = state.field["bounds"]
			var old_limit := SolarOptics.edge_distance(start, (end - start).normalized(), Rect2(box[0], box[1], box[2], box[3]))
			_check(start.distance_to(end) > old_limit + 5, "reported mid-air cutoff continues past the old boundary until a real distant hill")


func _shader() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(16, 16)
	viewport.world_2d = World2D.new()
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var mesh := MeshInstance2D.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(2, 7, 0), Vector3(14, 7, 0), Vector3(14, 10, 0), Vector3(2, 10, 0)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color(1, 0, 0), Color(1, 0, 0), Color(1, 0, 0), Color(1, 0, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.mesh = ArrayMesh.new()
	mesh.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	material.shader = BEAM
	material.set_shader_parameter("map_size", Vector2(16, 16))
	material.set_shader_parameter("beam_color", Color("#4fc6b4"))
	mesh.material = material
	viewport.add_child(mesh)
	add_child(viewport)
	for empty_sky in [true, false]:
		var depth := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		depth.fill(Color(1, 1, 0) if empty_sky else Color(200.0 / 255.0, 0, 0))
		material.set_shader_parameter("depth_map", ImageTexture.create_from_image(depth))
		await _frames()
		await RenderingServer.frame_post_draw
		var pixel := viewport.get_texture().get_image().get_pixel(8, 8)
		_check(pixel.g > .6 if empty_sky else pixel.a < .01, "sky sentinel lets light pass" if empty_sky else "foreground solid depth still hides light")
	material.set_shader_parameter("map_size", Vector2(2, 2))
	await _frames()
	await RenderingServer.frame_post_draw
	_check(viewport.get_texture().get_image().get_pixel(8, 8).g > .6, "rays outside the map do not collide with clamped edge pixels")
	viewport.queue_free()
	await _frames()


func _native() -> void:
	GameState.solar_field = SolarFieldState.new()
	var state := GameState.solar_field
	var solution := _solution(state)
	state.orientations = solution.duplicate()
	state.feeds.fill(true)
	state._evaluate()
	GameState.heading = 0
	GameState.intro_done = true
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await _frames()
	world.solar.fx.set_process(false)
	world.player.camera.set_process(false)
	for heading in 4:
		world._apply_view(heading, Vector2.RIGHT)
		world.player.teleport(world.solar.interaction_point("C1"))
		world.player.camera.set_level(1)
		world.player.camera.snap_to(world.player.position)
		for group in 3:
			state.toggle_feed(group)
		await _frames()
		await RenderingServer.frame_post_draw
		var dark := get_viewport().get_texture().get_image()
		for group in 3:
			state.toggle_feed(group)
		await _frames()
		await RenderingServer.frame_post_draw
		var lit := get_viewport().get_texture().get_image()
		var mirror: Dictionary = state.mirrors.filter(func(m): return m["id"] == "C1")[0]
		var center := SolarOptics.mirror_center(state.field, mirror)
		var pixel: Vector2 = get_viewport().get_stretch_transform() * (get_viewport().get_canvas_transform() * world.terrain.to_screen(Vector2(center.x, center.y), center.z))
		var changed := 0
		for y in range(roundi(pixel.y) - 3, roundi(pixel.y) + 4):
			for x in range(roundi(pixel.x) - 3, roundi(pixel.x) + 4):
				var a := lit.get_pixel(x, y)
				var b := dark.get_pixel(x, y)
				if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > .12:
					changed += 1
		_check(changed >= 4 if DayNight.daylight > .5 else changed == 0, "mirror contact follows sunlight in view %d (%d pixels)" % [heading, changed])
		await _capture("mirror-view%d" % heading)
	for heading in [0, 2]:
		world._apply_view(heading, Vector2.RIGHT)
		world.player.teleport(world.solar.interaction_point("B1"))
		world.player.camera.snap_to(world.player.position)
		state.orientations["B1"] = _hill_angle
		state._evaluate()
		state.changed.emit()
		await _capture("hill-stop-view%d" % heading)
	state.orientations = solution.duplicate()
	state.orientations["A1"] = _escape_angle
	state._evaluate()
	state.changed.emit()
	world._apply_view(0, Vector2.RIGHT)
	world.player.teleport(world.solar.interaction_point("A1"))
	world.player.camera.set_level(2)
	world.player.camera.snap_to(world.player.position)
	await _capture("escape")
	state.orientations["A1"] = 1
	state._evaluate()
	state.changed.emit()
	world.player.teleport(world.solar.interaction_point("C4"))
	world.player.camera.snap_to(world.player.position)
	await _capture("cliff-stop")
	world.queue_free()
	await _frames()
	await _shader()


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--gallery="):
			_gallery = argument.trim_prefix("--gallery=")
	if not _gallery.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_gallery.get_base_dir()))
	Audio.enter_scene()
	var terrain := MapTerrain.new(MAP)
	for path in terrain.views:
		_views.append(JSON.parse_string(FileAccess.get_file_as_string(path)))
	_grid_size = _views[0]["game"]["grid_size"]
	_model(terrain)
	if DisplayServer.get_name() != "headless":
		await _native()
	print("BEAM TEST: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)
