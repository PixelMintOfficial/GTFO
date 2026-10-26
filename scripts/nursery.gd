extends Node2D
## The damaged nursery: three simple F/X repairs, dead growing beds and two working airlocks.
## Artwork, collision, door frames and anchors come from nursery_gen.py in four views.
## Uses the base's player, depth window, day/night, room toast, inventory and door cutscene.
## Escape opens the shared paused volume/GUI options. F/X enters or exits through either door.
## Wild seeds replant the food racks/water silos, then game-clock growth yields consumable fruit.
## Session progress is GameState.cultivation. Repairs use the equipped multitool's held scanner;
## minigames remain future work. --use holds the tool for scanner captures after --equip.
##
## Test hooks: --spawn=X,Y --walk=DX,DY[,run] --capture=PATH --seconds=S --burst=N --gap=S
## --turn=N --turn-left/--turn-right --time=H --suit-light --equip --use --quit=S
## --arrive --exit --exit-id=ID (1 or 5); --door-id=ID chooses an arrival doorway.
## NurseryCleanup draws generated floor litter; the nursery UNIT physically vacuums it.
## Repairing the console powers nursery lighting. O2 remains piped from the main base.
## A scene-specific checklist tracks player repairs, planting and first harvests.
## --bot-wake / --bot-talk / --story-auto=S preview the nursery body's real repair/dialogue.
## --nursery-repaired --nursery-seeds --nursery-crops=ripe|sprout --nursery-at=ID

const MAP_JSON := "res://assets/maps/nursery_interior/nursery.json"
const PROPS_JSON := "res://assets/maps/nursery_interior/nursery_props.json"

var terrain: MapTerrain
var stream: MapStream
var view_turn: ViewTurn
var suit_light: SuitLight
var cultivation: CultivationWorld
var cleanup: NurseryCleanup
var bot: Bot
var dialogue: BotDialogue
var _repair_mask := 0
var doors: Array[AirlockDoor] = []

@onready var player: Player = $Actors/Player
@onready var multitool: Multitool = $Multitool
@onready var fx: InteriorFX = $InteriorFX
@onready var day_night: DayNight = $DayNight


func _ready() -> void:
	var args := _args()
	Audio.debug = args.has("audio-debug")
	Audio.enter_scene()
	Audio.bed("amb_dome", 1.0)
	if args.has("turn"):
		GameState.heading = posmod(int(args["turn"]), 4)
	if args.has("nursery-repaired"):
		GameState.cultivation.repairs = 7
		GameState.story.nursery_awake = true
		GameState.story.nursery_introduced = true
	if args.has("nursery-crops"):
		GameState.cultivation.repairs = 7
		GameState.story.nursery_awake = true
		GameState.story.nursery_introduced = true
		var preview_clock := float(args.get("time", GameState.clock))
		for id in GameState.cultivation.config["beds"]:
			GameState.cultivation.beds[id] = {"kind": GameState.cultivation.config["beds"][id],
					"ready_at": preview_clock - 1. if args["nursery-crops"] == "ripe" else preview_clock + 1.}
	if args.has("nursery-seeds"):
		GameState.store_items("emberpod_seed", 3)
		GameState.store_items("dewpod_seed", 3)
	_repair_mask = GameState.cultivation.repairs
	terrain = MapTerrain.new(_repair_map(_repair_mask), GameState.heading)
	$Map.texture = terrain.map_texture
	player.setup(terrain)
	player.air_source = GameState.facility_air.breathable # piped from the main base O2 generator
	player.camera.zoom_locked = true
	player.camera.setup(player, $Map, terrain.max_view_px, terrain.streaming)
	stream = MapStream.new()
	add_child(stream)
	stream.setup(terrain, $Map, player.camera, player)
	stream.published.connect(_window_moved)
	player.refresh_window()
	multitool.setup(PROPS_JSON, player, terrain, $Actors)
	fx.setup(terrain.view_json, player)
	day_night.facility = true
	day_night.facility_power_source = GameState.nursery_powered
	day_night.setup($Map, terrain.light_mask, terrain.sun_mask)
	player.step_source = func() -> String: return "step_metal"
	_setup_doors()
	cultivation = CultivationWorld.new()
	add_child(cultivation)
	cultivation.setup(player, multitool, terrain, $Actors, true)
	cleanup = NurseryCleanup.new()
	add_child(cleanup)
	cleanup.setup(terrain, $Actors)
	GameState.cultivation.changed.connect(_repair_changed)
	view_turn = ViewTurn.new()
	add_child(view_turn)
	view_turn.setup(terrain, player, _apply_view, _turn_boards, stream)
	var inventory_ui := InventoryUI.new()
	add_child(inventory_ui)
	inventory_ui.setup(player, multitool)
	var survival_hud := SurvivalHUD.new()
	add_child(survival_hud)
	survival_hud.setup(player, multitool)
	var dev_panel := DevPanel.new()
	add_child(dev_panel)
	dev_panel.setup(player)
	suit_light = SuitLight.new()
	add_child(suit_light)
	suit_light.setup(player, multitool)
	var objectives := ObjectiveHUD.new()
	add_child(objectives)
	objectives.setup(player, "nursery")
	dialogue = BotDialogue.new()
	add_child(dialogue)
	bot = Bot.new()
	$Actors.add_child(bot)
	bot.setup(ViewData.get_json(terrain.view_json)["bot"], player, multitool, terrain, dialogue, null)
	bot.set_cleanup(cleanup)
	PauseMenu.attach(self, player, multitool)
	if GameState.tool_out:
		player.set_tool_out(true)
	if GameState.arrive == "interior" or args.has("arrive"):
		var arrival := _door(int(args.get("door-id", GameState.door_id)))
		if arrival == null:
			arrival = doors[0]
		arrival.arrive()
	GameState.arrive = ""
	_run_test_hooks(args)


func _setup_doors() -> void:
	var meta := ViewData.get_json(terrain.view_json)
	for info in meta["doors"]:
		var door := AirlockDoor.new()
		$Actors.add_child(door)
		door.setup(info, terrain.view_json.get_base_dir(), player, player.camera, terrain, multitool, "EXIT")
		door.set_meta("id", int(info["id"]))
		door.entered.connect(_leave.bind(int(info["id"])))
		doors.append(door)


func _door(id: int) -> AirlockDoor:
	for door in doors:
		if int(door.get_meta("id")) == id:
			return door
	return null


func _leave(id: int) -> void:
	GameState.arrive = "door"
	GameState.door_id = id
	GameState.tool_out = player.tool_state == Player.Tool.READY
	get_tree().change_scene_to_file("res://scenes/overworld.tscn")


func _apply_view(k: int, world_facing: Vector2) -> void:
	terrain.load_view(k)
	player.refresh_view(world_facing)
	player.camera.set_view_limits(terrain.max_view_px)
	stream.refresh(true)
	$Map.texture = terrain.map_texture
	day_night.set_masks(terrain.light_mask, terrain.sun_mask)
	fx.load_view(terrain.view_json)
	multitool.set_view()
	cultivation.load_view()
	cleanup.load_view()
	bot.set_view()
	for door in doors:
		door.queue_free()
	doors.clear()
	_setup_doors()


func _window_moved(_heading: int) -> void:
	player.refresh_window()
	multitool.refresh_window()
	if cultivation != null:
		cultivation.refresh_window()
	if bot != null:
		bot.refresh_window()
	if cleanup != null:
		cleanup.refresh_window()


func _turn_boards() -> Array:
	return cultivation.boards() + cleanup.boards() + (bot.boards() if bot != null else [])


func _repair_map(mask: int) -> String:
	if mask == 0:
		return MAP_JSON
	return MAP_JSON.get_base_dir().path_join(ViewData.get_json(MAP_JSON)["repair_variants"][str(mask)])


func _repair_changed() -> void:
	if _repair_mask == GameState.cultivation.repairs:
		return
	_repair_mask = GameState.cultivation.repairs
	_refresh_repaired_art.call_deferred()


func _refresh_repaired_art() -> void:
	terrain.replace_variant(_repair_map(_repair_mask))
	_apply_view(terrain.heading, player.facing_dir())


static func _args() -> Dictionary:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	return args


func _run_test_hooks(args: Dictionary) -> void:
	if args.has("story-auto"):
		dialogue.auto_advance = float(args["story-auto"])
	if args.has("bot-wake") or args.has("bot-talk"):
		player.teleport(bot.world + Vector2(bot.radius + 14., 0))
	if args.has("bot-wake"):
		player.set_tool_out(true)
		player.tool_state = Player.Tool.READY
		multitool.forced_use = true
	if args.has("bot-talk"):
		get_tree().create_timer(.5).timeout.connect(bot.talk)
	PerfProbe.attach(self, args)
	if args.has("quit"):
		_quit_after(float(args["quit"]))
	if args.has("suit-light") and not suit_light.on():
		suit_light.toggle()
	if args.has("spawn"):
		var xy: PackedStringArray = args["spawn"].split(",")
		player.teleport(Vector2(float(xy[0]), float(xy[1])))
	if args.has("equip"):
		player.set_tool_out(true)
	if args.has("use"):
		multitool.forced_use = true
	if args.has("nursery-at"):
		player.teleport(cultivation.interaction_point(args["nursery-at"]))
	if args.has("walk"):
		var w: PackedStringArray = args["walk"].split(",")
		player.forced_input = Vector2(float(w[0]), float(w[1]))
		player.forced_run = w.size() > 2 and w[2] == "run"
	if args.has("exit") or args.has("exit-id"):
		var door := _door(int(args.get("exit-id", GameState.door_id)))
		if door == null:
			door = doors[0]
		get_tree().create_timer(.4).timeout.connect(func() -> void:
			player.teleport(door.stand_point())
			door.call("_start"))
	if not args.has("capture") or args.has("exit") or args.has("exit-id"):
		return
	await get_tree().create_timer(float(args.get("seconds", "1.5"))).timeout
	var count := int(args.get("burst", "1"))
	var path: String = args["capture"]
	for i in count:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(path if count == 1 else path.get_basename() + "_%d.png" % i)
		if i < count - 1:
			await get_tree().create_timer(float(args.get("gap", ".12"))).timeout
	await Audio.quit()


func _quit_after(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	await Audio.quit()
