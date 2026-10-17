class_name DayNight
extends Node
## Day and night. The game's clock (GameState.clock, in game hours) keeps running: a whole day
## passes in `day_minutes` real minutes, so the light changes as you play, indoors and out. Each
## frame this sets the shader globals that every world shader reads (shaders/day_night.gdshaderinc):
## a soft pink dawn, a clear noon, a golden evening, a deep blue night.
##
## What glows on its own stays lit at night: the map's light mask keeps its lamps, lit windows,
## glowing pools and crystals bright, the plants keep their glowing parts, and the effects
## scripts' lights are left alone (additive layers, and nodes tagged with the meta "dn_unlit").
## Nothing else is lit after dark: the lamp the astronaut carries is SuitLight's, and it is off
## until they switch it on.
##
## Every other world node with no material of its own (smoke, dust, gas, snow, the doors, the
## domes' moving parts...) gets the graded material, now and whenever one is added. UI on its own
## CanvasLayer is left alone. The time panel (DayClock) is made here too.
##
## Test hooks (after "--"): --time=HOUR (e.g. 21.5)  --day=N  --day-speed=X (time runs X times faster)

signal phase_changed(phase: String)
signal new_day(day: int)

const MAP_SHADER := preload("res://shaders/map_light.gdshader")
const GRADED_SHADER := preload("res://shaders/graded.gdshader")
## A new day begins at dawn.
const DAWN := 5.0
## The parts of the day: name, the hour it starts, its colour (the panel shows it).
const PHASES := [
	["MORNING", 5.0, Color("#ffd27a")],
	["NOON", 11.0, Color("#fff4d0")],
	["EVENING", 16.0, Color("#ec7a5a")],
	["NIGHT", 20.0, Color("#a8c8ff")],
]
## The light through the day: hour, the daylight's colour, sky light in the shadows, saturation,
## how dark it is (0..1). Between two keys it eases from one to the next. The night is deep: the
## sky light leaves a blue-violet floor rather than black, but little else, so the astronaut's
## suit lamp (SuitLight) is what you get about by once the sun is down.
const KEYS := [
	[0.0, Color(0.085, 0.095, 0.175), Color(0.008, 0.008, 0.022), 0.55, 1.0],
	[4.4, Color(0.090, 0.098, 0.182), Color(0.010, 0.008, 0.024), 0.57, 1.0],
	[5.8, Color(0.50, 0.37, 0.47), Color(0.026, 0.010, 0.030), 0.76, 0.55],
	[7.4, Color(1.00, 0.89, 0.86), Color(0.020, 0.008, 0.008), 0.95, 0.0],
	[10.0, Color(1.00, 1.00, 1.00), Color(0.0, 0.0, 0.0), 1.00, 0.0],
	[15.5, Color(1.00, 0.99, 0.96), Color(0.0, 0.0, 0.0), 1.00, 0.0],
	[18.0, Color(1.02, 0.86, 0.76), Color(0.026, 0.004, 0.016), 0.98, 0.1],
	[19.5, Color(0.42, 0.31, 0.44), Color(0.020, 0.007, 0.032), 0.76, 0.6],
	[21.0, Color(0.085, 0.095, 0.175), Color(0.008, 0.008, 0.022), 0.55, 1.0],
	[24.0, Color(0.085, 0.095, 0.175), Color(0.008, 0.008, 0.022), 0.55, 1.0],
]

## Real minutes per game day.
@export var day_minutes := 12.0

## For the effects scripts: the hour (0..24), how dark it is (0 by day, 1 at night), how much
## sun there is (1 - night), the part of the day and the day number.
static var hour := 8.0
static var night := 0.0
static var daylight := 1.0
static var phase := "MORNING"
static var day := 1
## The daylight's colour right now (for things drawn outside the shaders, like the camera's turn).
static var light_mul := Color.WHITE

var clock_panel: DayClock
## How many times faster than normal the clock runs (a test hook sets it).
var speed := 1.0

var _graded: ShaderMaterial
var _map_mat: ShaderMaterial
var _pending: Array[Node] = []


## map: the scene's pre-rendered map sprite. light_mask / sun_mask: its light and sun masks.
func setup(map: CanvasItem, light_mask: Texture2D, sun_mask: Texture2D = null) -> void:
	_map_mat = ShaderMaterial.new()
	_map_mat.shader = MAP_SHADER
	map.material = _map_mat
	set_masks(light_mask, sun_mask)
	_graded = ShaderMaterial.new()
	_graded.shader = GRADED_SHADER
	_run_test_hooks()
	_update(0.0, true)
	clock_panel = DayClock.new()
	add_child(clock_panel)
	phase_changed.connect(clock_panel.on_phase_changed)
	new_day.connect(clock_panel.on_new_day)
	get_tree().node_added.connect(_on_node_added)
	_grade_tree.call_deferred(get_parent())                # once the scene has made all its nodes


## The camera turned: the new view's light (and sun) masks.
func set_masks(light_mask: Texture2D, sun_mask: Texture2D = null) -> void:
	_map_mat.set_shader_parameter("light_mask", light_mask)
	_map_mat.set_shader_parameter("sun_mask", sun_mask)


## Where the current part of the day is: 0 as it begins, 1 as it ends.
static func phase_progress() -> float:
	var i := phase_index()
	var start: float = PHASES[i][1]
	var end: float = PHASES[(i + 1) % PHASES.size()][1]
	var h := hour
	if end <= start:
		end += 24.0
		if h < start:
			h += 24.0
	return clampf((h - start) / (end - start), 0.0, 1.0)


static func phase_index() -> int:
	for i in PHASES.size():
		if PHASES[i][0] == phase:
			return i
	return 0


static func phase_color() -> Color:
	return PHASES[phase_index()][2]


func _process(delta: float) -> void:
	_update(delta, false)
	for n in _pending:
		if is_instance_valid(n) and n.is_inside_tree() and not _in_ui(n):
			_grade(n as CanvasItem)
	_pending.clear()


func _update(delta: float, quiet: bool) -> void:
	GameState.clock += delta * speed * 24.0 / (day_minutes * 60.0)
	hour = fposmod(GameState.clock, 24.0)
	var d := int(floor((GameState.clock - DAWN) / 24.0)) + 1
	var ph := _phase_at(hour)
	var light := _light_at(hour)
	night = light[3]
	daylight = 1.0 - night
	var mul: Color = light[0]
	var add: Color = light[1]
	light_mul = Color(mul.r + add.r, mul.g + add.g, mul.b + add.b)
	RenderingServer.global_shader_parameter_set("dn_mul", Vector3(mul.r, mul.g, mul.b))
	RenderingServer.global_shader_parameter_set("dn_add", Vector3(add.r, add.g, add.b))
	RenderingServer.global_shader_parameter_set("dn_sat", light[2])
	RenderingServer.global_shader_parameter_set("dn_night", night)
	if quiet:
		day = d
		phase = ph
		return
	if d != day:
		day = d
		new_day.emit(day)
	if ph != phase:
		phase = ph
		phase_changed.emit(phase)


static func _phase_at(h: float) -> String:
	var name: String = PHASES[-1][0]
	for p in PHASES:
		if h >= p[1]:
			name = p[0]
	return name


## The light at an hour: [daylight colour, sky light, saturation, darkness].
static func _light_at(h: float) -> Array:
	for i in KEYS.size() - 1:
		var a: Array = KEYS[i]
		var b: Array = KEYS[i + 1]
		if h <= b[0]:
			var t := smoothstep(a[0], b[0], h)
			return [(a[1] as Color).lerp(b[1], t), (a[2] as Color).lerp(b[2], t), lerpf(a[3], b[3], t), lerpf(a[4], b[4], t)]
	var last: Array = KEYS[-1]
	return [last[1], last[2], last[3], last[4]]


# ---------------------------------------------------------------- the graded material
func _on_node_added(n: Node) -> void:
	if n is CanvasItem:
		_pending.append(n)


func _grade_tree(n: Node) -> void:
	if n is CanvasLayer and not (n as CanvasLayer).follow_viewport_enabled:
		return
	if n is CanvasItem:
		_grade(n as CanvasItem)
	for c in n.get_children():
		_grade_tree(c)


## Sunlit things take the time of day; lights, UI and anything with its own material don't.
func _grade(ci: CanvasItem) -> void:
	if ci.material != null or ci.use_parent_material or ci.has_meta("dn_unlit"):
		return
	ci.material = _graded


func _in_ui(n: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != get_parent():
		if p is CanvasLayer and not (p as CanvasLayer).follow_viewport_enabled:
			return true
		p = p.get_parent()
	return false


# ---------------------------------------------------------------- test hooks
func _run_test_hooks() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if args.has("day-speed"):
		speed = float(args["day-speed"])
	if args.has("time") or args.has("day"):
		var d := int(args.get("day", str(int(floor((GameState.clock - DAWN) / 24.0)) + 1)))
		var h := float(args.get("time", str(fposmod(GameState.clock, 24.0))))
		GameState.clock = (d - 1) * 24.0 + (h + 24.0 if h < DAWN else h)
