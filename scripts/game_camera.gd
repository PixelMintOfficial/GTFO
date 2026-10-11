class_name GameCamera
extends Camera2D
## Follows the player with smoothing that stays snapped to whole map pixels, and steps
## through zoom levels: I zooms in, O zooms out. The default view is the closest. The
## furthest shows a base-sized area (from the map data), still centered on the astronaut.
## At 1080p the in-between levels land on whole-pixel scales, so they stay pixel-perfect.

@export var follow_speed := 6.0
@export var zoom_time := 0.3
## How quickly the camera pans to a cutscene focus and back to the player.
@export var pan_speed := 2.2

## Cutscenes: look here instead of at the player (map px). Use release_focus() to come back.
var focus_override: Variant = null

## Indoors there is nothing to see further out: the view stays at the default zoom.
var zoom_locked := false
## How much more of the world each level shows than the default view.
var levels: Array[float] = [1.0]
var level := 0

var _target: Node2D
var _map: CanvasItem
var _max_view := Vector2.ZERO
var _pos := Vector2.ZERO
var _factor := 1.0
var _tween: Tween
var _returning := false
var _shake := 0.0
var _shake_left := 0.0
var _shake_len := 1.0


func setup(target: Node2D, map: CanvasItem, max_view_px: Vector2) -> void:
	_target = target
	_map = map
	_max_view = max_view_px
	top_level = true
	position_smoothing_enabled = false
	_ensure_actions()
	_build_levels()
	get_window().size_changed.connect(_build_levels)
	snap()


## The camera turned round the world: keep the zoom level and follow the reprojected target.
func set_view_limits(max_view_px: Vector2) -> void:
	_max_view = max_view_px
	_build_levels()
	if _target != null:
		_pos = _goal()
		global_position = _pos.round()


## Jump straight to the target (after a teleport).
func snap() -> void:
	if _target != null:
		_pos = _focus()
		global_position = _pos.round()


## Jump straight to a map point (cutscenes).
func snap_to(p: Vector2) -> void:
	_pos = p - offset
	global_position = _pos.round()


## Stop looking at the cutscene focus and pan back to the player.
func release_focus() -> void:
	focus_override = null
	_returning = true


## Rattle the view by up to strength px, dying away over duration seconds.
func shake(strength: float, duration: float) -> void:
	_shake = strength
	_shake_left = duration
	_shake_len = maxf(duration, 0.01)


## World pixels currently visible.
func view_size() -> Vector2:
	return _base_view() / zoom


func set_level(i: int) -> void:
	i = clampi(i, 0, levels.size() - 1)
	if i == level:
		return
	level = i
	Audio.play("ui_zoom")
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(_apply_factor, _factor, levels[level], zoom_time)


func _process(delta: float) -> void:
	if _target == null:
		return
	var goal := _goal()
	var speed := pan_speed if focus_override != null or _returning else follow_speed
	_pos = _pos.lerp(goal, 1.0 - exp(-speed * delta))
	if _returning and _pos.distance_to(goal) < 3.0:
		_returning = false
	var jolt := Vector2.ZERO
	if _shake_left > 0.0:
		_shake_left -= delta
		var a := _shake * clampf(_shake_left / _shake_len, 0.0, 1.0)
		jolt = Vector2(randf_range(-a, a), randf_range(-a, a))
	global_position = (_pos + jolt).round()


func _focus() -> Vector2:
	return _target.camera_focus() if _target.has_method("camera_focus") else _target.global_position


## Normal play follows the astronaut at every zoom level; only cutscenes override the focus.
func _goal() -> Vector2:
	if focus_override != null:
		return focus_override - offset
	return _focus()


func _unhandled_input(event: InputEvent) -> void:
	if zoom_locked:
		return
	if event.is_action_pressed("zoom_in"):
		set_level(level - 1)
	elif event.is_action_pressed("zoom_out"):
		set_level(level + 1)


func _apply_factor(f: float) -> void:
	_factor = f
	zoom = Vector2.ONE / f
	# Once a map pixel gets smaller than a screen pixel, let mipmaps shrink it smoothly.
	var screen_px_per_map_px := _base_scale() / f
	_map.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS if screen_px_per_map_px < 0.999 \
			else CanvasItem.TEXTURE_FILTER_NEAREST


func _build_levels() -> void:
	var base := _base_view()
	var max_f := maxf(1.0, maxf(_max_view.x / base.x, _max_view.y / base.y))
	var s0 := _base_scale()
	levels = [1.0]
	if zoom_locked:
		level = 0
		_apply_factor(1.0)
		return
	for k in [1, 2]:
		var ideal := pow(max_f, k / 3.0)
		var f := ideal
		if s0 >= 3.0:  # prefer a level where map pixels land on whole screen pixels
			f = s0 / clampi(int(round(s0 / ideal)), 1, int(s0) - 1)
		if f <= levels[-1] + 0.05 or f >= max_f - 0.05:
			f = ideal
		levels.append(f)
	levels.append(max_f)
	level = mini(level, levels.size() - 1)
	_apply_factor(levels[level])


func _base_view() -> Vector2:
	return Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"),
			ProjectSettings.get_setting("display/window/size/viewport_height"))


## Screen pixels per map pixel at the default zoom (the integer window scale).
func _base_scale() -> float:
	var win := Vector2(get_window().size)
	var base := _base_view()
	return maxf(1.0, floorf(minf(win.x / base.x, win.y / base.y)))


static func _ensure_actions() -> void:
	var setup := {"zoom_in": [KEY_I, JOY_BUTTON_DPAD_UP], "zoom_out": [KEY_O, JOY_BUTTON_DPAD_DOWN]}
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
