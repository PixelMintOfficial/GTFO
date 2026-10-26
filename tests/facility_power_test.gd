extends Node
## Real facility power regression: access unlock cannot light rooms; O2 reserve cannot
## light rooms; depleted reserve stops indoor refill; base mains and nursery console light
## their own rooms day AND night, independently of the shared oxygen supply.
var checks := 0
var failures := 0
var output := ""

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FACILITY POWER TEST: " + label)

func frames() -> void:
	for i in 4: await get_tree().process_frame

func capture(label: String) -> void:
	if output.is_empty(): return
	await frames()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(output.path_join(label + ".png"))
	await frames()


func capture_meter(room: Node, label: String) -> void:
	if output.is_empty(): return
	var center: Array = ViewData.get_json(room.terrain.view_json)["reserve_meter"]["world"]
	var focus: Vector2 = room.terrain.to_screen(Vector2(center[0],center[1]),float(center[2]))
	room.player.camera.focus_override = focus
	room.player.camera.snap_to(focus)
	await capture(label)
	room.player.camera.release_focus()

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
			DirAccess.make_dir_recursive_absolute(output)
	GameState.intro_done = true
	GameState.heading = 0
	GameState.clock = 12.
	GameState.story = StoryState.new()
	GameState.story.skip_intro()
	GameState.machine_repairs.clear()
	GameState.solar_field = SolarFieldState.new()
	GameState.window_repair = WindowRepair.new()
	GameState.facility_air.reset()
	for pane in ["burst", "crescent", "gash"]: GameState.window_repair.fix(pane)
	var room: Node = load("res://scenes/interior.tscn").instantiate()
	get_tree().root.add_child.call_deferred(room)
	await frames()
	room.day_night.speed = 0.
	var hud: SurvivalHUD
	for node in room.get_children():
		if node is SurvivalHUD: hud = node
	check(not room.fx._reserve.visible, "unlocking access does not power the base lights")
	check(DayNight.light_mul.r < .4, "unpowered rooms remain dim at noon")
	check(not hud.oxygen_counter.visible, "reserve counter hidden before O2 repair")
	check(not room.reserve_meter.readout.visible, "wall reserve readout is dark before O2 repair")
	await capture("base-unpowered-noon")
	room.suit_light.toggle()
	await frames()
	check(DayNight.darkness == 1. and room.suit_light.lamp_vector().w > .5, "suit lamp lights an unpowered room at noon")
	await capture("base-suit-lamp-noon")
	room.suit_light.toggle()
	GameState.repair_for("oxygen").complete_task("cracks")
	GameState.repair_for("oxygen").complete_task("wiring")
	await frames()
	check(GameState.facility_air.status() == "reserve" and room.player.can_breathe(), "reserve powers repaired sealed O2")
	check(not room.fx._reserve.visible, "O2 reserve cannot power facility lights")
	check(hud.oxygen_counter.visible, "reserve counter appears after O2 repair")
	GameState.clock += 12.
	await frames()
	check(is_equal_approx(GameState.facility_air.reserve_fraction(), .5), "battery gauge shows remaining reserve")
	check(room.reserve_meter.readout.visible and room.reserve_meter.readout.frame == 5, "physical wall reserve meter shows half charge")
	for heading in 4:
		room._apply_view(heading,room.player.facing_dir())
		await frames()
		check(room.reserve_meter.readout.visible and room.reserve_meter.readout.frame == 5, "physical meter retains charge in view %d" % heading)
		check(float(ViewData.get_json(room.terrain.view_json)["reserve_meter"]["clear_fraction"]) >= .98,"tank cannot cover physical readout in view %d" % heading)
		await capture_meter(room,"oxygen-wall-reserve-view-%d" % heading)
	room._apply_view(0,room.player.facing_dir())
	await capture("base-o2-reserve-half")
	GameState.survival.set_value("oxygen", 50.)
	GameState.clock += float(GameState.survival.config["facility_air"]["reserve_hours"]) + .01
	await frames()
	await get_tree().create_timer(.2).timeout
	check(not room.player.can_breathe() and GameState.survival.values["oxygen"] < 50., "expired reserve drains oxygen while player is indoors")
	check(GameState.facility_air.reserve_fraction() == 0., "depleted gauge clamps to empty")
	check(room.reserve_meter.readout.frame == 0, "physical meter shows reserve exhausted")
	await capture("base-o2-reserve-empty")
	GameState.repair_for("power").complete_task("cracks")
	GameState.repair_for("power").complete_task("wiring")
	await frames()
	check(DayNight.fixture_power == 0., "generator alone cannot restore lighting without solar")
	var solar := GameState.solar_field
	for mirror in solar.mirrors:
		var route: Dictionary = solar.field["routes"][mirror["group"]]
		var index: int = mirror["index"]
		var before := SolarOptics.point(route["source"] if index == 0 else route["mirrors"][index - 1])
		var after := SolarOptics.point(solar.field["collector"]["world"] if index + 1 == route["mirrors"].size() else route["mirrors"][index + 1])
		var desired := SolarOptics.alignment(mirror["world"] - before, after - mirror["world"])
		while solar.orientations[mirror["id"]] != desired: solar.rotate(mirror["id"])
	for group in 3: solar.toggle_feed(group)
	for hour in [0., 5., 8., 12., 16., 19.5, 22.]:
		GameState.clock = hour + 24.
		await frames()
		check(DayNight.light_mul.r > .7 and room.fx._reserve.visible, "restored main power lights the room at %02d:00" % hour)
		check(not hud.oxygen_counter.visible, "reserve counter disappears with mains at %02d" % hour)
		check(not room.reserve_meter.readout.visible, "reserve readout sleeps on mains at %02d" % hour)
		if hour in [12., 22.]: await capture("base-powered-%02d" % hour)
	await capture_meter(room,"oxygen-wall-on-mains")
	room.queue_free()
	await frames()
	GameState.story.nursery_awake = true
	GameState.story.nursery_introduced = true
	room = load("res://scenes/nursery.tscn").instantiate()
	get_tree().root.add_child.call_deferred(room)
	await frames()
	room.day_night.speed = 0.
	check(DayNight.fixture_power == 0. and room.player.can_breathe(), "base O2 reaches nursery while its console still leaves lights off")
	check(GameState.cultivation.repair("console"), "nursery console restores its local power")
	await frames()
	for hour in [0., 5., 8., 12., 16., 19.5, 22.]:
		GameState.clock = hour + 24.
		await frames()
		check(DayNight.light_mul.r > .7 and room.player.can_breathe(), "local console lighting and shared O2 work in nursery at %02d:00" % hour)
		if hour in [12., 22.]: await capture("nursery-powered-%02d" % hour)
	room.queue_free()
	await frames()
	print("FACILITY POWER TESTS: %d checks, %d failures" % [checks, failures])
	await Audio.quit(1 if failures else 0)
