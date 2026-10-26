extends Node
## Real nursery traversal, vacuum deployment/progressive litter removal, checklist/harvest
## updates and session/view persistence. -- --out=DIR captures the native room/animation.
var checks := 0
var failures := 0
var output := ""

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("CLEANUP TEST: " + label)

func frames() -> void:
	for i in 3: await get_tree().process_frame

func capture(label: String) -> void:
	if output.is_empty(): return
	await frames()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(output.path_join(label + ".png"))
	await frames()

func power_facilities() -> void:
	GameState.repair_for("power").complete_task("cracks")
	GameState.repair_for("power").complete_task("wiring")
	var solar := GameState.solar_field
	for mirror in solar.mirrors:
		var route: Dictionary = solar.field["routes"][mirror["group"]]
		var index: int = mirror["index"]
		var before := SolarOptics.point(route["source"] if index == 0 else route["mirrors"][index - 1])
		var after := SolarOptics.point(solar.field["collector"]["world"] if index + 1 == route["mirrors"].size() else route["mirrors"][index + 1])
		var desired := SolarOptics.alignment(mirror["world"] - before, after - mirror["world"])
		while solar.orientations[mirror["id"]] != desired: solar.rotate(mirror["id"])
	for group in 3:
		if not solar.feeds[group]: solar.toggle_feed(group)

func scene() -> Node:
	var room: Node = load("res://scenes/nursery.tscn").instantiate()
	get_tree().root.add_child.call_deferred(room)
	await frames()
	room.day_night.speed = 0.
	room.bot.set_process(false)
	return room

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
			DirAccess.make_dir_recursive_absolute(output)
	GameState.intro_done = true
	GameState.story = StoryState.new()
	GameState.reset_inventory()
	GameState.clock = 12.
	var room := await scene()
	var bot: Bot = room.bot
	var cleanup: NurseryCleanup = room.cleanup
	check(cleanup.sites.size() == 6 and not cleanup.all_clean(), "six real piles start dirty")
	check(GameState.story.objectives("nursery").size() == 8, "player-only nursery checklist available before main introduction")
	cleanup.advance(0, 2., cleanup.point(cleanup.sites[0]) + Vector2(60, 0))
	check(cleanup.progress(0) == 0., "remote bot cannot clear dirt")
	await capture("nursery-dirty-unpowered-noon")
	power_facilities()
	GameState.story.nursery_awake = true
	GameState.cultivation.repair("console")
	await frames()
	await capture("nursery-dirty-powered")
	GameState.story.nursery_awake = true
	GameState.story.nursery_introduced = true
	bot.state = Bot.State.PATROL
	room.player.teleport(room.terrain.spawn)
	var paths := true
	for spot in bot._spots: paths = paths and not bot._floor_path(spot).is_empty()
	check(paths, "every pile has a walk-grid route")
	# Real bot movement/animations at fixed simulation steps, never teleport it to a job.
	var moved_from := bot.world
	var cleaned_early := false
	for step in 240:
		bot._process(.05)
		cleaned_early = cleaned_early or bot.cleaning
	check(not cleaned_early, "UNIT strolls before deciding to clean")
	var stages := {}
	var partial := false
	for step in 9000:
		bot._process(.05)
		stages[bot._anim] = true
		if not partial and cleanup.progress(0) > .3 and cleanup.progress(0) < .7:
			partial = true
			check(bot.cleaning and bot.world.distance_to(bot._spots[0]) <= 6., "bot vacuums only at actual dirt")
			check(cleanup.visuals[0].sprite.frame > 0, "pile shrinks during vacuuming")
			room.player.camera.focus_override = bot.position
			room.player.camera.snap_to(bot.position)
			await capture("nursery-vacuuming")
			var held := cleanup.progress(0)
			get_tree().paused = true
			bot._process(.5)
			get_tree().paused = false
			check(cleanup.progress(0) == held, "paused cleanup cannot remove more dirt")
			for heading in 4:
				room._apply_view(heading, room.player.facing_dir())
				room.player.camera.focus_override = bot.position
				room.player.camera.snap_to(bot.position)
				await capture("nursery-vacuuming-view-%d" % heading)
				check(cleanup.progress(0) == held and cleanup.visuals[0].sprite.frame > 0, "partial dirt/animation follows view %d" % heading)
			room._apply_view(0, room.player.facing_dir())
			room.player.camera.release_focus()
		if cleanup.all_clean() and stages.has("clean_end"): break
	check(partial and bot.world.distance_to(moved_from) > 5., "UNIT travels independently to cleanup jobs")
	check(stages.has("move") and stages.has("clean_start") and stages.has("clean") and stages.has("clean_end"), "movement, deployment, sweep and stow animations all run")
	check(cleanup.all_clean(), "UNIT reaches and removes every pile")
	check(cleanup.visuals.all(func(v: CropVisual) -> bool: return not v.visible), "finished piles disappear")
	check(GameState.story.objectives("nursery").all(func(task: Dictionary) -> bool: return task["id"] != "cleanup"), "UNIT cleanup remains independent of player checklist")
	await capture("nursery-clean")
	for heading in 4:
		room._apply_view(heading, room.player.facing_dir())
		await frames()
		check(cleanup.boards().is_empty(), "cleaned dirt absent during turn %d" % heading)
	room.queue_free()
	await frames()
	room = await scene()
	check(room.cleanup.all_clean(), "cleaned floor persists through airlocks/reloads")
	GameState.cultivation.repairs = 7
	GameState.store_items("emberpod_seed", 3)
	GameState.store_items("dewpod_seed", 2)
	for id in GameState.cultivation.config["beds"]:
		check(GameState.cultivation.plant(id, GameState.clock), "plant " + id)
	var objectives := GameState.story.objectives("nursery")
	check(objectives[4]["done"] and objectives[5]["done"], "food and water planting checklist counts every bed")
	GameState.clock += 24.
	check(GameState.cultivation.harvest("rack0", GameState.clock), "first food harvest")
	check(GameState.cultivation.harvest("silo0", GameState.clock), "first water harvest")
	check(GameState.story.all_done("nursery"), "complete nursery checklist includes both first harvests")
	room.queue_free()
	await frames()
	await base_body()
	print("NURSERY CLEANUP TESTS: %d checks, %d failures" % [checks, failures])
	await Audio.quit(1 if failures else 0)


func base_body() -> void:
	GameState.story = StoryState.new()
	GameState.story.skip_intro()
	var room: Node = load("res://scenes/interior.tscn").instantiate()
	get_tree().root.add_child.call_deferred(room)
	await frames()
	room.day_night.speed = 0.
	var bot: Bot = room.bot
	bot.set_process(false)
	bot._rng.seed = 42
	bot._spot = 0
	bot._clean_wait = 18.
	var cleanup: NurseryCleanup = room.cleanup
	check(bot.cleanup == cleanup and cleanup.sites.size() == 6, "base body has real removable dirt targets")
	var reachable := true
	for spot in bot._spots: reachable = reachable and not bot._floor_path(spot).is_empty()
	check(reachable,"all base dirt piles are reachable")
	var saved_world := bot.world
	var safe_routes := true
	var stands: Array[Vector2] = []
	for target in bot._spots:
		var approach := bot._floor_path(target)
		if not approach.is_empty(): stands.append(approach[-1])
	for source in stands:
		bot.world = source
		for target in bot._spots:
			var path := bot._floor_path(target)
			safe_routes = safe_routes and not path.is_empty()
			var previous := source
			for point in path:
				safe_routes = safe_routes and bot._clear_segment(previous,point)
				previous = point
	bot.world = saved_world
	check(safe_routes and stands.size() == bot._spots.size(),"all base cleaning approaches have clear routes through curved walls")
	var before: Dictionary = GameState.removed_props.duplicate()
	var any_clean := false
	var captured := false
	for step in 14000:
		bot._process(.05)
		any_clean = any_clean or bot.cleaning
		if bot.cleaning and not captured:
			captured = true
			room.player.camera.focus_override = bot.position
			room.player.camera.snap_to(bot.position)
			await capture("base-unit-real-cleanup")
			room.player.camera.release_focus()
		if cleanup.all_clean(): break
	check(any_clean and cleanup.all_clean(),"base UNIT removes actual floor dirt")
	check(before == GameState.removed_props,"UNIT leaves quest scrap/glass/loot untouched")
	var fake := false
	for step in 1200:
		bot._process(.05)
		fake = fake or bot.cleaning
	check(not fake,"clean floors never trigger a fake vacuum job")
	await capture("base-unit-floor-clean")
	room.queue_free()
	await frames()
