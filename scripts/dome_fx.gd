class_name DomeFX
extends Node2D
## Moving parts on the bases. Sprite animations come from the map generator (the base
## radar, the nursery wind gauge, the comms dish orbiting its tower); the lights are
## animated here: pulses chasing around each dome rim, blinking airlock warning lights
## and the double strobe of the comms beacon.
##
## Sit this node between the map and the player: its lights draw under the player, its
## sprites (on top of the domes) draw over anyone walking behind a dome.

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
var _rim: Array = []       # [Vector2, phase around the rim]
var _doors: Array = []     # [Vector2, phase]
var _beacon := Vector2.ZERO
var _t := 0.0


func setup(meta_path: String) -> void:
	set_meta("dn_unlit", true)                           # these are lights: the sprites below take the time of day
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
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
	for l in anim.get("ring_lights", []):
		_rim.append([Vector2(l[0], l[1]), float(l[2])])
	for l in anim.get("door_lights", []):
		_doors.append([Vector2(l[0], l[1]), float(l[2])])
	var b = anim.get("beacon")
	if b != null:
		_beacon = Vector2(b[0], b[1])


func _process(delta: float) -> void:
	_t += delta
	for s in _sprites:
		(s[0] as Sprite2D).frame = int(_t * s[2]) % int(s[1])
	queue_redraw()


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
