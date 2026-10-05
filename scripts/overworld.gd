extends Node2D
## The red planet overworld: the pre-rendered map with the astronaut walking on it.
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

const MAP_JSON := "res://assets/maps/red_planet/red_planet_map.json"
const DEPTH_MAP: Texture2D = preload("res://assets/maps/red_planet/red_planet_depth.png")

var terrain: MapTerrain

@onready var player: Player = $Player
@onready var wind: WindFX = $WindFX
@onready var map_screen: MapScreen = $MapScreen
@onready var dome_fx: DomeFX = $DomeFX


func _ready() -> void:
	terrain = MapTerrain.new(MAP_JSON)
	player.setup(terrain, DEPTH_MAP)
	player.camera.frames = terrain.frames
	player.camera.setup(player, $Map, terrain.max_view_px)
	wind.setup(player.camera)
	map_screen.setup(MAP_JSON, player)
	dome_fx.setup(MAP_JSON)
	_run_test_hooks()


func _run_test_hooks() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
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
	if args.has("open-map"):
		get_tree().create_timer(1.0).timeout.connect(map_screen.toggle)
	if not args.has("capture"):
		return
	await get_tree().create_timer(float(args.get("seconds", "1.5"))).timeout
	if args.has("debug"):
		var p := player.world_pos
		var depth_img := DEPTH_MAP.get_image()
		var sp := Vector2i(player.position)
		var c := depth_img.get_pixelv(sp)
		var map_depth := (roundf(c.r * 255.0) * 256.0 + roundf(c.g * 255.0)) / terrain.depth_scale
		print("player world ", p, " ground z ", terrain.height_at(p), " screen ", player.position,
				" map depth under feet ", map_depth)
	var path: String = args["capture"]
	var count := int(args.get("burst", "1"))
	for i in count:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(path if count == 1 else path.get_basename() + "_%d.png" % i)
		if i < count - 1:
			await get_tree().create_timer(0.12).timeout
	get_tree().quit()
