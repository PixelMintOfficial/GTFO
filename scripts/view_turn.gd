class_name ViewTurn
extends Node
## Turning the camera round the world, Don't Starve style. G turns the view to the left, H to
## the right (gamepad: d-pad left / right): a quarter turn each press, in a short eased swing
## round the astronaut, who stands still while it lasts. The world itself doesn't move, only
## the view of it: the map is rendered once per view, and a turn switches the scene to the next
## view (MapTerrain.load_view, then every system's load_view, through `apply`) while
## TurnOverlay covers the switch with the swing.
##
## Turns wait for a calm moment: not in a cutscene, a modal, mid-jump, while the tool is being
## drawn or at work. The next views' pictures load in the background ahead of time, so a turn
## never waits for the disk. A press during a swing is kept and played straight after it.
##
## Test hooks (after "--"): --turn=N (start N quarter turns round; read by the scene),
## --turn-left / --turn-right (turn once after a second, for captures).

signal turned(heading: int)

## How long a quarter turn's swing takes, seconds.
@export var turn_time := 0.42

var terrain: MapTerrain
## The window the view is stitched into; a turn waits for the view it is turning to.
var stream: MapStream
var player: Player
var camera: GameCamera
## (heading: int, world_facing: Vector2) -> void: switch the scene to that view.
var apply: Callable
## () -> Array of things standing in the world to show in the swing (see TurnOverlay._board).
var boards: Callable
## True from the moment a turn is accepted until its swing has finished - including the moment
## it may spend waiting for the next view's pictures. Anything that waits for a turn to be over
## waits on this.
var busy := false

## How long a turn waits for its view's pictures to arrive in the background before it gives up
## and loads them itself, seconds. Only reached if the disk is very slow or the press came
## straight after another turn.
const WISH_PATIENCE := 8.0

var _pending := 0
var _keep := {}                  # resource path -> resource: views kept loaded
var _paths_of := {}              # view JSON -> the files that view needs
var _overlay: TurnOverlay
var _wish := 0                   # a press waiting for its view's pictures to load
var _wish_left := 0.0


func setup(t: MapTerrain, p: Player, apply_view: Callable, board_source := Callable(),
		map_stream: MapStream = null) -> void:
	terrain = t
	stream = map_stream
	player = p
	camera = p.camera
	apply = apply_view
	boards = board_source
	_ensure_actions()
	_overlay = TurnOverlay.new()
	add_child(_overlay)
	_preload_around(terrain.heading)
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if args.has("turn-left") or args.has("turn-right"):
		get_tree().create_timer(float(args.get("turn-at", "1.0"))).timeout.connect(request.bind(-1 if args.has("turn-left") else 1))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("turn_left"):
		request(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("turn_right"):
		request(1)
		get_viewport().set_input_as_handled()


## Turn a quarter turn: -1 to the left, +1 to the right.
##
## A press whose view is not in memory yet is kept, not waited for. The turn used to force the
## load, which froze the frame for up to two seconds when two turns came close together: a
## view's pictures are hundreds of MB and the background load has not finished that soon after
## the last turn. The press fires from _process once the pictures are there, or is dropped if
## they take so long that the player has plainly moved on.
func request(step: int) -> void:
	if terrain == null or terrain.views.size() < 4:
		return
	if busy:
		_pending = step
		return
	if not can_turn():
		return
	busy = true
	_wish = step
	_wish_left = WISH_PATIENCE
	_start_wish()


## Start the waiting turn if its view's pictures have arrived. Returns whether it started.
func _start_wish() -> bool:
	if _wish == 0 or not _loaded(posmod(terrain.heading + _wish, 4)):
		return false
	if not can_turn():
		return false                         # mid-jump or in a modal: hold it a moment longer
	_turn(_wish)
	return true


## Load a view's pictures here and now. The last resort when the background load has not come
## through: a turn the player asked for must happen, so a hitch is better than losing it.
func _force_loaded(k: int) -> void:
	for path in _paths(k):
		if _keep.get(path) == null:
			_keep[path] = ResourceLoader.load_threaded_get(path) \
					if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE \
					else load(path)


## Play a press that came in while a turn was running.
func _replay_pending() -> void:
	if _pending == 0:
		return
	var again := _pending
	_pending = 0
	request(again)


func can_turn() -> bool:
	return (player.controls_enabled and not player.puppet and not player.turning and not player.is_airborne()
			and player.work_target == null and not get_tree().paused
			and (player.tool_state == Player.Tool.HOLSTERED or player.tool_state == Player.Tool.READY))


func _turn(step: int) -> void:
	_wish = 0
	player.turning = true
	var to_k := posmod(terrain.heading + step, 4)
	var from := TurnOverlay.view_info(terrain, camera, player)
	var pivot := Vector3(player.world_pos.x, player.world_pos.y, terrain.height_at(player.world_pos))
	var things: Array = boards.call() if boards.is_valid() else []
	_overlay.begin(from, from, step, pivot, things, player, turn_time)
	apply.call(to_k, player.facing_dir())                 # the world switches under the overlay
	GameState.heading = to_k
	var arrival := TurnOverlay.view_info(terrain, camera, player)
	_overlay.set_arrival(arrival, boards.call() if boards.is_valid() else [])   # this side's sprites
	await _overlay.finished
	player.turning = false
	busy = false
	turned.emit(to_k)
	_preload_around(to_k)
	_replay_pending()


# ---------------------------------------------------------------- loading the views ahead
## Every picture a view needs: the map's own four, and each system's sprite sheets.
##
## A turn calls every system's load_view() in one frame, and each of those used to load() its own
## sheets off the disk then and there - 44 flora sheets, the dome's animated parts (the comms dish
## alone is 5976x249), the crash wreck, the minimap, the doors. Loading them ahead with the map
## keeps the disk out of the turn entirely. It is not where most of the turn's time went (that was
## the forced load this file used to do, and rebinding the map's own huge textures), but it is the
## part that was unbounded: a cold cache could add a hundred milliseconds of PNG decode.
func _paths(k: int) -> Array[String]:
	# Keyed by the view's own JSON, not by its heading: the interior swaps every view for a
	# repaired one (MapTerrain.replace_variant), and those are different files.
	var path := terrain.views[posmod(k, terrain.views.size())]
	if _paths_of.has(path):
		return _paths_of[path]               # worked out once: a view's files do not change
	var out: Array[String] = []
	var meta := ViewData.get_json(path)
	if meta.is_empty():
		return out                           # not cached: a missing view may just be a slow disk
	var dir := path.get_base_dir()
	var game: Dictionary = meta["game"]
	if not terrain.streaming:
		# A streamed map's picture, depth and light are stitched from tiles by MapStream, which
		# keeps only a window of them. Loading the whole ones here would put back the gigabyte
		# the streaming is there to remove.
		if meta.has("image"):
			out.append(dir.path_join(meta["image"]))
		for key in ["depth_png", "light_png"]:
			if game.has(key):
				out.append(dir.path_join(game[key]))
	if game.has("sun_png"):
		out.append(dir.path_join(game["sun_png"]))
	if meta.has("minimap"):
		out.append(dir.path_join(meta["minimap"]["file"]))
	for s in meta.get("animated", {}).get("sprites", []):
		out.append(dir.path_join(s["file"]))
	var fx := ViewData.fx_of(path, meta)
	for s in fx.get("flora", {}).get("sheets", []):
		out.append(dir.path_join(s["file"]))
	if fx.has("halos"):
		out.append(dir.path_join(fx["halos"]["file"]))
	var crash: Dictionary = fx.get("crash", {})
	for key in ["before", "satellite"]:
		if crash.has(key):
			out.append(dir.path_join(crash[key]["file"]))
	for d in fx.get("doors", []):
		if d.has("file"):
			out.append(dir.path_join(d["file"]))
	if meta.has("door"):                       # the interior's one door is named in its meta
		out.append(dir.path_join(meta["door"]["file"]))
	_paths_of[path] = out
	return out


## Keep this view and its two neighbours loaded (in the background); let the far one go.
func _preload_around(k: int) -> void:
	var want := {}
	for d in [0, -1, 1]:
		for path in _paths(k + d):
			want[path] = true
			if _keep.has(path):
				continue
			if ResourceLoader.has_cached(path):
				_keep[path] = load(path)
			else:
				ResourceLoader.load_threaded_request(path)
				_keep[path] = null
	for path in _keep.keys():
		if want.has(path):
			continue
		if _keep[path] == null and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue                         # still coming: taking it now would block. Prune it next time.
		_collect(path)                       # a finished load must be taken before it is let go
		_keep.erase(path)


## Collect background loads as they finish (and any still going when the scene ends), so none
## is left hanging.
func _process(delta: float) -> void:
	for path in _keep:
		if _keep[path] == null and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
			_keep[path] = ResourceLoader.load_threaded_get(path)
	if _wish == 0:
		return
	_wish_left -= delta
	if not _start_wish() and _wish_left <= 0.0:
		_force_loaded(posmod(terrain.heading + _wish, 4))      # a hitch, but never a lost press
		_start_wish()


func _exit_tree() -> void:
	for path in _keep:
		_collect(path)
	_keep.clear()


## Take a background load's result, if one is outstanding for this path. A threaded request that
## is never collected is reported as a leak when the engine shuts down, so every path that leaves
## _keep goes through this first. It waits if the load is still running, which is why pruning
## skips those and the scene's end is the only place that lets it wait.
func _collect(path: String) -> void:
	if _keep.get(path) != null:
		return
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_get(path)


## Is every picture this view needs in memory? Never waits: a background load that has not
## finished means "not yet", and the press that wanted it is kept (see request()).
func _loaded(k: int) -> bool:
	if stream != null and not stream.ready_for(k):
		return false
	for path in _paths(k):
		if _keep.get(path) != null:
			continue
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			_keep[path] = ResourceLoader.load_threaded_get(path)
		elif status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_keep[path] = load(path)       # never asked for in the background; the cache has it
		else:
			return false
	return true


static func _ensure_actions() -> void:
	var setup := {"turn_left": [KEY_G, JOY_BUTTON_DPAD_LEFT], "turn_right": [KEY_H, JOY_BUTTON_DPAD_RIGHT]}
	for action in setup:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var key := InputEventKey.new()
		key.physical_keycode = setup[action][0]
		InputMap.action_add_event(action, key)
		var pad := InputEventJoypadButton.new()
		pad.button_index = setup[action][1]
		InputMap.action_add_event(action, pad)


# ---------------------------------------------------------------- what stands in the swing
## A plant from BiomeFX.visible_plants(), as a billboard in the world (this view's sprite).
static func plant_board(t: MapTerrain, p: Array) -> Dictionary:
	var foot: Vector2 = (p[2] as Vector2) + (p[3] as Vector2)
	var depth: float = p[4]
	var v := Vector2((foot.x - t.origin.x) * t.units_per_px, depth)
	var z := (t.origin.y - foot.y) / t.px_per_unit - t.depth_to_px * depth
	var w := t.world_point(v)
	return {"tex": p[0], "region": p[1], "anchor": p[3], "world": Vector3(w.x, w.y, z)}


## A loose prop (rock, scrap, crate) as a billboard.
static func prop_board(t: MapTerrain, prop: WorldProp) -> Dictionary:
	var tex := prop.sprite.texture
	var w := tex.get_width() / float(prop.sprite.hframes)
	return {"tex": tex, "region": Rect2(prop.sprite.frame * w, 0.0, w, tex.get_height()), "anchor": -prop.sprite.offset,
			"world": Vector3(prop.world.x, prop.world.y, t.height_at(prop.world) + prop.lift / t.px_per_unit)}
