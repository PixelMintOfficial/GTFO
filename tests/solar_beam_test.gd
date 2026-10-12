extends Node
## Beam regressions against the real field/map: all individual yaw settings, seeded mixed
## settings, first terrain contacts and escaped rays outside every view's visible envelope.
## Native mode compares mirror-face pixels in the real world and replays the production
## reflector layer with front/behind rays at the face, collar and post, all 320 poses.
## Actual uploaded mesh attributes and shifted depth-window shader fixtures guard precision.
## Real back-side reflections must not expose buried bounce vertices as face dots.
## --contact-probe isolates the reported Jade dot in a small native render.
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
var _contact_probe := false


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
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(3000, 0), Vector2(3000, 0), Vector2(3000, 0), Vector2(3000, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.mesh = ArrayMesh.new()
	mesh.mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var material := ShaderMaterial.new()
	material.shader = BEAM
	material.set_shader_parameter("map_win", Vector4(0, 0, 16, 16))
	material.set_shader_parameter("beam_color", Color("#4fc6b4"))
	mesh.material = material
	viewport.add_child(mesh)
	add_child(viewport)
	for empty_sky in [true, false]:
		var depth := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		depth.fill(Color(1, 1, 0) if empty_sky else Color(200.0 / 255.0, 0, 0))
		material.set_shader_parameter("depth_map", ImageTexture.create_from_image(depth))
		await _frames()
		await RenderingServer.frame_post_draw
		var pixel := viewport.get_texture().get_image().get_pixel(8, 8)
		_check(pixel.g > .6 if empty_sky else pixel.a < .01, "sky sentinel lets light pass" if empty_sky else "foreground solid depth still hides light")
	# Move the same mesh and window away from the map origin: sampling must stay local.
	mesh.position = Vector2(100, 200)
	viewport.canvas_transform = Transform2D(0, Vector2(-100, -200))
	material.set_shader_parameter("map_win", Vector4(100, 200, 16, 16))
	for empty_sky in [true, false]:
		var depth := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		depth.fill(Color(1, 1, 0) if empty_sky else Color(200.0 / 255.0, 0, 0))
		material.set_shader_parameter("depth_map", ImageTexture.create_from_image(depth))
		await _frames()
		await RenderingServer.frame_post_draw
		var pixel := viewport.get_texture().get_image().get_pixel(8, 8)
		_check(pixel.g > .6 if empty_sky else pixel.a < .01, "shifted depth window passes sky" if empty_sky else "shifted depth window hides light behind solid ground")
	material.set_shader_parameter("map_win", Vector4(100, 200, 2, 2))
	await _frames()
	await RenderingServer.frame_post_draw
	_check(viewport.get_texture().get_image().get_pixel(8, 8).g > .6, "rays outside the map do not collide with clamped edge pixels")
	viewport.queue_free()
	await _frames()


## Read the GPU-packed ArrayMesh attribute, rather than testing our encoding formula.
func _depth_attributes(terrain: MapTerrain) -> void:
	for heading in 4:
		terrain.load_view(heading)
		for y in [-2500.0, 1800.0, 1815.0, 1921.97, 2047.99, 2300.03, 9000.0]:
			var a := Vector3(-530, y, 68)
			var b := a + Vector3(50, 12.8, -10)
			var mesh := SolarBeamVisuals.mesh(terrain, [[a, b]], 2.25)
			var depths: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
			for index in [0, 2]:
				var point := a if index == 0 else b
				var actual := depths[index].x
				var expected := terrain.view_depth(Vector2(point.x, point.y))
				_check(absf(actual - expected) < .027, "uploaded ray depth stays within map precision, view%d Y%.2f" % [heading, y])
## Isolate only scenery occlusion with empty sky; reflector art, beam meshes and its
## real production overlay are unchanged. +/-40 view units bracket the entire hardware.
func _reflectors(terrain: MapTerrain) -> void:
	var state := SolarFieldState.new()
	var solution := _solution(state)
	state.orientations = solution.duplicate()
	state.feeds.fill(true)
	state._evaluate()
	var art: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SolarField.ART))
	var viewport := SubViewport.new()
	viewport.size = Vector2i(192, 160)
	viewport.world_2d = World2D.new()
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var base := MeshInstance2D.new()
	var material := ShaderMaterial.new()
	material.shader = BEAM
	MapStream.bind(material, terrain)
	material.set_shader_parameter("depth_scale", terrain.depth_scale)
	material.set_shader_parameter("beam_color", Color("#4fc6b4"))
	base.material = material
	base.set_meta("group", 0)
	base.set_meta("dn_unlit", true)
	viewport.add_child(base)
	var camera := Camera2D.new()
	viewport.add_child(camera)
	add_child(viewport)
	var sky := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	sky.fill(Color(1, 1, 0))
	var sky_texture := ImageTexture.create_from_image(sky)
	for heading in 4:
		if _contact_probe and heading != 0: continue
		terrain.load_view(heading)
		for mirror in state.mirrors:
			var id: String = mirror["id"]
			if _contact_probe and id != "B1": continue
			var group: int = mirror["group"]
			var sheet: Dictionary = art["special_mirrors"][id][heading] if art["special_mirrors"].has(id) else art["sheets"][state.field["routes"][group]["id"]]["mirror"]
			var prop := WorldProp.new()
			prop.setup({"tex": load(SolarField.ART.get_base_dir().path_join(sheet["file"])), "frames": sheet["frames"], "anchor": SolarOptics.point(sheet["anchor"])}, 0, terrain)
			(prop.sprite.material as ShaderMaterial).set_shader_parameter("depth_map", sky_texture)
			(prop.sprite.material as ShaderMaterial).set_shader_parameter("map_win", Vector4(0, 0, 1, 1))
			viewport.add_child(prop)
			prop.place(mirror["world"])
			camera.position = prop.position + Vector2(0, -50)
			camera.reset_smoothing()
			var overlay := SolarReflectorLight.new()
			prop.add_child(overlay)
			var beams: Array[MeshInstance2D] = [base]
			base.set_meta("group", group)
			overlay.setup(terrain, prop, sheet, beams, state, mirror)
			(base.material as ShaderMaterial).set_shader_parameter("depth_map", sky_texture)
			(base.material as ShaderMaterial).set_shader_parameter("map_win", Vector4(0, 0, 1, 1))
			(overlay.meshes[0].material as ShaderMaterial).set_shader_parameter("depth_map", sky_texture)
			(overlay.meshes[0].material as ShaderMaterial).set_shader_parameter("map_win", Vector4(0, 0, 1, 1))
			var atlas := (load(SolarField.ART.get_base_dir().path_join(sheet["depth"]["file"])) as Texture2D).get_image()
			for angle in 8:
				if _contact_probe and angle != solution[id]: continue
				state.orientations[id] = angle
				state._evaluate()
				var frame: int = angle if art["special_mirrors"].has(id) else posmod(angle - heading * 4, 8)
				prop.sprite.frame = frame * int(sheet["shine_frames"])
				base.visible = false
				overlay.visible = false
				await _frames()
				await RenderingServer.frame_post_draw
				var dark := viewport.get_texture().get_image()
				for in_front in [true, false]:
					var segments := []
					var center := SolarOptics.mirror_center(state.field, mirror)
					var viewed := terrain.view_point(Vector2(center.x, center.y))
					var offset := -40.0 if in_front else 40.0
					for height in [center.z, center.z - 12, center.z - 26]:
						var a := terrain.world_point(viewed + Vector2(-36, offset))
						var b := terrain.world_point(viewed + Vector2(36, offset))
						segments.append([Vector3(a.x, a.y, height - offset * terrain.depth_to_px), Vector3(b.x, b.y, height - offset * terrain.depth_to_px)])
					base.mesh = SolarBeamVisuals.mesh(terrain, segments, 2.25)
					overlay.refresh()
					base.visible = true
					overlay.visible = true
					await _frames()
					await RenderingServer.frame_post_draw
					var lit := viewport.get_texture().get_image()
					var wrong := 0
					var sampled := 0
					var transform := viewport.get_canvas_transform()
					for height in [center.z, center.z - 12, center.z - 26]:
						var row := floori((transform * terrain.to_screen(mirror["world"], height)).y)
						for x in range(15, viewport.size.x - 15):
							var map_pixel := transform.affine_inverse() * Vector2(x + .5, row + .5)
							var local := (map_pixel - prop.position - prop.sprite.offset).floor()
							if local.x < 0 or local.y < 0 or local.x >= sheet["size"][0] or local.y >= sheet["size"][1]: continue
							if atlas.get_pixel(int(local.x) + frame * int(sheet["size"][0]), int(local.y)).a < .5: continue
							sampled += 1
							var before := dark.get_pixel(x, row)
							var after := lit.get_pixel(x, row)
							var changed := absf(before.r - after.r) + absf(before.g - after.g) + absf(before.b - after.b) > .12
							if changed != in_front: wrong += 1
					_check(sampled > 5 and wrong == 0, "%s yaw%d view%d %s reflector (wrong %d/%d)" % [id, angle, heading, "in front of" if in_front else "behind", wrong, sampled])
				# A real back-side reflection must not expose its buried optical vertex as
				# an isolated dot in the visible face. This is the owner's reported fixture.
				var route: Dictionary = state.routes[group]
				var hit: int = route["hits"].find(id)
				if hit >= 0 and hit + 1 < route["segments"].size():
					var normal := SolarOptics.mirror_normal(mirror, angle)
					var toward_xy := terrain.world_dir(Vector2(0, -1))
					var toward := Vector3(toward_xy.x, toward_xy.y, terrain.depth_to_px)
					var incoming: Vector3 = route["segments"][hit][1] - route["segments"][hit][0]
					if incoming.dot(normal) * toward.dot(normal) > .01:
						base.visible = false
						overlay.visible = false
						await _frames()
						await RenderingServer.frame_post_draw
						var before := viewport.get_texture().get_image()
						base.mesh = SolarBeamVisuals.mesh(terrain, route["segments"], 2.25)
						overlay.refresh()
						base.visible = true
						overlay.visible = true
						await _frames()
						await RenderingServer.frame_post_draw
						var after := viewport.get_texture().get_image()
						var vertex: Vector3 = route["segments"][hit][1]
						var pixel := viewport.get_canvas_transform() * terrain.to_screen(Vector2(vertex.x, vertex.y), vertex.z)
						var dots := 0
						for y in range(roundi(pixel.y) - 2, roundi(pixel.y) + 3):
							for x in range(roundi(pixel.x) - 2, roundi(pixel.x) + 3):
								var map_pixel := viewport.get_canvas_transform().affine_inverse() * Vector2(x + .5, y + .5)
								var local := (map_pixel - prop.position - prop.sprite.offset).floor()
								if local.x < 0 or local.y < 0 or local.x >= sheet["size"][0] or local.y >= sheet["size"][1]: continue
								var surface := atlas.get_pixel(int(local.x) + frame * int(sheet["size"][0]), int(local.y))
								if surface.a < .5 or surface.b < .001: continue
								var a := after.get_pixel(x, y)
								var b := before.get_pixel(x, y)
								if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > .12: dots += 1
						_check(dots == 0, "%s yaw%d view%d back-side bounce has no ghost dot (%d pixels)" % [id, angle, heading, dots])
			state.orientations[id] = solution[id]
			prop.queue_free()
			await _frames()
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
		# A fixed frame count can leave the zoom tween running on a faster build.
		# Compare the same screen pixels only once zoom and its depth window have settled.
		await get_tree().create_timer(world.player.camera.zoom_time + .05).timeout
		world.stream.refresh(true)
		for group in 3:
			state.toggle_feed(group)
		await _frames()
		await RenderingServer.frame_post_draw
		var dark := get_viewport().get_texture().get_image()
		var dark_transform := get_viewport().get_canvas_transform()
		for group in 3:
			state.toggle_feed(group)
		await _frames()
		await RenderingServer.frame_post_draw
		var lit := get_viewport().get_texture().get_image()
		_check(get_viewport().get_canvas_transform() == dark_transform, "contact pixel comparison uses a settled camera in view %d" % heading)
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
		var normal := SolarOptics.mirror_normal(mirror, state.orientations["C1"])
		var toward_xy: Vector2 = world.terrain.world_dir(Vector2(0, -1))
		var toward := Vector3(toward_xy.x, toward_xy.y, world.terrain.depth_to_px)
		var incoming: Vector3 = state.routes[2]["segments"][0][1] - state.routes[2]["segments"][0][0]
		var front := incoming.dot(normal) * toward.dot(normal) < 0
		_check(changed >= 4 if DayNight.daylight > .5 and front else changed == 0, "mirror contact respects incident side/sunlight in view %d (%d pixels)" % [heading, changed])
		await _capture("mirror-view%d" % heading)
		if not _gallery.is_empty():
			for target in ["B2", "B3", "A2"]:
				world.player.teleport(world.solar.interaction_point(target))
				world.player.camera.snap_to(world.player.position)
				await _capture("%s-view%d" % [target, heading])
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
		_contact_probe = _contact_probe or argument == "--contact-probe"
	if not _gallery.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_gallery.get_base_dir()))
	Audio.enter_scene()
	var terrain := MapTerrain.new(MAP)
	if _contact_probe:
		await _reflectors(terrain)
		print("BEAM CONTACT PROBE: %d checks, %d failures" % [_checks, _failures])
		await Audio.quit(1 if _failures else 0)
		return
	for path in terrain.views:
		_views.append(JSON.parse_string(FileAccess.get_file_as_string(path)))
	_grid_size = _views[0]["game"]["grid_size"]
	_model(terrain)
	_depth_attributes(terrain)
	if DisplayServer.get_name() != "headless":
		await _native()
		await _reflectors(terrain)
	print("BEAM TEST: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)
