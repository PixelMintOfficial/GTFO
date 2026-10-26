extends Node
## Full-power prerequisite combinations/order, live loss/restoration, midnight/noon,
## streaming, four actual camera swings and interior/exterior/nursery transitions.
## Run headless for assertions, or -- --gallery=shots/base-power for native evidence.
## Prerequisites use the real repair transaction and real solar rotations/feeds.
## Broken storage glass keeps daylight by day, but no baked beam-shaped darkness at night.
## All storage glass repairs restore all six exterior holes; window spill and patches
## follow all four actual camera swings, with the planet beyond the base staying dark.

var _checks := 0
var _failures := 0
var _gallery := ""


func _check(value: bool, label: String) -> void:
	_checks += 1
	if not value:
		_failures += 1
		push_error("BASE POWER: " + label)


func _frames(count := 5) -> void:
	for i in count:
		await get_tree().process_frame


func _repair(id: String) -> void:
	GameState.repair_for(id).complete_task("cracks")
	GameState.repair_for(id).complete_task("wiring")


func _solar() -> void:
	var state := GameState.solar_field
	for route in state.field["routes"]:
		for i in route["mirrors"].size():
			var at := SolarOptics.point(route["mirrors"][i])
			var before := SolarOptics.point(route["source"] if i == 0 else route["mirrors"][i-1])
			var after := SolarOptics.point(state.field["collector"]["world"] if i+1 == route["mirrors"].size() else route["mirrors"][i+1])
			var target := SolarOptics.alignment(at-before, after-at)
			var id: String = route["id"] + str(i+1)
			for step in posmod(target - int(state.orientations[id]), 8):
				state.rotate(id)
	for group in 3:
		if not state.feeds[group]:
			state.toggle_feed(group)


func _scene(path: String) -> Node2D:
	var scene := load(path).instantiate() as Node2D
	get_tree().root.add_child.call_deferred(scene)
	await _frames(10)
	scene.day_night.speed = 0.0
	return scene


func _shot(scene: Node2D, label: String) -> void:
	if _gallery.is_empty():
		return
	# Let room toasts settle and make streaming finish before reading the viewport.
	await get_tree().create_timer(3.0).timeout
	scene.stream.refresh(true)
	var hidden: Array[CanvasLayer] = []
	for child in scene.get_children():
		if child is InventoryUI or child is SurvivalHUD:
			hidden.append(child)
			child.visible = false
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(_gallery.path_join(label + ".png")) == OK, "capture " + label)
	for child in hidden:
		child.visible = true


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--gallery="):
			_gallery = arg.trim_prefix("--gallery=")
	if not _gallery.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_gallery))
	Audio.enter_scene()
	# Every combination, including both possible final machine repairs and solar last.
	for mask in 8:
		GameState.machine_repairs.clear()
		GameState.solar_field = SolarFieldState.new()
		if mask & 1:
			_repair("power")
		if mask & 2:
			_repair("oxygen")
		if mask & 4:
			_solar()
		_check(GameState.base_powered() == (mask == 7), "prerequisites combination %d" % mask)
	GameState.machine_repairs.clear()
	GameState.story.skip_intro()
	GameState.intro_done = true
	GameState.suit_light = false
	GameState.clock = 22.0
	GameState.heading = 0
	var world := await _scene("res://scenes/overworld.tscn")
	world.player.camera.set_level(3)
	world.player.camera.focus_override = SolarOptics.point(ViewData.get_json(world.terrain.view_json)["domes"]["base"]["center_px"]) + Vector2(0, -180)
	world.player.camera.snap_to(world.player.camera.focus_override)
	world.stream.refresh(true)
	_check(not BasePower.active, "solar alone leaves the base dark")
	await _shot(world, "outside-incomplete-night")
	_repair("power")
	await _frames()
	_check(not BasePower.active, "reactor plus solar still dark")
	GameState.repair_for("oxygen").complete_task("cracks")
	await _frames()
	_check(not BasePower.active, "partial O2 still dark")
	GameState.repair_for("oxygen").complete_task("wiring")
	await _frames()
	_check(BasePower.active, "last repair turns base lights on live")
	_check(not GameState.suit_light, "restoring the base never switches the suit lamp")
	await _shot(world, "outside-powered-night")
	GameState.window_repair.debug_complete(true, ViewData.get_json("res://assets/maps/base_interior/base_interior.json"))
	await _frames()
	_check(world.dome_fx._glass.size() == 6, "all three base domes mend immediately")
	await _shot(world, "outside-mended-night")
	for hour in [0.0, 5.0, 12.0, 18.0, 22.0]:
		GameState.clock = hour
		await _frames()
		_check(BasePower.active, "power independent of hour %.0f" % hour)
	GameState.clock = 12.0
	await _frames()
	await _shot(world, "outside-powered-day")
	world.player.camera.focus_override = null
	world.player.camera.set_level(2)
	GameState.clock = 22.0
	for i in 4:
		world.view_turn.request(1)
		await get_tree().create_timer(1.2).timeout
		_check(not world.view_turn.busy and BasePower.active, "powered exterior turn %d" % i)
		_check(BasePower.current["rect"] == BasePower.view_data(world.terrain)["rect"], "correct view mask %d" % i)
		var holes: Array = ViewData.fx_of(world.terrain.view_json, ViewData.get_json(world.terrain.view_json))["cracks"]
		_check(world.dome_fx._glass.size() == holes.size(), "all visible repaired holes follow exterior turn %d" % i)
		if not _gallery.is_empty():
			world.player.camera.set_level(3)
			world.player.camera.focus_override = SolarOptics.point(ViewData.get_json(world.terrain.view_json)["domes"]["base"]["center_px"]) + Vector2(0, -180)
			world.player.camera.snap_to(world.player.camera.focus_override)
		await _shot(world, "outside-view-%d" % world.terrain.heading)
		if not _gallery.is_empty() and world.terrain.heading == 1:
			GameState.solar_field.toggle_feed(0)
			await _frames()
			await _shot(world, "outside-view-1-unpowered")
			GameState.solar_field.toggle_feed(0)
			await _frames()
	world.player.camera.focus_override = null
	GameState.window_repair.debug_complete(false, ViewData.get_json("res://assets/maps/base_interior/base_interior.json"))
	await _frames()
	_check(world.dome_fx._glass.is_empty(), "reset reopens all six holes immediately")
	world.player.teleport(SolarOptics.point(GameState.solar_field.field["collector"]["world"]))
	world.stream.refresh(true)
	await _frames()
	_check(BasePower.light_at(BasePower.current, world.player.global_position) == 0.0, "collector terrain stays naturally dark")
	GameState.solar_field.toggle_feed(0)
	await _frames()
	_check(not BasePower.active, "lost solar route removes full lights live")
	GameState.solar_field.toggle_feed(0)
	await _frames()
	_check(BasePower.active, "restored solar route relights base")
	world.queue_free()
	await _frames()
	_check(not BasePower.active, "scene exit clears shader publication")
	var base := await _scene("res://scenes/interior.tscn")
	_check(BasePower.active and BasePower.current["indoor"] == 1.0, "airlock arrival reads full power")
	_check(base.fx._reserve.visible and base.fx._reserve.modulate.a == 1.0, "full-power strips steady")
	_check(GameState.window_repair.fixed.is_empty(), "powered-night case leaves all glass broken")
	_check(base.terrain.no_sun_map != null and base.day_night._map_mat.get_shader_parameter("has_no_sun"), "night uses the sunlight-free room")
	await _shot(base, "inside-powered-night")
	GameState.clock = 12.0
	await _frames()
	_check(DayNight.night == 0.0 and base.fx._shafts.size() == 2, "unrepaired windows retain daytime sunlight")
	await _shot(base, "inside-powered-day")
	GameState.clock = 22.0
	base.player.teleport(base.terrain.spawn)
	await _frames()
	for id in ["power", "oxygen"]:
		var room: Dictionary = ViewData.get_json(base.terrain.view_json)["rooms"][id]
		base.player.teleport(SolarOptics.point(room["center"]))
		await _frames()
		await _shot(base, "inside-" + id + "-night")
	for i in 4:
		base.player.teleport(base.terrain.spawn)
		base.view_turn.request(1)
		await get_tree().create_timer(1.2).timeout
		_check(not base.view_turn.busy and BasePower.active, "powered interior turn %d" % i)
		_check(base.day_night._map_mat.get_shader_parameter("has_no_sun"), "sunlight-free room follows turn %d" % i)
		await _shot(base, "inside-view-%d" % base.terrain.heading)
	GameState.solar_field.toggle_feed(1)
	await _frames()
	_check(not BasePower.active and base.fx._reserve.visible, "loss returns to independent bot reserve")
	await _shot(base, "inside-reserve-night")
	GameState.solar_field.toggle_feed(1)
	await _frames()
	_check(BasePower.active, "interior relights when source returns")
	base.queue_free()
	await _frames()
	var nursery := await _scene("res://scenes/nursery.tscn")
	_check(not BasePower.active, "base lighting does not leak into nursery")
	nursery.queue_free()
	await _frames()
	world = await _scene("res://scenes/overworld.tscn")
	_check(BasePower.active, "full power persists on return outside")
	world.queue_free()
	await _frames()
	print("BASE POWER TEST: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)
