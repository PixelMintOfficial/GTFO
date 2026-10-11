class_name DomeFX
extends Node2D
## Moving parts on the bases. Sprite animations come from the map generator (the base
## radar, the nursery wind gauge, the comms dish orbiting its tower); the lights are
## animated here: pulses chasing around each dome rim, blinking airlock warning lights
## and the double strobe of the comms beacon.
##
## Sit this node between the map and the player: its lights draw under the player, its
## sprites (on top of the domes) draw over anyone walking behind a dome.
##
## Mended glass: once a base room's windows are mended from inside
## (GameState.window_repair.dome_mended), each of its holes gets the glass back - the patch the
## map generator exported with it (red_planet_fx.json -> cracks), laid over the map like the map
## itself, so the hole, its bright rim and its cracks are gone in every view.

const GLASS := preload("res://shaders/dome_glass.gdshader")

const RIM_BRIGHT := Color("#e2fff6")
const RIM_GLOW := Color(0.5, 0.95, 0.85, 0.3)
const DOOR_ON := Color("#ffb347")
const DOOR_GLOW := Color(1.0, 0.7, 0.3, 0.28)

## Pulses travelling around each rim at once, and how fast they go (laps per second).
@export var rim_pulses := 4
@export var rim_speed := 0.09
@export var door_blink_period := 1.2
@export var beacon_period := 2.0

var _sprites: Array = []   # [Sprite2D, frame count, fps]
var _glass: Array[Sprite2D] = []   # mended holes: the glass as it was
var _rim: Array = []       # [Vector2, phase around the rim]
var _doors: Array = []     # [Vector2, phase]
var _beacon := Vector2.ZERO
var _beacon_lit := false
var _door_lit := []
var _t := 0.0


func setup(meta_path: String) -> void:
	set_meta("dn_unlit", true)                           # these are lights: the sprites below take the time of day
	load_view(meta_path)


## The camera turned: this view's sprites on the domes, and where its lights are.
func load_view(meta_path: String) -> void:
	for s in _sprites:
		(s[0] as Node).queue_free()
	_sprites.clear()
	_rim.clear()
	_doors.clear()
	_beacon = Vector2.ZERO
	var meta := ViewData.get_json(meta_path)
	var anim: Dictionary = meta.get("animated", {})
	var dir := meta_path.get_base_dir()
	for s in anim.get("sprites", []):
		var spr := Sprite2D.new()
		spr.texture = load(dir.path_join(s["file"]))
		spr.hframes = int(s["frames"])
		spr.centered = false
		spr.position = Vector2(s["position"][0], s["position"][1])
		spr.z_index = 10
		add_child(spr)
		_sprites.append([spr, int(s["frames"]), float(s["fps"])])
		if s.has("world"):                                # for the camera's turn: where it is in the world
			spr.set_meta("world", Vector3(s["world"][0], s["world"][1], s["world"][2]))
			spr.set_meta("anchor", Vector2(s["anchor"][0], s["anchor"][1]))
	for l in anim.get("ring_lights", []):
		_rim.append([Vector2(l[0], l[1]), float(l[2])])
	for l in anim.get("door_lights", []):
		_doors.append([Vector2(l[0], l[1]), float(l[2])])
	var b = anim.get("beacon")
	if b != null:
		_beacon = Vector2(b[0], b[1])
	_door_lit.resize(_doors.size())
	_door_lit.fill(false)
	_load_glass(meta_path, meta, dir)


## This view's mended holes: a patch of whole glass over each hole in the mended room.
func _load_glass(meta_path: String, meta: Dictionary, dir: String) -> void:
	for spr in _glass:
		spr.queue_free()
	_glass.clear()
	var room := GameState.window_repair.dome_mended
	if room == "" or not meta.has("fx"):
		return
	var fx := ViewData.fx_of(meta_path, meta)
	var mat := ShaderMaterial.new()
	mat.shader = GLASS
	for c in fx.get("cracks", []):
		if c["room"] != room:
			continue
		var spr := Sprite2D.new()
		spr.texture = load(dir.path_join(c["patch"]))
		spr.centered = false
		spr.position = Vector2(c["patch_pos"][0], c["patch_pos"][1])
		spr.material = mat
		spr.set_meta("world", Vector3(c["world"][0], c["world"][1], c["world"][2]))
		spr.set_meta("anchor", Vector2(c["center"][0], c["center"][1]) - spr.position)
		add_child(spr)
		_glass.append(spr)


## The moving parts on the domes, for the camera's turn: billboards (see TurnOverlay._board).
func boards() -> Array:
	var out := []
	for s in _sprites:
		var spr := s[0] as Sprite2D
		if not spr.has_meta("world"):
			continue
		var w := spr.texture.get_width() / float(spr.hframes)
		out.append({"tex": spr.texture, "region": Rect2(spr.frame * w, 0.0, w, spr.texture.get_height()),
				"anchor": spr.get_meta("anchor"), "world": spr.get_meta("world")})
	for spr in _glass:
		out.append({"tex": spr.texture, "region": Rect2(Vector2.ZERO, spr.texture.get_size()),
				"anchor": spr.get_meta("anchor"), "world": spr.get_meta("world")})
	return out


func _process(delta: float) -> void:
	_t += delta
	for s in _sprites:
		(s[0] as Sprite2D).frame = int(_t * s[2]) % int(s[1])
	_tick_lights()
	queue_redraw()


## The blinking lights are audible if you are standing under them: tick in step with the
## strobe _draw() draws, so the sound and the light are the same event.
func _tick_lights() -> void:
	if _beacon != Vector2.ZERO:
		var c := fmod(_t, beacon_period)
		var on := c < 0.12 or (c > 0.3 and c < 0.42)
		if on and not _beacon_lit:
			Audio.play("beacon", _beacon)
		_beacon_lit = on
	for i in _doors.size():
		var l: Array = _doors[i]
		var on := fmod(_t + float(l[1]) * door_blink_period, door_blink_period) < door_blink_period * 0.4
		if on and not _door_lit[i]:
			Audio.play("door_lamp", l[0] as Vector2)
		_door_lit[i] = on


func _draw() -> void:
	for l in _rim:
		var b := pow(maxf(0.0, cos(TAU * (float(l[1]) * rim_pulses - _t * rim_speed * rim_pulses))), 8.0)
		if b > 0.2:
			var p: Vector2 = l[0]
			draw_circle(p + Vector2(0.5, 0.5), 3.5, Color(RIM_GLOW, RIM_GLOW.a * b))
			draw_rect(Rect2(p - Vector2(1, 1), Vector2(2, 2)), Color(RIM_BRIGHT, b))
	for l in _doors:
		if fmod(_t + float(l[1]) * door_blink_period, door_blink_period) < door_blink_period * 0.4:
			var p: Vector2 = l[0]
			draw_circle(p + Vector2(0.5, 0.5), 6.0, DOOR_GLOW)
			draw_rect(Rect2(p - Vector2(1, 1), Vector2(3, 3)), DOOR_ON)
	if _beacon != Vector2.ZERO:
		var c := fmod(_t, beacon_period)
		var flash := c < 0.12 or (c > 0.3 and c < 0.42)
		if flash:
			draw_circle(_beacon, 30.0, Color(1.0, 0.42, 0.32, 0.10))
			draw_circle(_beacon, 16.0, Color(1.0, 0.45, 0.35, 0.22))
			draw_circle(_beacon, 7.0, Color(1.0, 0.72, 0.6, 0.65))
			draw_circle(_beacon, 3.5, Color(1.0, 0.96, 0.9, 1.0))
		else:
			draw_circle(_beacon, 9.0, Color(1.0, 0.42, 0.32, 0.12))
