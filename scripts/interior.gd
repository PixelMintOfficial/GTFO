extends Node2D
## Inside the main base: storage (the airlock comes in here), the power room to the right and
## the oxygen room to the left. Full lighting needs both restored machines and solar.
## F at the airlock door goes back outside.
## Escape opens the paused volume/GUI options (PauseMenu).
## Storage's three smashed panes and the cargo box you stand on to reach them: WindowCracks. The
## bot asleep in its cradle in storage (then patrolling and cleaning), the bulkheads sealing
## the power and oxygen rooms until it releases maintenance access, and the objective line:
## scripts/story/.
##
## Test hooks (after "--"): --spawn=X,Y  --walk=DX,DY[,run]  --capture=PATH
## --seconds=S  --burst=N  --gap=S  --arrive (play coming in through the door)  --exit (use the door)
## --face=DX,DY  --equip (take the tool out)  --use (then hold F: works, or lifts, what is in reach)
## --open-inventory / --inventory-demo   backpack screenshot hooks (see InventoryUI)
## --survival-debug / --vitals=H,O,F,W / --survival-speed=N (see SurvivalHUD)
## --dev-panel / --dev-freeze=hunger,thirst,oxygen (master control panel, F1; see DevPanel)
## --suit-light starts with the suit's lamp lit (L switches it; see SuitLight)
## --repair=power|oxygen opens its current task (three demo scraps supplied for captures).
## --repair-done=power|oxygen|both marks both tasks for repaired-art captures.
## --repair-circuit=power|oxygen skips cracks only for circuit screenshots/tests.
## --repair-bars keeps ambient F input from opening a panel during a machine-bar capture.
## --cargo=burst|crescent|gash sets the cargo box down under that pane and stands you on it;
## --cargo-mended=N mends the first N panes first (the box shows N cracks); --cargo-land lands on
## the box (wear only; collapse waits until all three scans have sealed their windows).
## --window=burst|crescent|gash opens a reachable window with six demo glass for captures;
## --window-fit=N fits N pieces; --window-scan=P starts the complete board's scan at fraction P.
## --window-close=S closes that live panel after S seconds for world scan/persistence captures.
## --audio-debug (print every sound as it plays)
## --perf / --perf-every=SECONDS (print texture memory, draw calls and frame times)
## --quit=SECONDS (run for this long, then shut the sound down and quit cleanly)
## --turn=N (start with the camera turned N quarter turns round; G / H turn it)
## --turn-left / --turn-right (turn the camera once after a second, see ViewTurn)
## --story=awake (bot awake/named, maintenance access open, objectives handed out)
## --bot-wake (stand by the bot with the tool out and hold F: the fix job wakes it)
## --bot-talk (stand by the awake bot and talk to it)  --story-auto=S (lines move on after S seconds)
## --bot-follow (the bot awake and following, beside you from the start; implies --story=awake)
## --name=NAME (the name entry types NAME and confirms it; never saved to the profile)

const MAP_JSON := "res://assets/maps/base_interior/base_interior.json"
const PROPS_JSON := "res://assets/maps/base_interior/interior_props.json"

var terrain: MapTerrain
var stream: MapStream
var door: AirlockDoor
var repairs: MachineRepairs
var cracks: WindowCracks
var view_turn: ViewTurn
var solar_input: SolarPowerInput
var reserve_meter: ReserveMeter
var suit_light: SuitLight
var cleanup: NurseryCleanup
var bot: Bot
var bulkheads: Array[Bulkhead] = []
var dialogue: BotDialogue
var names: NameEntry
var _repair_mask := 0

@onready var player: Player = $Actors/Player
@onready var multitool: Multitool = $Multitool
@onready var fx: InteriorFX = $InteriorFX
@onready var day_night: DayNight = $DayNight


func _ready() -> void:
	Audio.debug = _args().has("audio-debug")
	Audio.enter_scene()
	Audio.bed("amb_interior", 1.0)             # wind through the smashed windows, from inside
	if _args().has("turn"):
		GameState.heading = posmod(int(_args()["turn"]), 4)
	if _args().get("story", "") == "awake" or _args().has("bot-follow"):
		GameState.story.skip_intro(_args().get("name", "TESTER"))
	_repair_mask = _completed_mask()
	terrain = MapTerrain.new(_repair_map(_repair_mask), GameState.heading)
	$Map.texture = terrain.map_texture
	player.setup(terrain)
	player.camera.zoom_locked = true                     # no zooming out indoors
	player.camera.setup(player, $Map, terrain.max_view_px, terrain.streaming)
	stream = MapStream.new()
	add_child(stream)
	stream.setup(terrain, $Map, player.camera, player)
	stream.published.connect(_window_moved)
	multitool.setup(PROPS_JSON, player, terrain, $Actors)
	fx.setup(terrain.view_json, player)
	day_night.facility = true
	day_night.setup($Map, terrain.light_mask, terrain.sun_mask, terrain)
	player.step_source = func() -> String: return "step_metal"
	var meta := ViewData.get_json(terrain.view_json)
	player.air_source = GameState.facility_air.breathable
	_setup_door(meta)
	repairs = MachineRepairs.new()
	add_child(repairs)
	repairs.setup(meta, player, multitool)
	solar_input = SolarPowerInput.new()
	add_child(solar_input)
	solar_input.setup(meta, terrain)
	reserve_meter = ReserveMeter.new()
	add_child(reserve_meter)
	reserve_meter.setup(meta, terrain)
	for machine_id in ["power", "oxygen"]:
		GameState.repair_for(machine_id).changed.connect(_repair_changed)
	cracks = WindowCracks.new()
	add_child(cracks)
	cracks.setup(meta, player, multitool, terrain)
	var inventory_ui := InventoryUI.new()
	add_child(inventory_ui)
	inventory_ui.setup(player, multitool)
	var survival_hud := SurvivalHUD.new()
	add_child(survival_hud)
	survival_hud.setup(player, multitool)
	var dev_panel := DevPanel.new()                    # F1, debug builds: time and frozen needs
	add_child(dev_panel)
	dev_panel.setup(player)
	suit_light = SuitLight.new()                       # L: the base is dead, so bring your own
	add_child(suit_light)
	suit_light.setup(player, multitool)
	cleanup = NurseryCleanup.new()
	add_child(cleanup)
	cleanup.setup(terrain, $Actors, NurseryCleanup.BASE_ART)
	_setup_story(meta)
	bot.set_cleanup(cleanup)
	view_turn = ViewTurn.new()
	add_child(view_turn)
	view_turn.setup(terrain, player, _apply_view, _turn_boards, stream)
	PauseMenu.attach(self, player, multitool)
	if GameState.tool_out:
		player.set_tool_out(true)
	var args := _args()
	if GameState.arrive == "interior" or args.has("arrive"):
		door.arrive()
	GameState.arrive = ""
	_run_test_hooks(args)


## The bot, the bulkheads, the conversation and the objective line. The dialogue and name entry
## come last so they take input before anything else while they are open.
func _setup_story(meta: Dictionary) -> void:
	for info in meta["bulkheads"]:
		var b := Bulkhead.new()
		$Actors.add_child(b)
		b.setup(info, terrain.view_json.get_base_dir(), terrain, player)
		bulkheads.append(b)
	GameState.story.changed.connect(_story_changed)
	var objectives := ObjectiveHUD.new()
	add_child(objectives)
	objectives.setup(player)
	dialogue = BotDialogue.new()
	add_child(dialogue)
	names = NameEntry.new()
	add_child(names)
	bot = Bot.new()
	$Actors.add_child(bot)
	bot.setup(meta["bot"], player, multitool, terrain, dialogue, names)


func _story_changed() -> void:
	if GameState.story.access_opened:
		for b in bulkheads:
			b.open()


func _setup_door(meta: Dictionary) -> void:
	door = AirlockDoor.new()
	$Actors.add_child(door)
	door.setup(meta["door"], terrain.view_json.get_base_dir(), player, player.camera, terrain, multitool, "EXIT")
	door.entered.connect(_leave)


## The camera turned round the base: switch everything to that view.
func _apply_view(k: int, world_facing: Vector2) -> void:
	terrain.load_view(k)
	var meta := ViewData.get_json(terrain.view_json)
	player.refresh_view(world_facing)
	player.camera.set_view_limits(terrain.max_view_px)
	stream.refresh(true)                                 # the window, once the camera has moved
	$Map.texture = terrain.map_texture
	day_night.set_masks(terrain.light_mask, terrain.sun_mask, terrain.no_sun_map)
	fx.load_view(terrain.view_json)
	multitool.set_view()
	repairs.set_view(meta)
	solar_input.load_view(meta)
	reserve_meter.load_view(meta)
	cracks.set_view(meta)
	for info in meta["bulkheads"]:
		for b in bulkheads:
			if b.id == info["id"]:
				b.set_view(info, terrain.view_json.get_base_dir())
	bot.set_view()
	cleanup.load_view()
	door.queue_free()
	_setup_door(meta)


## The depth window has moved: point everything that samples it at where it is now.
func _window_moved(_heading: int) -> void:
	player.refresh_window()
	multitool.refresh_window()
	bot.refresh_window()
	if cleanup != null: cleanup.refresh_window()
	for b in bulkheads:
		b.refresh_window()


## The loose props (scrap, the cargo box, rations), for the camera's swing.
func _turn_boards() -> Array:
	var out := []
	for n in $Actors.get_children():
		if n is WorldProp and not (n as WorldProp).gone:
			out.append(ViewTurn.prop_board(terrain, n))
	out.append_array(bot.boards())
	out.append_array(cleanup.boards())
	for b in bulkheads:
		out.append_array(b.boards())
	return out


func _completed_mask() -> int:
	return (1 if GameState.repair_for("power").progress() >= 1 else 0) + (2 if GameState.repair_for("oxygen").progress() >= 1 else 0)


func _repair_map(mask: int) -> String:
	if mask == 0:
		return MAP_JSON
	var meta := ViewData.get_json(MAP_JSON)
	return MAP_JSON.get_base_dir().path_join(meta["repair_variants"][str(mask)])


func _repair_changed() -> void:
	var mask := _completed_mask()
	if mask == _repair_mask:
		return
	_repair_mask = mask
	_refresh_repaired_art.call_deferred()


func _refresh_repaired_art() -> void:
	terrain.replace_variant(_repair_map(_repair_mask))
	_apply_view(terrain.heading, player.facing_dir())


func _leave() -> void:
	GameState.arrive = "door"
	GameState.tool_out = player.tool_state == Player.Tool.READY
	get_tree().change_scene_to_file("res://scenes/overworld.tscn")


static func _args() -> Dictionary:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	return args


## Quit after a fixed number of seconds, stopping the sound first: anything still playing when
## the engine tears down is reported as a leaked playback. Prefer this to --quit-after, which
## counts frames and so depends on how fast the machine runs.
func _quit_after(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	await Audio.quit()


func _run_test_hooks(args: Dictionary) -> void:
	PerfProbe.attach(self, args)
	if args.has("quit"):
		_quit_after(float(args["quit"]))
	if args.has("suit-light") and not suit_light.on():
		suit_light.toggle()
	if args.has("repair-bars"):
		repairs.set_process_unhandled_input(false)
	if args.has("repair-done"):
		for id in ["power", "oxygen"]:
			if args["repair-done"] == id or args["repair-done"] == "both":
				GameState.repair_for(id).complete_task("cracks")
				GameState.repair_for(id).complete_task("wiring")
	if args.has("repair-circuit"):
		GameState.repair_for(args["repair-circuit"]).complete_task("cracks")
		get_tree().create_timer(.25).timeout.connect(func() -> void: repairs.open_machine(args["repair-circuit"]))
	if args.has("repair"):
		while GameState.item_count("scrap") < 3:
			GameState.store_item("scrap")
		get_tree().create_timer(0.25).timeout.connect(func() -> void: repairs.open_machine(args["repair"]))
	if args.has("spawn"):
		var xy: PackedStringArray = args["spawn"].split(",")
		player.teleport(Vector2(float(xy[0]), float(xy[1])))
	if args.has("cargo-mended"):
		for i in mini(int(args["cargo-mended"]), cracks.panes.size()):
			GameState.window_repair.crack_box(cracks.panes[i]["id"])
			cracks.fix(cracks.panes[i]["id"])
		cracks.box.sprite.frame = GameState.window_repair.damage()
		cracks.set_view(JSON.parse_string(FileAccess.get_file_as_string(terrain.view_json)))
	if args.has("cargo"):
		player.teleport(cracks.place_box_under(args["cargo"]))
	if args.has("cargo-land"):
		get_tree().create_timer(0.5).timeout.connect(func() -> void: player.landed.emit(0.0))
	if args.has("window"):
		var id: String = args["window"]
		player.teleport(cracks.place_box_under(id))
		player.set_tool_out(true)
		while GameState.item_count("glass") < 6:
			GameState.store_item("glass")
		get_tree().create_timer(.25).timeout.connect(func() -> void:
			if cracks.open_window(id):
				var puzzle := cracks.panel.puzzle
				for i in mini(int(args.get("window-fit", "0")), 6):
					puzzle.rotations[i] = 0
					puzzle.place(i, puzzle.target(i))
				if args.has("window-scan"):
					puzzle.scan = clampf(float(args["window-scan"]), 0, 1))
		if args.has("window-close"):
			get_tree().create_timer(float(args["window-close"])).timeout.connect(cracks.panel.close)
	if args.has("name"):
		names.remember = false
		names.auto_name = args["name"]
	if args.has("story-auto"):
		dialogue.auto_advance = float(args["story-auto"])
	if args.has("bot-wake") or args.has("bot-talk"):
		player.teleport(bot.world + Vector2(bot.radius + 14.0, 0))         # beside it, not in front
		player.facing = Player.DIRS[posmod(int(round(Vector2(-1, 0).angle() / (PI / 4.0))), 8)]
	if args.has("bot-wake"):
		player.set_tool_out(true)
		get_tree().create_timer(0.4).timeout.connect(func() -> void: multitool.forced_use = true)
	if args.has("bot-follow"):
		bot.warp_near_player.call_deferred()              # after --spawn has put you somewhere
	if args.has("bot-talk"):
		get_tree().create_timer(0.5).timeout.connect(bot.talk)
	if args.has("face"):
		var f: PackedStringArray = args["face"].split(",")
		var sd := Vector2(float(f[0]), float(f[1]))
		player.facing = Player.DIRS[posmod(int(round(sd.angle() / (PI / 4.0))), 8)]
	if args.has("equip"):
		get_tree().create_timer(0.3).timeout.connect(player.toggle_tool)
	if args.has("use"):
		get_tree().create_timer(1.2).timeout.connect(func() -> void: multitool.forced_use = true)
	if args.has("walk"):
		var w: PackedStringArray = args["walk"].split(",")
		player.forced_input = Vector2(float(w[0]), float(w[1]))
		player.forced_run = w.size() > 2 and w[2] == "run"
	if args.has("exit"):
		get_tree().create_timer(0.4).timeout.connect(func() -> void:
			player.teleport(door.stand_point())
			door.call("_start"))
	if not args.has("capture"):
		return
	await get_tree().create_timer(float(args.get("seconds", "1.5"))).timeout
	var path: String = args["capture"]
	var count := int(args.get("burst", "1"))
	var gap := float(args.get("gap", "0.12"))
	for i in count:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(path if count == 1 else path.get_basename() + "_%d.png" % i)
		if i < count - 1:
			await get_tree().create_timer(gap).timeout
	await Audio.quit()
