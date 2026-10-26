extends Node
## Nursery console is the local power switch. Real repair notifications must light the room,
## its fixtures and exterior without powering the base or supplying O2. Verify all four views,
## day/night, scene continuity and a broken console even when main-base mains are restored.
## Optional native screenshots: -- --out=ABSOLUTE_DIRECTORY. Uses ordinary session state.
var checks := 0
var failures := 0
var output := ""

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("NURSERY POWER: " + label)

func frames() -> void:
	for i in 4: await get_tree().process_frame

func scene(path: String) -> Node2D:
	var room := load(path).instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await frames()
	room.day_night.speed = 0.
	return room

func capture(label: String) -> void:
	if output.is_empty(): return
	await RenderingServer.frame_post_draw
	check(get_viewport().get_texture().get_image().save_png(output.path_join(label + ".png")) == OK, "capture " + label)
	await frames()

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
			DirAccess.make_dir_recursive_absolute(output)
	GameState.intro_done = true
	GameState.heading = 0
	GameState.clock = 22.
	GameState.suit_light = false
	GameState.reset_inventory()
	GameState.story.nursery_awake = true
	GameState.story.nursery_introduced = true
	GameState.survival.frozen = {"oxygen": true, "hunger": true, "thirst": true}
	var room := await scene("res://scenes/nursery.tscn")
	check(DayNight.fixture_power == 0. and DayNight.light_mul.r < .4, "broken screen leaves nursery dark")
	await capture("screen-broken-night")
	check(GameState.cultivation.repair("console"), "repair the real console state")
	await frames()
	check(DayNight.fixture_power == 1. and DayNight.light_mul.r > .7, "repairing only the screen turns nursery power on live")
	check(not GameState.base_powered() and not room.player.can_breathe(), "local lights do not repair main power or generate oxygen")
	var tasks := GameState.story.objectives("nursery")
	check(tasks.size() == 8 and tasks.all(func(task: Dictionary) -> bool: return task["id"] != "cleanup"), "checklist contains player tasks, excluding UNIT cleaning")
	await capture("screen-repaired-night")
	for hour in [0., 8., 12., 22.]:
		GameState.clock = hour
		for heading in 4:
			room._apply_view(heading, room.player.facing_dir())
			await frames()
			check(DayNight.fixture_power == 1. and DayNight.light_mul.r > .7, "nursery powered at hour %d, view %d" % [hour, heading])
			if hour == 22.: await capture("screen-repaired-view-%d" % heading)
	room.queue_free()
	await frames()
	var world := await scene("res://scenes/overworld.tscn")
	for door in world.doors:
		if door.get_meta("id") == 1:
			world.player.teleport(door.stand_point())
			break
	world.player.camera.set_level(2)
	for heading in 4:
		world._apply_view(heading, world.player.facing_dir())
		var box: Array = ViewData.get_json(world.terrain.view_json)["domes"]["nursery"]["bbox_px"]
		var center := Vector2((float(box[0]) + float(box[2])) * .5, (float(box[1]) + float(box[3])) * .5)
		world.player.camera.focus_override = center
		world.player.camera.snap_to(center)
		world.stream.refresh(true)
		await frames()
		check(not BasePower.active and BasePower.light_at(BasePower.current, center) > .5, "console powers exterior glow independently in view %d" % heading)
		if heading in [0, 2]: await capture("console-powered-exterior-%d" % heading)
	world.queue_free()
	await frames()
	GameState.cultivation.repairs = 0
	GameState.cultivation.changed.emit()
	GameState.repair_for("power").debug_complete(true)
	GameState.solar_field.debug_complete(true)
	room = await scene("res://scenes/nursery.tscn")
	check(GameState.base_powered() and DayNight.fixture_power == 0., "main-base mains cannot bypass a broken nursery screen")
	check(GameState.cultivation.repair("console"), "repair screen while base mains are running")
	await frames()
	check(DayNight.fixture_power == 1., "screen restores nursery power with base mains too")
	room.queue_free()
	await frames()
	print("NURSERY POWER TESTS: %d checks, %d failures" % [checks, failures])
	await Audio.quit(1 if failures else 0)
