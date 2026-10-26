class_name SuitLight
extends Node
## The lamp on the astronaut's suit. It starts off and stays off until you switch it on (L, or
## B on the pad), and it stays as you left it through the airlock (GameState.suit_light). The
## base is dead and nothing is lit out on the plains, so after dark this is the only light you
## carry: the beam is what you find your way by.
##
## It is not a light node. Every world shader already takes the time of day from one place
## (shaders/day_night.gdshaderinc), so the lamp is two more shader globals that the same
## shaders lay on the ground as they colour it:
##   dn_lamp  where it is (map px), how far it throws (map px), how strong it is
##   dn_beam  the way it points, the cosine of its half width, the spill round the feet
## Nothing dynamic is added to the scene, so it costs nothing per lit thing.
##
## The beam is thrown along the ground the way the astronaut faces, so its direction is worked
## out in the current view's map pixels (MapTerrain.to_screen_direction): turn the camera
## (G / H) and the beam turns with the world. It is only worth anything in the dark, so its
## strength follows DayNight.night and it does nothing at noon.
## Its origin follows the sprite's pixel-snapped feet offset, so jumps, falls and platforms
## carry the lamp with the suit rather than leaving its source at the ground sort position.
##
## Test hooks (after "--"): --suit-light (start with the lamp on)

## How far the camera flattens the ground. Must match DN_GROUND in day_night.gdshaderinc.
const GROUND := 0.55
## The lamp sits on the suit's chest, this far above the feet in map pixels.
const CHEST := 6.0

## How far the beam throws across the ground, in map pixels (its long half-axis; the camera
## flattens the other one, DN_GROUND in the shader include).
@export var reach := 120.0
## How bright the brightest part of the beam is: 1 would be full daylight on that pixel.
@export var strength := 0.85
## How much of that falls on the astronaut wearing it (they are beside the lamp, not in its beam).
@export var on_suit := 0.8
## Half the beam's width, in degrees.
@export var spread := 38.0
## The pool spilling round the astronaut's feet, as a share of the throw.
@export var spill := 0.3

## What the shaders were last given: where the lamp is and what it throws, and how much of it
## falls on the astronaut (the camera's swing lights their billboard by it, and the tests read
## it - a global shader parameter cannot be read back from a headless run).
static var published := Vector4(0.0, 0.0, 1.0, 0.0)
static var published_suit := 0.0

var player: Player

var _tool: Multitool


## tool: the multitool, for the one modal that does not pause the game (the window panel).
func setup(p: Player, tool: Multitool = null) -> void:
	player = p
	_tool = tool
	_ensure_actions()
	_apply()


func on() -> bool:
	return GameState.suit_light


## Switch the lamp on or off (the switch is on the suit, so it is heard where you stand).
func toggle() -> void:
	GameState.suit_light = not GameState.suit_light
	if player != null:
		Audio.play("suit_light_on" if GameState.suit_light else "suit_light_off", player.global_position)
	_apply()


## Which way the beam points, in the flattened ground the shader measures its ellipse in: the
## way the astronaut faces, as this view lays it out and with the camera's squash taken out.
static func beam_dir(terrain: MapTerrain, p: Player) -> Vector2:
	if terrain == null or p == null:
		return Vector2.RIGHT
	var w := p.facing_dir()
	var d := terrain.to_screen_direction(Vector3(w.x, w.y, 0.0))
	d.y /= GROUND
	return d.normalized() if d.length() > 0.001 else Vector2.RIGHT


## The same drawn suit position for live world shaders and camera-turn reliefs.
static func beam_origin(p: Player) -> Vector2:
	return p.sprite.global_position + Vector2(0.0, -CHEST)


## Where the lamp is and what it throws, as the shader global holds it.
func lamp_vector() -> Vector4:
	if player == null:
		return Vector4(0.0, 0.0, reach, 0.0)
	var at := beam_origin(player)
	var lit := strength * DayNight.night if GameState.suit_light else 0.0
	return Vector4(at.x, at.y, reach, lit)


## How much of the lamp falls on the astronaut themselves.
func suit_lit() -> float:
	return lamp_vector().w * on_suit


## Where it points and how wide, as the shader global holds it.
func beam_vector() -> Vector4:
	var d := beam_dir(player.terrain if player != null else null, player)
	return Vector4(d.x, d.y, cos(deg_to_rad(spread)), spill)


func _process(_delta: float) -> void:
	_apply()


func _input(event: InputEvent) -> void:
	if event.is_echo() or not event.is_action_pressed("suit_light"):
		return
	if get_tree().paused or player == null or not player.controls_enabled or player.puppet or player.turning:
		return
	if _tool != null and _tool.window_panel_open:        # the one modal that does not pause
		return
	toggle()
	get_viewport().set_input_as_handled()


## Leaving the scene: the lamp goes with the astronaut, so nothing is left lighting the next one.
func _exit_tree() -> void:
	_publish(Vector4(0.0, 0.0, reach, 0.0), 0.0)


func _apply() -> void:
	_publish(lamp_vector(), suit_lit())
	RenderingServer.global_shader_parameter_set("dn_beam", beam_vector())


func _publish(lamp: Vector4, suit: float) -> void:
	published = lamp
	published_suit = suit
	RenderingServer.global_shader_parameter_set("dn_lamp", lamp)
	if is_instance_valid(player):              # the scene may be coming down around us
		player.set_suit_lamp(suit)


static func _ensure_actions() -> void:
	if InputMap.has_action("suit_light"):
		return
	InputMap.add_action("suit_light")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_L
	InputMap.action_add_event("suit_light", key)
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_B
	InputMap.action_add_event("suit_light", pad)
