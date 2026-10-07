extends Node2D
## The red planet overworld: the pre-rendered map with the astronaut walking on it, the life
## of its three lands (red dust plains, the alien forest, the ice), and the satellite crash
## that opens the game.
##
## Test hooks (pass after "--" on the command line), used for automated screenshots:
##   --spawn=X,Y            start at this world position
##   --walk=DX,DY[,run]     hold this stick direction (screen space, y down)
##   --capture=PATH         save the screen as PNG after --seconds (default 1.5), then quit
##   --burst=N              save N frames, 0.12 s apart (PATH gets _0, _1, ... suffixes)
##   --open-map             open the map screen after a second
##   --jump-every=SECONDS   jump on a timer
##   --zoom=LEVEL           start at this zoom level (0 = default, 3 = furthest)
##   --debug                print the player's position, ground height and map depth
##   --intro / --no-intro   force or skip the crash scene (skipped by default with --spawn/--walk)
##   --equip                take the multitool out right away
##   --use                  keep the multitool's use button held (after --equip)
##   --face=DX,DY           turn to face this screen direction before working
##   --door                 walk up to the base's airlock and go in (the whole cutscene)
##   --open-inventory / --inventory-demo   backpack screenshot hooks (see InventoryUI)
##   --audio-debug          print every sound as it plays (there is no screenshot for sound)
##   --quit=SECONDS         run for this long, then shut the sound down and quit cleanly

const MAP_JSON := "res://assets/maps/red_planet/red_planet_map.json"
const DEPTH_MAP: Texture2D = preload("res://assets/maps/red_planet/red_planet_depth.png")
const PROPS_JSON := "res://assets/maps/red_planet/red_planet_props.json"
const INTERIOR := "res://scenes/interior.tscn"

var terrain: MapTerrain
var doors: Array[AirlockDoor] = []

@onready var player: Player = $Actors/Player
@onready var multitool: Multitool = $Multitool
@onready var wind: WindFX = $WindFX
@onready var map_screen: MapScreen = $MapScreen
@onready var dome_fx: DomeFX = $DomeFX
@onready var biome_fx: BiomeFX = $BiomeFX
@onready var crash: CrashSite = $CrashSite
@onready var ambience: WorldAmbience = $Ambience


func _ready() -> void:
	Audio.debug = _args().has("audio-debug")
	Audio.enter_scene()
	terrain = MapTerrain.new(MAP_JSON)
	player.setup(terrain, DEPTH_MAP)
	player.camera.frames = terrain.frames
	player.camera.setup(player, $Map, terrain.max_view_px)
	wind.setup(player.camera, _biome_here)
	map_screen.setup(MAP_JSON, player)
	dome_fx.setup(MAP_JSON)
	biome_fx.setup(MAP_JSON, player.camera, DEPTH_MAP, terrain.map_size, player)
	crash.setup(MAP_JSON, player.camera, player, biome_fx)
	ambience.setup(MAP_JSON, player.camera, player, _biome_here)
	player.step_source = _step_sound
	multitool.setup(PROPS_JSON, player, terrain, $Actors, DEPTH_MAP)
	_setup_doors()
	var inventory_ui := InventoryUI.new()
	add_child(inventory_ui)
	inventory_ui.setup(player, multitool)
	if GameState.tool_out:
		player.set_tool_out(true)
	var args := _args()
	var arriving := GameState.arrive == "door"
	if arriving:
		for d in doors:
			if d.get_meta("id") == GameState.door_id:
				d.arrive()
	GameState.arrive = ""
	var skip := args.has("no-intro") or args.has("spawn") or args.has("walk") or GameState.intro_done or arriving
	if args.has("intro") or not skip:
		crash.finished.connect(func() -> void: GameState.intro_done = true)
		crash.play_intro()
	else:
		GameState.intro_done = true
	_run_test_hooks(args)


func _biome_here() -> Vector3:
	return terrain.biome_at(player.world_pos)


## What the boots are landing on, from the land the astronaut is standing in. The biome image
## is the same one that crossfades the weather and the ambience, so the surface the ear hears
## is the surface the eye sees.
func _step_sound() -> String:
	var w := terrain.biome_at(player.world_pos)
	if w.z > w.x and w.z > w.y:
		return "step_snow"
	if w.y > w.x:
		return "step_moss"
	return "step_dust"


## The base's airlock doors: F to go inside.
func _setup_doors() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MAP_JSON))
	if not meta.has("fx"):
		return
	var fx_path := MAP_JSON.get_base_dir().path_join(meta["fx"])
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(fx_path))
	for info in fx.get("doors", []):
		var d := AirlockDoor.new()
		$Actors.add_child(d)
		d.setup(info, MAP_JSON.get_base_dir(), player, player.camera, terrain, multitool, "ENTER")
		d.set_meta("id", int(info["id"]))
		d.entered.connect(_go_inside.bind(int(info["id"])))
		doors.append(d)


func _go_inside(id: int) -> void:
	GameState.arrive = "interior"
	GameState.door_id = id
	GameState.tool_out = player.tool_state == Player.Tool.READY
	get_tree().change_scene_to_file(INTERIOR)


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
	if args.has("quit"):
		_quit_after(float(args["quit"]))
	if args.has("spawn"):
		var xy: PackedStringArray = args["spawn"].split(",")
		player.teleport(Vector2(float(xy[0]), float(xy[1])))
	if args.has("walk"):
		var w: PackedStringArray = args["walk"].split(",")
		player.forced_input = Vector2(float(w[0]), float(w[1]))
		player.forced_run = w.size() > 2 and w[2] == "run"
	if args.has("zoom"):
		player.camera.set_level(int(args["zoom"]))
	if args.has("jump-every"):
		player.auto_jump_every = float(args["jump-every"])
	if args.has("face"):
		var f: PackedStringArray = args["face"].split(",")
		var sd := Vector2(float(f[0]), float(f[1]))
		player.facing = Player.DIRS[posmod(int(round(sd.angle() / (PI / 4.0))), 8)]
	if args.has("door") and not doors.is_empty():
		var nearest: AirlockDoor = doors[0]
		for d in doors:
			if d.stand_point().distance_to(player.world_pos) < nearest.stand_point().distance_to(player.world_pos):
				nearest = d
		get_tree().create_timer(0.5).timeout.connect(func() -> void: nearest.call("_start"))
	if args.has("equip"):
		get_tree().create_timer(0.3).timeout.connect(player.toggle_tool)
	if args.has("use"):
		get_tree().create_timer(1.2).timeout.connect(func() -> void: multitool.forced_use = true)
	if args.has("open-map"):
		get_tree().create_timer(1.0).timeout.connect(map_screen.toggle)
	if not args.has("capture") or args.has("door"):     # --door: the interior takes the pictures
		return
	await get_tree().create_timer(float(args.get("seconds", "1.5"))).timeout
	if args.has("debug"):
		var p := player.world_pos
		var depth_img := DEPTH_MAP.get_image()
		var sp := Vector2i(player.position)
		var c := depth_img.get_pixelv(sp)
		var map_depth := (roundf(c.r * 255.0) * 256.0 + roundf(c.g * 255.0)) / terrain.depth_scale
		print("fps ", Engine.get_frames_per_second(), " player world ", p, " ground z ", terrain.height_at(p),
				" biome ", terrain.biome_at(p),
				" screen ", player.position, " map depth under feet ", map_depth)
	var path: String = args["capture"]
	var count := int(args.get("burst", "1"))
	var gap := float(args.get("gap", "0.12"))
	for i in count:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(path if count == 1 else path.get_basename() + "_%d.png" % i)
		if i < count - 1:
			await get_tree().create_timer(gap).timeout
	await Audio.quit()
