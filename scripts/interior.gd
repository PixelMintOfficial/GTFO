extends Node2D
## Inside the main base: storage (the airlock comes in here), the power room to the right and
## the oxygen room to the left. The power is out. F at the airlock door goes back outside.
## Storage's three smashed panes and the cargo box you stand on to reach them: WindowCracks.
##
## Test hooks (after "--"): --spawn=X,Y  --walk=DX,DY[,run]  --capture=PATH
## --seconds=S  --burst=N  --gap=S  --arrive (play coming in through the door)  --exit (use the door)
## --face=DX,DY  --equip (take the tool out)  --use (then hold F: works, or lifts, what is in reach)
## --open-inventory / --inventory-demo   backpack screenshot hooks (see InventoryUI)
## --survival-debug / --vitals=H,O,F,W / --survival-speed=N (see SurvivalHUD)
## --repair=power|oxygen opens its current task (three demo scraps supplied for captures).
## --repair-done=power|oxygen|both marks both tasks for repaired-art captures.
## --repair-circuit=power|oxygen skips cracks only for circuit screenshots/tests.
## --repair-bars keeps ambient F input from opening a panel during a machine-bar capture.
## --cargo=burst|crescent|gash sets the cargo box down under that pane and stands you on it;
## --cargo-mended=N mends the first N panes first (the box shows N cracks); --cargo-land lands on
## the box (the next pane cracks it; after the other two, it gives way).
## --audio-debug (print every sound as it plays)
## --perf / --perf-every=SECONDS (print texture memory, draw calls and frame times)
## --quit=SECONDS (run for this long, then shut the sound down and quit cleanly)
## --turn=N (start with the camera turned N quarter turns round; G / H turn it)
## --turn-left / --turn-right (turn the camera once after a second, see ViewTurn)

const MAP_JSON := "res://assets/maps/base_interior/base_interior.json"
const PROPS_JSON := "res://assets/maps/base_interior/interior_props.json"

var terrain: MapTerrain
var door: AirlockDoor
var repairs: MachineRepairs
var cracks: WindowCracks
var view_turn: ViewTurn
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
	_repair_mask = _completed_mask()
	terrain = MapTerrain.new(_repair_map(_repair_mask), GameState.heading)
	$Map.texture = terrain.map_texture
	player.setup(terrain, terrain.depth_map)
	player.camera.zoom_locked = true                     # no zooming out indoors
	player.camera.setup(player, $Map, terrain.max_view_px)
	multitool.setup(PROPS_JSON, player, terrain, $Actors, terrain.depth_map)
	fx.setup(terrain.view_json, player)
	day_night.setup(player, $Map, terrain.light_mask, terrain.sun_mask)
	player.step_source = func() -> String: return "step_metal"
	var meta := ViewData.get_json(terrain.view_json)
	# Damaged O2 room has unsafe air; the suit spends its reserve until wiring is restored.
	# Room coordinates are world metadata and remain valid through camera turns.
	var room: Dictionary = meta["rooms"]["oxygen"]
	var air_center := Vector2(room["center"][0], room["center"][1])
	var air_radius := float(room["radius"]) * float(GameState.survival.config["unsafe_room_radius_fraction"])
	player.air_source = func() -> bool:
		return player.world_pos.distance_to(air_center) >= air_radius or GameState.repair_for("oxygen").task_completed("wiring")
	_setup_door(meta)
	repairs = MachineRepairs.new()
	add_child(repairs)
	repairs.setup(meta, player, multitool)
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
	view_turn = ViewTurn.new()
	add_child(view_turn)
	view_turn.setup(terrain, player, _apply_view, _turn_boards)
	if GameState.tool_out:
		player.set_tool_out(true)
	var args := _args()
	if GameState.arrive == "interior" or args.has("arrive"):
		door.arrive()
	GameState.arrive = ""
	_run_test_hooks(args)


func _setup_door(meta: Dictionary) -> void:
	door = AirlockDoor.new()
	$Actors.add_child(door)
	door.setup(meta["door"], terrain.view_json.get_base_dir(), player, player.camera, terrain, multitool, "EXIT")
	door.entered.connect(_leave)


## The camera turned round the base: switch everything to that view.
func _apply_view(k: int, world_facing: Vector2) -> void:
	terrain.load_view(k)
	$Map.texture = terrain.map_texture
	var meta := ViewData.get_json(terrain.view_json)
	player.refresh_view(world_facing)
	player.camera.set_view_limits(terrain.max_view_px, terrain.frames)
	day_night.set_masks(terrain.light_mask, terrain.sun_mask)
	fx.load_view(terrain.view_json)
	multitool.set_view(terrain.depth_map)
	repairs.set_view(meta)
	cracks.set_view(meta)
	door.queue_free()
	_setup_door(meta)


## The loose props (scrap, the cargo box, rations), for the camera's swing.
func _turn_boards() -> Array:
	var out := []
	for n in $Actors.get_children():
		if n is WorldProp and not (n as WorldProp).gone:
			out.append(ViewTurn.prop_board(terrain, n))
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
			GameState.window_repair.fix(cracks.panes[i]["id"])
		cracks.box.sprite.frame = GameState.window_repair.damage()
	if args.has("cargo"):
		player.teleport(cracks.place_box_under(args["cargo"]))
	if args.has("cargo-land"):
		get_tree().create_timer(0.5).timeout.connect(func() -> void: player.landed.emit(0.0))
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
