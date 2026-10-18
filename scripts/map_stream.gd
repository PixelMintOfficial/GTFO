class_name MapStream
extends Node
## Only as much of the map as the camera can see is in memory.
##
## A view of the overworld is 7751x4350: its picture, depth map and light mask together are
## ~240 MB, and three views are kept so a turn never waits for the disk (§4.9). That was over a
## gigabyte of textures, which on a machine with an integrated GPU is a gigabyte of the
## player's RAM.
##
## The generator now writes each layer as 512 px tiles (`tiles` in the view JSON) and this
## stitches a window around the camera out of them, one per resident view: the picture the Map
## sprite draws, the depth map the occlusion shaders sample, and the light mask. The window
## covers the camera's view plus the margin the turn's swing needs, so it is small at the
## default zoom and grows as you zoom out - the memory follows what you can see rather than how
## big the world is.
##
## Tiles are imported as Images, never as textures, so stitching is pure CPU work and nothing
## but the finished window ever reaches the GPU. A tile the generator left out is a run of one
## colour (sky, mostly): the window is filled with that colour before anything is blitted in.
##
## Test hooks (after "--"): --stream-debug prints every window as it is built; --no-stream
## loads the whole pictures instead, which is what the game did before the windows existed and
## is there so the two can be measured against each other in one build.

## Emitted after a view's window has been rebuilt and published. The scene re-pushes the
## shader uniforms that point at it, the way _apply_view does on a turn.
signal published(heading: int)

## How far beyond what the swing needs a window reaches, map px. Bigger means more memory and
## fewer rebuilds; the camera has to leave this band before anything is stitched again.
const PAD := 128
## Window edges are kept on a multiple of this, so a window that moves lands on the same
## pixel grid it had before.
const SNAP := 16

var terrain: MapTerrain
var debug := false

var _map: Sprite2D
var _camera: GameCamera
var _player: Player
var _windows := {}               # heading -> {rect: Rect2i, map/depth/light: Texture2D}
var _job := -1                   # 1 while a window's tiles are loading in the background
var _job_view := 0
var _job_rect := Rect2i()
var _job_paths: Array[String] = []


func setup(t: MapTerrain, map: Sprite2D, camera: GameCamera, player: Player) -> void:
	terrain = t
	_map = map
	_camera = camera
	_player = player
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stream-debug"):
			debug = true
	refresh(true)


## Is this view's window ready to be shown? A turn waits for it (ViewTurn.request).
func ready_for(k: int) -> bool:
	var h := posmod(k, 4)
	return not terrain.streaming or (_windows.has(h) and _windows[h]["rect"].encloses(_need(h)))


## Rebuild whatever has gone out of date.
##
## Stitching a window is tens of milliseconds, and three views go out of date together when the
## camera moves, so only one is rebuilt per call - the one being looked at first, then the two
## the player might turn to. The old windows stay on screen meanwhile, so a rebuild is never
## something you can see; a turn simply waits for its view (ViewTurn.request).
##
## `force` means "do not defer": any window that is out of date is stitched here and now, for
## the moments where there is no time to wait - the scene opening, a teleport, the view switch
## in the middle of a turn. It does not restitch a window that already covers what it needs,
## which is why turning to a view that was a neighbour a moment ago costs nothing.
func refresh(force := false) -> void:
	if not terrain.streaming:
		return
	if force:
		_drop_job()                          # whatever was coming, this pass overtakes it
	elif _collect():
		return                               # a stitch landed this frame; one is enough
	var want := {}
	for d in [0, -1, 1]:
		var h := posmod(terrain.heading + d, 4)
		want[h] = true
		var need := _need(h)
		var have: Rect2i = _windows[h]["rect"] if _windows.has(h) else Rect2i()
		if have.encloses(need):
			continue                         # already covered, even if this is a forced pass
		# Covering what the camera can see this instant is not negotiable: ground that is not
		# in the window is ground that is not drawn. If that is what has gone wrong - the view
		# zoomed out, the astronaut was put down somewhere else - stitch here and now and take
		# the hitch. Otherwise there is still margin in hand, so let a worker do it.
		if force or (h == terrain.heading and not have.encloses(_seen())):
			_finish(h, need, _stitch_all(h, need))
			if h == terrain.heading:
				_publish()
		elif _job < 0:
			_start(h, need)
	for h in _windows.keys():
		if not want.has(h):
			_windows.erase(h)
	if force:
		_publish()


## Ask for the tiles a window needs, in the background.
##
## Decoding them is a couple of hundred milliseconds, far too much to spend on the frame the
## player is looking at, and there is no hurry: the window already on screen covers what the
## camera shows for another PAD pixels of walking. The engine's own background loader does the
## decoding; once the tiles are in, stitching them is a few MB of memcpy, which is cheap enough
## to do here. (Calling load() on a worker thread instead would be simpler, and leaks: the
## resource stays in the engine's books after the last reference to it is gone.)
func _start(k: int, rect: Rect2i) -> void:
	_job_view = k
	_job_rect = rect
	_job_paths = []
	var tiles: Dictionary = terrain.tiles_in(k)
	var dir: String = terrain.views[k].get_base_dir()
	var size: int = tiles["tile"][0]
	for layer in ["map", "depth", "light"]:
		var spec: Dictionary = tiles["layers"][layer]
		var base: String = dir.path_join(spec["dir"])
		for t in spec["present"]:
			if Rect2i(int(t[0]) * size, int(t[1]) * size, size, size).intersection(rect).has_area():
				_job_paths.append(base.path_join(t[2]))
	for path in _job_paths:
		ResourceLoader.load_threaded_request(path)
	_job = 1


## Stitch the window once every tile it needs has come in. Returns whether it published.
func _collect() -> bool:
	if _job < 0:
		return false
	for path in _job_paths:
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			return false
	_job = -1
	_finish(_job_view, _job_rect, _stitch_all(_job_view, _job_rect))
	_job_paths = []
	if _job_view == terrain.heading:
		_publish()
	return true


## Every layer of one view's window, as Images.
func _stitch_all(k: int, rect: Rect2i) -> Dictionary:
	var tiles: Dictionary = terrain.tiles_in(k)
	var dir: String = terrain.views[k].get_base_dir()
	var out := {}
	for layer in ["map", "depth", "light"]:
		out[layer] = _stitch(tiles, layer, dir, rect)
	return out


func _process(_delta: float) -> void:
	# Not during a turn's swing. The overlay is holding this view's textures and the one it is
	# turning to, and a rebuild writes over a window's pixels in place - which the player would
	# see as the ground changing under the swing. Nothing moves during a turn anyway: the
	# astronaut stands still, so the window cannot go out of date while it lasts.
	if _player != null and _player.turning:
		return
	refresh()


## What the camera can actually show right now, in map pixels.
func _seen() -> Rect2i:
	var size := _camera.view_size()
	var r := Rect2(_camera.get_screen_center_position() - size * 0.5, size)
	return Rect2i(r.position.floor(), r.size.ceil() + Vector2.ONE) \
			.intersection(Rect2i(Vector2i.ZERO, terrain.size_in(terrain.heading)))


## The part of this view the window has to cover: what the camera shows, grown by the margin
## the turn's swing lays out, and then by PAD so walking does not restitch every step.
func _need(k: int) -> Rect2i:
	var view := _camera.target_view_size()
	var centre := _camera.centre_in(terrain, k, _player)
	var margin := view * (0.5 + TurnOverlay.MARGIN) + Vector2(PAD, PAD)
	# Snap the two corners outwards, not the corner and the size: rounding a position down and
	# a size up can still leave the far edge short of what was asked for.
	var from := _snap(centre - margin, -1)
	var to := _snap(centre + margin, 1)
	return Rect2i(from, to - from).intersection(Rect2i(Vector2i.ZERO, terrain.size_in(k)))


## A corner on the window grid, rounded away from the middle (`away` is -1 or 1).
static func _snap(p: Vector2, away: int) -> Vector2i:
	if away < 0:
		return Vector2i(floori(p.x / SNAP) * SNAP, floori(p.y / SNAP) * SNAP)
	return Vector2i(ceili(p.x / SNAP) * SNAP, ceili(p.y / SNAP) * SNAP)


## Turn a stitch into this view's window. The GPU side, so it is the main thread's half.
func _finish(k: int, rect: Rect2i, images: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var old: Dictionary = _windows.get(k, {})
	var win := {"rect": rect}
	for layer in ["map", "depth", "light"]:
		# Reuse the texture when the window has only moved, not changed size: update() writes
		# over the pixels the GPU already has instead of allocating a second one beside it.
		var tex: ImageTexture = old.get(layer)
		if tex != null and tex.get_size() == Vector2(rect.size):
			tex.update(images[layer])
		else:
			tex = ImageTexture.create_from_image(images[layer])
		win[layer] = tex
	_windows[k] = win
	if debug:
		print("[stream] view %d window %s (%.1f MB) uploaded in %.1f ms" % [k, rect,
				rect.size.x * rect.size.y * 7.0 / 1048576.0, (Time.get_ticks_usec() - t0) / 1000.0])


## One layer's window: the fill colour everywhere the generator left a tile out, with every
## tile that does exist blitted over it.
func _stitch(tiles: Dictionary, layer: String, dir: String, rect: Rect2i) -> Image:
	var spec: Dictionary = tiles["layers"][layer]
	var size: int = tiles["tile"][0]
	var fill: Array = spec["fill"]
	var fmt := Image.FORMAT_L8 if fill.size() == 1 else Image.FORMAT_RGB8
	var img := Image.create_empty(rect.size.x, rect.size.y, false, fmt)
	img.fill(_colour(fill))
	for odd in spec.get("fills", []):          # the few constant tiles that are not the usual fill
		var at := Rect2i(int(odd[0]) * size, int(odd[1]) * size, size, size).intersection(rect)
		if at.has_area():
			img.fill_rect(Rect2i(at.position - rect.position, at.size), _colour(odd[2]))
	var base: String = dir.path_join(spec["dir"])
	for t in spec["present"]:
		var at := Rect2i(int(t[0]) * size, int(t[1]) * size, size, size).intersection(rect)
		if not at.has_area():
			continue
		# Already decoded by the background loader (see _start), so this is a cache hit; it
		# is only a real read when a window is stitched on the spot.
		var res := _take(base.path_join(t[2]))
		if not res is Image:
			push_error("MapStream: %s did not load as an Image" % t[2])
			continue
		var tile: Image = res
		var src := Rect2i(at.position - Vector2i(int(t[0]) * size, int(t[1]) * size), at.size)
		img.blit_rect(tile, src, at.position - rect.position)
	return img


## A tile's pixels, taking the background load if one is outstanding. A threaded request that
## is never collected is reported as a leak at shutdown, so every path asked for goes through
## here exactly once.
func _take(path: String) -> Resource:
	if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		return load(path)
	return ResourceLoader.load_threaded_get(path)


## The window as a shader uniform: where it starts in map pixels, and how big it is.
## Is streaming switched off for this run (--no-stream)? Read once; the command line does not
## change while the game is running.
static func disabled() -> bool:
	if _off == -1:
		_off = 1 if OS.get_cmdline_user_args().has("--no-stream") else 0
	return _off == 1


static var _off := -1


static func win_vec(terrain: MapTerrain) -> Vector4:
	var r := terrain.window
	return Vector4(r.position.x, r.position.y, r.size.x, r.size.y)


## Point one material at the current window.
static func bind(mat: ShaderMaterial, terrain: MapTerrain) -> void:
	mat.set_shader_parameter("depth_map", terrain.depth_map)
	mat.set_shader_parameter("map_win", win_vec(terrain))


static func _colour(c: Array) -> Color:
	return Color8(c[0], c[0], c[0]) if c.size() == 1 else Color8(c[0], c[1], c[2])


## Hand the current view's window to the Map sprite and tell the scene to re-point its shaders.
func _publish() -> void:
	var win: Dictionary = _windows.get(terrain.heading, {})
	if win.is_empty():
		return
	terrain.set_window(win["rect"], win["map"], win["depth"], win["light"])
	_map.texture = win["map"]
	_map.position = Vector2(win["rect"].position)
	published.emit(terrain.heading)


func _exit_tree() -> void:
	_drop_job()
	# Let the windows go here rather than leave it to the order the scene happens to be torn
	# down in: the shaders and the Map sprite hold the same textures, and whichever outlives
	# the other keeps them alive past the end of the scene.
	_windows.clear()
	if terrain != null:
		terrain.set_window(Rect2i(), null, null, null)
	if _map != null:
		_map.texture = null


## Let go of a background load without using it. Every path asked for has to be taken, even
## when its window is no longer wanted: a threaded request nobody collects is reported as a
## leak when the engine shuts down.
func _drop_job() -> void:
	for path in _job_paths:
		_take(path)
	_job_paths = []
	_job = -1


## What TurnOverlay needs to lay a view's picture out: its window and the three textures.
func window_of(k: int) -> Dictionary:
	return _windows.get(posmod(k, 4), {})
