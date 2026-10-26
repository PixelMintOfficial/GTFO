extends Node
## Real nursery-body repair/intro/prerequisite regression, plus facility air and sequential
## guidance checks. Optional native screenshots: -- --out=ABSOLUTE_DIRECTORY.
var checks := 0
var failures := 0
var output := ""

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FACILITY TEST: " + label)

func frames() -> void:
	for i in 3: await get_tree().process_frame

func key(code: int, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)
	Input.flush_buffered_events()
	await frames()

func capture(label: String) -> void:
	if output.is_empty(): return
	await frames()
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(output.path_join(label + ".png"))
	await frames() # inject the next key during process, rather than the completed render frame

func scene(path: String) -> Node:
	var node: Node = load(path).instantiate()
	get_tree().root.add_child.call_deferred(node)
	await frames()
	return node

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			output = arg.trim_prefix("--out=")
			DirAccess.make_dir_recursive_absolute(output)
	await nursery_body()
	guidance_sequence()
	await initial_air()
	await air_supply()
	await exterior_glass()
	print("FACILITY TESTS: %d checks, %d failures" % [checks, failures])
	await Audio.quit(1 if failures else 0)

func nursery_body() -> void:
	GameState.intro_done = true
	GameState.heading = 0
	GameState.story = StoryState.new()
	GameState.clock = 12.
	GameState.reset_inventory()
	GameState.survival.reset()
	GameState.survival.frozen = {"oxygen": true, "hunger": true, "thirst": true}
	var room := await scene("res://scenes/nursery.tscn")
	var bot: Bot = room.bot
	var player: Player = room.player
	check(bot.state == Bot.State.DORMANT and bot.body == "nursery", "nursery body starts dormant")
	check(not GameState.cultivation.repair("console"), "body repair is prerequisite for nursery systems")
	player.teleport(bot.world + Vector2(19., 0.))
	await frames()
	await capture("nursery-unit-dormant")
	await key(KEY_T, true)
	await key(KEY_T, false)
	await get_tree().create_timer(1.2).timeout
	await frames()
	check(player.tool_state == Player.Tool.READY, "T equips multitool before body repair")
	await key(KEY_F, true)
	await get_tree().create_timer(.4).timeout
	await frames()
	check(str(player.sprite.animation).begins_with("use_"), "body repair uses scanner pose")
	await capture("nursery-unit-scan")
	await key(KEY_F, false)
	var progress := float(bot._fix.get("progress", 0.))
	check(progress > 0. and progress < 1., "unfinished body scan is retained")
	await key(KEY_F, true)
	await get_tree().create_timer(3.7).timeout
	await key(KEY_F, false)
	check(GameState.story.nursery_awake and room.dialogue.opened, "scanner wakes body and opens introduction")
	check(not GameState.story.bot_awake, "nursery repair does not repair main body")
	await capture("nursery-unit-introduction")
	for i in 35:
		if not room.dialogue.opened: break
		await key(KEY_ENTER, true)
		await key(KEY_ENTER, false)
	check(GameState.story.nursery_introduced and bot.state == Bot.State.PATROL, "introduction ends in independent maintenance")
	check(GameState.cultivation.repair("console"), "nursery repair unlocked after UNIT")
	check(bot._data["animations"].has("clean"), "native cleaning animation is available")
	var world := bot.world
	room._apply_view(1, player.facing_dir())
	await frames()
	check(bot.world.distance_to(world) < 5., "camera turn preserves bot world position")
	check(not bot._floor_path(bot._spots[0]).is_empty(), "nursery has reachable cleaning sites")
	player.teleport(room.terrain.spawn)
	await get_tree().create_timer(1.).timeout
	await frames()
	check(bot.world.distance_to(world) > 1. or bot.cleaning, "nursery body performs maintenance")
	check(not bot.cleaning, "UNIT strolls between occasional cleanups")
	bot.set_process(false)
	for step in 1800:
		bot._process(.05)
		if bot.cleaning: break
	check(bot.cleaning and bot._anim == "clean", "UNIT reaches its cleaning site and runs native vacuum animation")
	await capture("nursery-unit-patrol")
	room.queue_free()
	await frames()
	room = await scene("res://scenes/nursery.tscn")
	check(room.bot.state == Bot.State.PATROL and GameState.story.nursery_introduced, "body repair and introduction survive scene reload")
	room.queue_free()
	await frames()
	GameState.survival.frozen = {}

func guidance_sequence() -> void:
	GameState.machine_repairs.clear()
	GameState.window_repair = WindowRepair.new()
	GameState.solar_field = SolarFieldState.new()
	GameState.story = StoryState.new()
	var story := GameState.story
	story.skip_intro()
	check(story.objectives().size() == 7 and story.active_stage() == "oxygen", "complete checklist starts with O2")
	check(story.has_news(), "unheard instruction has exclamation")
	story.next_talk()
	check(not story.has_news(), "hearing instruction clears exclamation")
	GameState.repair_for("oxygen").complete_task("cracks")
	check(story.active_stage() == "oxygen", "partial O2 repair cannot advance guidance")
	GameState.repair_for("oxygen").complete_task("wiring")
	check(story.active_stage() == "glass" and story.has_news(), "O2 completion unlocks glass advice")
	var advice := " ".join(story.next_talk())
	check(advice.contains("RESERVE") and advice.contains("G AND H") and advice.contains("BACK"), "glass advice covers reserve, back crack and live turn keys")
	GameState.window_repair.box_broken = true
	check(story.active_stage() == "glass", "broken cargo box cannot count as sealed glass")
	for pane in ["burst", "crescent", "gash"]: GameState.window_repair.fix(pane)
	check(story.active_stage() == "power" and story.has_news(), "all three panes unlock generator advice")
	GameState.repair_for("power").complete_task("cracks")
	GameState.repair_for("power").complete_task("wiring")
	check(story.active_stage() == "solar", "repaired generator still needs solar")
	check(" ".join(story.next_talk()).contains("THREE"), "UNIT requests all solar routes")
	var solar := GameState.solar_field
	for mirror in solar.mirrors:
		var route: Dictionary = solar.field["routes"][mirror["group"]]
		var index: int = mirror["index"]
		var before := SolarOptics.point(route["source"] if index == 0 else route["mirrors"][index - 1])
		var after := SolarOptics.point(solar.field["collector"]["world"] if index + 1 == route["mirrors"].size() else route["mirrors"][index + 1])
		var desired := SolarOptics.alignment(mirror["world"] - before, after - mirror["world"])
		while solar.orientations[mirror["id"]] != desired: solar.rotate(mirror["id"])
	for group in 2: solar.toggle_feed(group)
	check(story.active_stage() == "solar" and not story.objective_done("feeds"), "two solar channels are insufficient")
	solar.toggle_feed(2)
	check(story.active_stage() == "done" and story.all_done(), "all generator/glass/solar objectives complete")

func initial_air() -> void:
	GameState.facility_air.reset()
	GameState.clock = 8.
	GameState.machine_repairs.clear()
	GameState.window_repair = WindowRepair.new()
	GameState.solar_field = SolarFieldState.new()
	GameState.survival.reset()
	for path in ["res://scenes/overworld.tscn", "res://scenes/interior.tscn", "res://scenes/nursery.tscn"]:
		var room := await scene(path)
		check(not room.player.can_breathe(), "broken outpost cannot supply air: " + path)
		var oxygen: float = GameState.survival.values["oxygen"]
		await get_tree().create_timer(.15).timeout
		check(GameState.survival.values["oxygen"] < oxygen, "suit oxygen drains in " + path)
		room.queue_free()
		await frames()

func air_supply() -> void:
	var air := GameState.facility_air
	check(air.status() == "offline", "O2 requires both repair tasks")
	GameState.repair_for("oxygen").complete_task("cracks")
	check(air.status() == "offline", "cracks alone cannot produce oxygen")
	GameState.repair_for("oxygen").complete_task("wiring")
	check(air.status() == "reserve" and air.reserve_started_at == GameState.clock, "complete O2 repair starts timed reserve")
	check(not air.breathable(), "broken glass leaks reserve oxygen")
	for pane in ["burst", "crescent"]: GameState.window_repair.fix(pane)
	check(not air.breathable(), "rear pane must also be sealed")
	GameState.window_repair.fix("gash")
	check(air.breathable(), "reserve O2 retained after all glass is sealed")
	GameState.story.nursery_awake = true
	GameState.story.nursery_introduced = true
	for path in ["res://scenes/interior.tscn", "res://scenes/nursery.tscn"]:
		GameState.survival.set_value("oxygen", 40.)
		var room := await scene(path)
		check(room.player.can_breathe(), "shared facility supply reaches " + path)
		await get_tree().create_timer(.2).timeout
		check(GameState.survival.values["oxygen"] > 40., "indoor air replenishes suit oxygen")
		room.player.teleport(room.bot.world + Vector2(20., 0.))
		room.player.facing = "W"
		await frames()
		check(GameState.story.has_news(room.bot.body), "UNIT has unread generator advice in " + path)
		await capture("reserve-" + ("base" if path.contains("interior.tscn") else "nursery"))
		room.queue_free()
		await frames()
	GameState.clock += float(GameState.survival.config["facility_air"]["reserve_hours"]) + .01
	check(air.status() == "empty" and not air.breathable(), "reserve expires without continuous power")
	GameState.repair_for("power").complete_task("cracks")
	GameState.repair_for("power").complete_task("wiring")
	check(air.status() == "empty", "generator alone cannot replace solar supply")
	# The same authored solution used in guidance_sequence, with all three feeds.
	guidance_sequence()
	check(air.status() == "online" and air.breathable(), "generator and all solar routes provide lasting air")
	var world := await scene("res://scenes/overworld.tscn")
	check(not world.player.can_breathe(), "working facilities do not make outdoor atmosphere breathable")
	world.queue_free()
	await frames()

func exterior_glass() -> void:
	GameState.window_repair.dome_mended = ""
	var world := await scene("res://scenes/overworld.tscn")
	world.player.camera.set_level(3)
	await get_tree().create_timer(.5).timeout
	var shapes := {}
	for heading in 4:
		world._apply_view(heading, world.player.facing_dir())
		await frames()
		var meta := ViewData.get_json(world.terrain.view_json)
		var cracks: Array = ViewData.fx_of(world.terrain.view_json, meta)["cracks"]
		check(cracks.all(func(crack: Dictionary) -> bool: return crack["room"] == "command"), "habitat and garage have intact exterior glass in view %d" % heading)
		for crack in cracks:
			shapes[crack["shape"]] = true
			check(FileAccess.file_exists(world.terrain.view_json.get_base_dir().path_join(crack["patch"])), "exterior repair patch exists for " + crack["id"])
		if heading == 2:
			check(cracks.any(func(crack: Dictionary) -> bool: return crack["shape"] == "gash"), "rear view shows the storage gash")
		await capture("exterior-cracked-view%d" % heading)
		GameState.window_repair.dome_mended = "command"
		world.dome_fx.load_view(world.terrain.view_json)
		check(world.dome_fx._glass.size() == cracks.size(), "sealing storage restores every visible exterior hole")
		await capture("exterior-sealed-view%d" % heading)
		GameState.window_repair.dome_mended = ""
	check(shapes.size() == 3 and shapes.has("gash") and shapes.has("burst") and shapes.has("crescent"), "exactly the three repairable storage panes exist outside")
	world.queue_free()
	await frames()
