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
##   --survival-debug / --vitals=H,O,F,W / --survival-speed=N (see SurvivalHUD)
##   --dev-panel / --dev-freeze=hunger,thirst,oxygen   master control panel (F1; see DevPanel)
##   --audio-debug          print every sound as it plays (there is no screenshot for sound)
##   --perf                 print texture memory, draw calls and frame times once a second
##   --perf-every=SECONDS   how often --perf prints (default 1.0)
##   --quit=SECONDS         run for this long, then shut the sound down and quit cleanly
##   --turn=N               start with the camera turned N quarter turns round (G / H turn it)
##   --turn-left / --turn-right   turn the camera once after a second (see ViewTurn)
##   --dome-mended=ROOM     that base room's dome glass is whole again (command: storage's windows mended)
##   --solar-at=ID          stand beside A SUN/B SUN/C SUN or reflector A1..C4
##   --solar-active / --solar-solved   optical routing capture hooks (ordinary feeds start off)

const MAP_JSON := "res://assets/maps/red_planet/red_planet_map.json"
const PROPS_JSON := "res://assets/maps/red_planet/red_planet_props.json"
const INTERIOR := "res://scenes/interior.tscn"

var terrain: MapTerrain
var doors: Array[AirlockDoor] = []
var view_turn: ViewTurn
var stream: MapStream
var solar: SolarField

@onready var player: Player = $Actors/Player
@onready var multitool: Multitool = $Multitool
@onready var wind: WindFX = $WindFX
@onready var map_screen: MapScreen = $MapScreen
@onready var dome_fx: DomeFX = $DomeFX
@onready var biome_fx: BiomeFX = $BiomeFX
@onready var crash: CrashSite = $CrashSite
@onready var day_night: DayNight = $DayNight
@onready var ambience: WorldAmbience = $Ambience


func _ready() -> void:
	Audio.debug = _args().has("audio-debug")
	Audio.enter_scene()
	if _args().has("turn"):
		GameState.heading = posmod(int(_args()["turn"]), 4)
	terrain = MapTerrain.new(MAP_JSON, GameState.heading)
	var view := terrain.view_json
	player.setup(terrain)
	player.camera.frames = terrain.frames
	player.camera.setup(player, $Map, terrain.max_view_px, terrain.streaming)
	# The window has to exist before anything that samples the depth map is set up, and it is
	# built around where the camera is, so it comes straight after the camera.
	stream = MapStream.new()
	add_child(stream)
	stream.setup(terrain, $Map, player.camera, player)
	stream.published.connect(_window_moved)
	$Map.texture = terrain.map_texture
	wind.setup(player.camera, _biome_here)
	map_screen.setup(view, player)
	dome_fx.setup(view)
	biome_fx.setup(view, player.camera, terrain, player)
	crash.setup(view, player.camera, player, biome_fx)
	ambience.setup(view, player.camera, player, _biome_here)
	player.step_source = _step_sound
	multitool.setup(PROPS_JSON, player, terrain, $Actors)
	day_night.setup(player, $Map, terrain.light_mask)
	_setup_doors()
	solar = SolarField.new()
	add_child(solar)
	solar.setup(player, multitool, terrain, $Actors)
	view_turn = ViewTurn.new()
	add_child(view_turn)
	view_turn.setup(terrain, player, _apply_view, _turn_boards, stream)
	var inventory_ui := InventoryUI.new()
	add_child(inventory_ui)
	inventory_ui.setup(player, multitool)
	var survival_hud := SurvivalHUD.new()
	add_child(survival_hud)
	survival_hud.setup(player, multitool)
	var dev_panel := DevPanel.new()                    # F1, debug builds: time and frozen needs
	add_child(dev_panel)
	dev_panel.setup(player)
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
		day_night.clock_panel.visible = false            # the time panel comes in once the crash is over
		crash.finished.connect(func() -> void:
			day_night.clock_panel.visible = true
			day_night.clock_panel.announce("DAY %d" % DayNight.day))
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


## The camera turned round the world: switch the whole scene to that view. The world itself
## (positions, props, the clock, sounds) carries on; only how it is drawn changes.
func _apply_view(k: int, world_facing: Vector2) -> void:
	terrain.load_view(k)
	var view := terrain.view_json
	player.refresh_view(world_facing)
	player.camera.set_view_limits(terrain.max_view_px, terrain.frames)
	stream.refresh(true)                                 # the window, once the camera is where
	$Map.texture = terrain.map_texture                   # this view puts it - not before
	day_night.set_masks(terrain.light_mask)
	map_screen.load_view(view)
	dome_fx.load_view(view)
	biome_fx.load_view(view)
	crash.load_view(view)
	ambience.load_view(view)
	multitool.set_view()
	solar.load_view()
	for d in doors:
		d.queue_free()
	doors.clear()
	_setup_doors()


## The window has moved under the world (MapStream): everything that samples the depth map has
## to be told where it is now. Same fan-out as a view switch, and for the same reason.
func _window_moved(_heading: int) -> void:
	player.refresh_window()
	biome_fx.refresh_window()
	multitool.refresh_window()
	solar.refresh_window()


## What stands in the world, for the camera's swing: the plants in view, the loose props and
## the domes' moving parts.
func _turn_boards() -> Array:
	var out := []
	for p in biome_fx.visible_plants():
		out.append(ViewTurn.plant_board(terrain, p))
	for n in $Actors.get_children():
		if n is WorldProp and not (n as WorldProp).gone:
			out.append(ViewTurn.prop_board(terrain, n))
	out.append_array(dome_fx.boards())
	out.append_array(solar.beam_boards())
	return out


## The base's airlock doors: F to go inside.
func _setup_doors() -> void:
	var meta := ViewData.get_json(terrain.view_json)
	if not meta.has("fx"):
		return
	var fx := ViewData.fx_of(terrain.view_json, meta)
	for info in fx.get("doors", []):
		var d := AirlockDoor.new()
		$Actors.add_child(d)
		d.setup(info, terrain.view_json.get_base_dir(), player, player.camera, terrain, multitool, "ENTER")
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
	PerfProbe.attach(self, args)
	if args.has("quit"):
		_quit_after(float(args["quit"]))
	if args.has("solar-active") or args.has("solar-solved"):
		for group in solar.state.feeds.size():
			if not solar.state.feeds[group]:
				solar.state.toggle_feed(group)
	if args.has("solar-solved"):
		for group in solar.state.field["routes"].size():
			var route: Dictionary = solar.state.field["routes"][group]
			for index in route["mirrors"].size():
				var point := SolarOptics.point(route["mirrors"][index])
				var before := SolarOptics.point(route["source"] if index == 0 else route["mirrors"][index - 1])
				var after := SolarOptics.point(solar.state.field["collector"]["world"] if index + 1 == route["mirrors"].size() else route["mirrors"][index + 1])
				var id: String = route["id"] + str(index + 1)
				var angle := SolarOptics.alignment(point - before, after - point)
				while solar.state.orientations[id] != angle:
					solar.state.rotate(id)
	if args.has("solar-at") and solar.equipment.has(args["solar-at"]):
		player.teleport(solar.interaction_point(args["solar-at"]))
	if args.has("dome-mended"):
		GameState.window_repair.dome_mended = args["dome-mended"]
		dome_fx.load_view(terrain.view_json)
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
		var depth_img := terrain.depth_map.get_image()
		var sp := Vector2i(player.position) - terrain.window.position
		var c := depth_img.get_pixelv(sp.clamp(Vector2i.ZERO, terrain.window.size - Vector2i.ONE))
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
