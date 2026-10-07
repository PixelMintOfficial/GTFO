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
var player: Player
var camera: GameCamera
## (heading: int, world_facing: Vector2) -> void: switch the scene to that view.
var apply: Callable
## () -> Array of things standing in the world to show in the swing (see TurnOverlay._board).
var boards: Callable
var busy := false

var _pending := 0
var _keep := {}                  # resource path -> resource: views kept loaded
var _overlay: TurnOverlay


func setup(t: MapTerrain, p: Player, apply_view: Callable, board_source := Callable()) -> void:
	terrain = t
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
		args[a.trim_prefix("--").split("=", true, 1)[0]] = true
	if args.has("turn-left") or args.has("turn-right"):
		get_tree().create_timer(1.0).timeout.connect(request.bind(-1 if args.has("turn-left") else 1))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("turn_left"):
		request(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("turn_right"):
		request(1)
		get_viewport().set_input_as_handled()


## Turn a quarter turn: -1 to the left, +1 to the right.
func request(step: int) -> void:
	if terrain == null or terrain.views.size() < 4:
		return
	if busy:
		_pending = step
		return
	if can_turn():
		_turn(step)


func can_turn() -> bool:
	return (player.controls_enabled and not player.puppet and not player.turning and not player.is_airborne()
			and player.work_target == null and not get_tree().paused
			and (player.tool_state == Player.Tool.HOLSTERED or player.tool_state == Player.Tool.READY))


func _turn(step: int) -> void:
	busy = true
	player.turning = true
	var to_k := posmod(terrain.heading + step, 4)
	var from := TurnOverlay.view_info(terrain, camera, player)
	var pivot := Vector3(player.world_pos.x, player.world_pos.y, terrain.height_at(player.world_pos))
	var things: Array = boards.call() if boards.is_valid() else []
	_ensure_loaded(to_k)
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
	if _pending != 0:
		var again := _pending
		_pending = 0
		request(again)


# ---------------------------------------------------------------- loading the views ahead
## The pictures a view needs (map, depth, light, sun).
func _paths(k: int) -> Array[String]:
	var out: Array[String] = []
	var path := terrain.views[posmod(k, terrain.views.size())]
	var meta = JSON.parse_string(FileAccess.get_file_as_string(path))
	if meta == null:
		return out
	var dir := path.get_base_dir()
	out.append(dir.path_join(meta["image"]))
	var game: Dictionary = meta["game"]
	for key in ["depth_png", "light_png", "sun_png"]:
		if game.has(key):
			out.append(dir.path_join(game[key]))
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
		if not want.has(path):
			_keep.erase(path)


## Collect background loads as they finish (and any still going when the scene ends), so none
## is left hanging.
func _process(_delta: float) -> void:
	for path in _keep:
		if _keep[path] == null and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
			_keep[path] = ResourceLoader.load_threaded_get(path)


func _exit_tree() -> void:
	for path in _keep:
		if _keep[path] == null and ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			ResourceLoader.load_threaded_get(path)
	_keep.clear()


## Make sure a view's pictures are in memory (waits only if the background load hasn't finished).
func _ensure_loaded(k: int) -> void:
	for path in _paths(k):
		if _keep.get(path) != null:
			continue
		if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_keep[path] = ResourceLoader.load_threaded_get(path)
		else:
			_keep[path] = load(path)


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
