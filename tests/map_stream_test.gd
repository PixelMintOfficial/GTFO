extends Node
## Checks for the map window (MapStream), against the real overworld.
##
## The window is the only part of the map in memory, so two things must always hold: it covers
## everything the camera can show (or the player would walk into ground that is not there), and
## the pixels in it are the pixels the generator wrote (or the depth map would hide the
## astronaut in the wrong places). Walking, running, jumping, teleporting, zooming and turning
## all move the window; each is checked here.
## Run: godot --headless --path . res://tests/map_stream_test.tscn  (failures exit nonzero)

var _checks := 0
var _failures := 0


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("MAP STREAM TEST: " + label)


func _ready() -> void:
	GameState.intro_done = true
	GameState.heading = 0
	await _overworld()
	await _interior()
	print("MAP STREAM TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


## What the camera can actually show, in map pixels.
func _seen(camera: GameCamera) -> Rect2:
	var size := camera.view_size()
	return Rect2(camera.get_screen_center_position() - size * 0.5, size)


func _covers(world: Node, where: String) -> void:
	var terrain: MapTerrain = world.terrain
	if not terrain.streaming:
		return
	var seen := _seen(world.player.camera)
	var win := Rect2(terrain.window)
	_check(win.encloses(seen.grow(-1.0)), "%s: the window %s covers what the camera shows %s" % [where, win, seen])


func _overworld() -> void:
	var world := load("res://scenes/overworld.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(world)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	var terrain: MapTerrain = world.terrain
	_check(terrain.streaming, "the overworld's map is streamed from tiles")
	_check(terrain.window.get_area() > 0, "it has a window")
	_check(terrain.window.get_area() < terrain.map_size.x * terrain.map_size.y * 0.5,
			"the window is a part of the map, not all of it (%s of %s)" % [terrain.window.size, terrain.map_size])
	_covers(world, "at the spawn")
	_pixels(world)

	for level in [1, 2, 3, 0]:                           # every zoom, growing and shrinking again
		world.player.camera.set_level(level)
		for i in 40:
			await get_tree().process_frame
		_covers(world, "at zoom %d" % level)

	world.player.forced_input = Vector2(1, 0)            # walk out of the window and on
	for i in 240:
		await get_tree().process_frame
		if i % 40 == 0:
			_covers(world, "while walking")
	world.player.forced_input = Vector2.ZERO
	await get_tree().process_frame

	world.player.teleport(Vector2(250.0, 2500.0))        # the forest, far from anything stitched
	await get_tree().process_frame
	await get_tree().process_frame
	_covers(world, "after a teleport")
	_pixels(world)

	for step in [KEY_H, KEY_G]:                          # turn, and come back
		await _tap(step)
		for i in 400:
			if not world.view_turn.busy:
				break
			await get_tree().process_frame
		await get_tree().process_frame
		_covers(world, "after turning")
	_pixels(world)
	world.queue_free()
	for i in 4:                                          # let the scene and its textures go
		await get_tree().process_frame


## The window holds what the generator wrote: compare points in it against their own tile.
func _pixels(world: Node) -> void:
	var terrain: MapTerrain = world.terrain
	var tiles: Dictionary = terrain.tiles_in(terrain.heading)
	if tiles.is_empty():
		return
	var size: int = tiles["tile"][0]
	var dir: String = terrain.views[terrain.heading].get_base_dir()
	var win := terrain.window
	var rs := RandomNumberGenerator.new()
	rs.seed = 11
	for layer in ["map", "depth", "light"]:
		var spec: Dictionary = tiles["layers"][layer]
		var tex: Texture2D = terrain.map_texture if layer == "map" else \
				(terrain.depth_map if layer == "depth" else terrain.light_mask)
		var got := tex.get_image()
		var wrong := 0
		for i in 60:
			var at := Vector2i(rs.randi_range(win.position.x, win.end.x - 1), rs.randi_range(win.position.y, win.end.y - 1))
			var want := _tile_pixel(spec, dir, size, at)
			var have := got.get_pixelv(at - win.position)
			if absf(want.r - have.r) > 0.002 or absf(want.g - have.g) > 0.002 or absf(want.b - have.b) > 0.002:
				wrong += 1
		_check(wrong == 0, "view %d %s: %d of 60 window pixels differ from their tile" % [terrain.heading, layer, wrong])


## One map pixel, read from the tile the generator put it in (or its fill, if it left it out).
func _tile_pixel(spec: Dictionary, dir: String, size: int, at: Vector2i) -> Color:
	var tx := at.x / size
	var ty := at.y / size
	for t in spec["present"]:
		if int(t[0]) == tx and int(t[1]) == ty:
			var img: Image = load(dir.path_join(spec["dir"]).path_join(t[2]))
			return img.get_pixelv(at - Vector2i(tx * size, ty * size))
	for odd in spec.get("fills", []):
		if int(odd[0]) == tx and int(odd[1]) == ty:
			return MapStream._colour(odd[2])
	return MapStream._colour(spec["fill"])


func _interior() -> void:
	var inside := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(inside)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	var terrain: MapTerrain = inside.terrain
	_check(not terrain.streaming, "the interior is small enough to keep whole")
	_check(terrain.window == Rect2i(Vector2i.ZERO, Vector2i(terrain.map_size)),
			"its window is the whole map, so the same shaders work unchanged")
	_check(terrain.depth_map != null and terrain.map_texture != null, "it still has its own pictures")
	inside.queue_free()
	for i in 4:
		await get_tree().process_frame


func _tap(code: int) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
