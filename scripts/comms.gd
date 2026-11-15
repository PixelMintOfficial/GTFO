extends Node2D
## The damaged communications room inside the dish pedestal. Its airlock and
## cutaway come from comms_gen.py. The normal fix job restores the cracked screen.
## The room and repaired screen light up only while main-base mains are online.
## F/X at the powered screen transmits the session's SOS. The pedestal shelters the suit.
## Test hooks: --arrive --exit --turn=N --turn-right --time=H --console
## --capture=PATH --seconds=S --quit=S --equip --use --suit-light
## --comms-main-power starts with the main-base reactor and solar feeds restored.

const MAP_JSON := "res://assets/maps/comms_interior/comms.json"
const PROPS_JSON := "res://assets/maps/comms_interior/comms_props.json"
const OVERWORLD := "res://scenes/overworld.tscn"
const VARIANTS := ["comms.json", "comms_standby.json", "comms_online.json"]

var terrain: MapTerrain
var door: AirlockDoor
var door_id: int
var _variant := 0
var _screen: Dictionary = {}
var _console_hint: Node2D
var _console_message := ""
var _release_guard := false

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
	if args.has("comms-main-power") and OS.is_debug_build():
		GameState.repair_for("power").debug_complete(true)
		GameState.solar_field.debug_complete(true)
	_variant = _art_state()
	terrain = MapTerrain.new(_map_path(), GameState.heading)
	$Map.texture = terrain.map_texture
	player.setup(terrain)
	player.camera.zoom_locked = true
	player.camera.setup(player, $Map, terrain.max_view_px)
	player.step_source = func() -> String: return "step_metal"
	multitool.setup(PROPS_JSON, player, terrain, $Actors)
	fx.setup(terrain.view_json, player)
	day_night.facility = true
	day_night.facility_power_source = GameState.comms_powered
	day_night.setup($Map, terrain.light_mask, terrain.sun_mask)
	_setup_door()
	_setup_screen()
	GameState.repair_for("power").changed.connect(_sync_art)
	GameState.solar_field.changed.connect(_sync_art)
	var view_turn := ViewTurn.new()
	add_child(view_turn)
	view_turn.setup(terrain, player, _apply_view)
	var inventory := InventoryUI.new()
	add_child(inventory)
	inventory.setup(player, multitool)
	var survival := SurvivalHUD.new()
	add_child(survival)
	survival.setup(player, multitool)
	var objectives := ObjectiveHUD.new()
	add_child(objectives)
	objectives.setup(player, "comms")
	var suit_light := SuitLight.new()
	add_child(suit_light)
	suit_light.setup(player, multitool)
	if args.has("suit-light") and not suit_light.on():
		suit_light.toggle()
	PauseMenu.attach(self, player, multitool)
	if GameState.tool_out:
		player.set_tool_out(true)
	if GameState.arrive == "interior" or args.has("arrive"):
		door.arrive()
	GameState.arrive = ""
	_run_test_hooks(args)


func _setup_door() -> void:
	var info: Dictionary = ViewData.get_json(terrain.view_json)["doors"][0]
	door_id = int(info["id"])
	door = AirlockDoor.new()
	$Actors.add_child(door)
	door.setup(info, terrain.view_json.get_base_dir(), player, player.camera, terrain, multitool, "EXIT")
	door.entered.connect(_leave)


func _leave() -> void:
	GameState.arrive = "door"
	GameState.door_id = door_id
	GameState.tool_out = player.tool_state == Player.Tool.READY
	get_tree().change_scene_to_file(OVERWORLD)


func _apply_view(heading: int, world_facing: Vector2) -> void:
	terrain.load_view(heading)
	$Map.texture = terrain.map_texture
	player.refresh_view(world_facing)
	player.camera.set_view_limits(terrain.max_view_px)
	day_night.set_masks(terrain.light_mask, terrain.sun_mask)
	fx.load_view(terrain.view_json)
	multitool.set_view()
	_place_screen()
	door.queue_free()
	_setup_door()


func _art_state() -> int:
	if GameState.comms_repair_progress < 1.0:
		return 0
	return 2 if GameState.comms_powered() else 1


func _map_path() -> String:
	return MAP_JSON.get_base_dir().path_join(VARIANTS[_variant])


func _setup_screen() -> void:
	var info: Dictionary = ViewData.get_json(terrain.view_json)["console_repair"]
	var world := Vector2(float(info["world"][0]), float(info["world"][1]))
	_screen = {"world": world, "radius": 0.0, "scan_height": float(info["scan_height"]),
			"progress": GameState.comms_repair_progress}
	_console_hint = Node2D.new()
	_console_hint.z_index = 40
	_console_hint.set_meta("dn_unlit", true)
	_console_hint.draw.connect(_draw_console_hint)
	add_child(_console_hint)
	_place_screen()
	if _variant == 0:
		multitool.add_fixable(_screen, _screen_fixed)


func _place_screen() -> void:
	var world: Vector2 = _screen["world"]
	var floor_height := terrain.height_at(world)
	_screen["base"] = terrain.to_screen(world, floor_height).round()
	_screen["head"] = terrain.to_screen(world, floor_height + float(_screen["scan_height"])).round()
	_console_hint.position = _screen["head"] - Vector2(0, 18)


func _process(_delta: float) -> void:
	GameState.comms_repair_progress = float(_screen["progress"])
	if not Input.is_action_pressed("interact") and not Input.is_action_pressed("tool_use"):
		_release_guard = false
	var world: Vector2 = _screen["world"]
	var in_reach := player.controls_enabled and not player.turning and not player.puppet \
			and not player.is_airborne() and player.height_above_floor() <= 1.0 \
			and not multitool.suppressed and not multitool.inventory_suppressed \
			and not multitool.options_suppressed and player.world_pos.distance_to(world) <= Multitool.REACH
	var mission := GameState.comms_mission
	var can_send := _variant == 2 and in_reach and not mission.has_transmitted()
	multitool.comms_suppressed = can_send or _release_guard
	if can_send and not _release_guard and Input.is_action_just_pressed("interact"):
		_release_guard = mission.transmit(GameState.clock, GameState.comms_powered())
	var message := ""
	var lines: Dictionary = GameState.story.data["comms"]
	if in_reach:
		if _variant == 1:
			message = lines["power"]
		elif _variant == 2:
			if mission.reply_received:
				message = lines["acknowledgement"]
			elif not mission.has_transmitted():
				message = "F / X  SEND SOS"
	if message != _console_message:
		_console_message = message
		_console_hint.visible = not message.is_empty()
		_console_hint.queue_redraw()


func _draw_console_hint() -> void:
	if _console_message.is_empty():
		return
	var width := PixelFont.width(_console_message)
	var at := Vector2(-width / 2.0, 0.0).round()
	_console_hint.draw_rect(Rect2(at - Vector2(3, 3), Vector2(width + 6, 11)), InventoryUI.VOID)
	var color := InventoryUI.GOLD if _variant == 1 else InventoryUI.TEAL
	PixelFont.draw(_console_hint, at, _console_message, color)


func _screen_fixed() -> void:
	GameState.comms_repair_progress = 1.0
	_release_guard = true
	_sync_art()


func _sync_art() -> void:
	var state := _art_state()
	if _variant == state:
		return
	_variant = state
	terrain.replace_variant(_map_path())
	$Map.texture = terrain.map_texture
	player.refresh_window()
	day_night.set_masks(terrain.light_mask, terrain.sun_mask)


static func _args() -> Dictionary:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	return args


func _run_test_hooks(args: Dictionary) -> void:
	if args.has("quit"):
		get_tree().create_timer(float(args["quit"])).timeout.connect(Audio.quit)
	if args.has("console"):
		var stand: Array = ViewData.get_json(terrain.view_json)["console_stand"]
		player.teleport(Vector2(float(stand[0]), float(stand[1])))
		player.puppet_face(Vector2.DOWN)
	if args.has("equip"):
		player.set_tool_out(true)
	if args.has("use"):
		multitool.forced_use = true
	if args.has("exit"):
		player.teleport(door.stand_point())
		door.call("_start")
	if args.has("capture") and not args.has("exit"):
		await get_tree().create_timer(float(args.get("seconds", "1.5"))).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(args["capture"])
		await Audio.quit()
