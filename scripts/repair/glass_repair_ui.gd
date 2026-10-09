class_name GlassRepairUI
extends CanvasLayer
## Native version of the approved compact window inspection. Uses generated window material,
## connected fragment textures and the actual working gauntlet. Pointer drag/click or
## keyboard/gamepad placement and quarter turns; world physics belongs to WindowCracks.

signal closed

const DIR := "res://assets/maps/base_interior/windows/inspection/"
const PANE := Rect2(43, 39, 298, 96)
const DARK := Color("#22182c")
const RIM := Color("#423d5e")
const WHITE := Color("#fbfbff")
const MUTED := Color("#a9a7bd")
const TEAL := Color("#4fc6b4")
const CORAL := Color("#ec7a5a")

var opened := false
var puzzle: GlassPuzzle
var active := -1
var point := Vector2.ZERO
var reduced_motion := OS.get_cmdline_user_args().has("--reduced-motion")
var _canvas: Control
var _pane: Texture2D
var _damage: Texture2D
var _tool: Texture2D
var _pieces: Array[Texture2D] = []
var _images: Array[Image] = []
var _drag := false
var _offset := Vector2.ZERO
var _mouse_mode := Input.MOUSE_MODE_VISIBLE
var _notice := ""
var _notice_time := 0.0


func _ready() -> void:
	layer = 15
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.size = Vector2(384, 216)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_canvas.draw.connect(_draw_panel)
	add_child(_canvas)
	_ensure_actions()
	_tool = load(DIR + "multitool_fix.png")
	visible = false


func open(state: GlassPuzzle) -> void:
	puzzle = state
	_pane = load(DIR + state.definition["pane"])
	_damage = load(DIR + state.definition["damage"])
	_pieces.clear()
	_images.clear()
	for piece in state.definition["pieces"]:
		var texture: Texture2D = load(DIR + piece["file"])
		_pieces.append(texture)
		_images.append(texture.get_image())
	active = -1
	_drag = false
	_notice_time = 0.0
	_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	opened = true
	visible = true
	_fit_canvas()
	_canvas.queue_redraw()
	Audio.play("ui_panel_open")


func close() -> void:
	if not opened:
		return
	opened = false
	visible = false
	_drag = false
	active = -1
	Input.mouse_mode = _mouse_mode
	Audio.play("ui_panel_close")
	closed.emit()


func _exit_tree() -> void:
	if opened:
		Input.mouse_mode = _mouse_mode


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_drag = false


func _fit_canvas() -> void:
	var view := _canvas.get_viewport_rect().size
	var factor := minf(view.x / 384.0, view.y / 216.0)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = ((view - Vector2(384, 216) * factor) * .5).floor()


func _process(delta: float) -> void:
	if not opened:
		return
	_fit_canvas()
	_notice_time = maxf(0, _notice_time - delta)
	if active >= 0 and not _drag and not puzzle.scanning() and not puzzle.done:
		point += Input.get_vector("glass_left", "glass_right", "glass_up", "glass_down") * delta * (18.0 if Input.is_action_pressed("run") else 70.0)
		point = point.clamp(Vector2(30, 36), Vector2(353, 192))
	_canvas.queue_redraw()


func _slot(index: int) -> Rect2:
	return Rect2(36 + index * 52, 141, 50, 49)


func choose(index: int) -> void:
	if puzzle.done or puzzle.scanning() or index < 0 or puzzle.placed[index]:
		return
	if active != index:
		point = _slot(index).get_center().floor()
	active = index
	Audio.play("ui_pick")


func cycle(direction := 1) -> void:
	for step in puzzle.placed.size():
		var next := posmod(active + direction * (step + 1), puzzle.placed.size())
		if not puzzle.placed[next]:
			choose(next)
			return


func rotate() -> void:
	if active < 0:
		cycle()
	if active >= 0 and not puzzle.scanning():
		puzzle.rotate(active)
		Audio.play("ui_slot")


func place() -> bool:
	if active < 0 or puzzle.scanning() or puzzle.done:
		return false
	if puzzle.place(active, point - PANE.position):
		active = -1
		_drag = false
		Audio.play("ui_place")
		_notice = "GLASS FITTED"
		_notice_time = .8
		return true
	Audio.play("ui_deny")
	_notice = "TURN TO MATCH" if puzzle.rotations[active] != 0 else "MATCH THE BROKEN EDGE"
	_notice_time = 1.0
	return false


func _hit(index: int, p: Vector2) -> bool:
	var origin := point if index == active else _slot(index).get_center().floor()
	var delta := (p - origin).rotated(-puzzle.rotations[index] * PI / 2).round() + _anchor(index)
	var image := _images[index]
	return delta.x >= 0 and delta.y >= 0 and delta.x < image.get_width() and delta.y < image.get_height() and image.get_pixelv(delta).a > .5


func _input(event: InputEvent) -> void:
	if not opened:
		return
	if event.is_action_pressed("glass_close"):
		close()
	elif event is InputEventMouseMotion:
		if _drag and active >= 0:
			point = (_canvas.get_global_transform().affine_inverse() * event.position - _offset).round()
	elif event is InputEventMouseButton:
		var p: Vector2 = (_canvas.get_global_transform().affine_inverse() * event.position).round()
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			rotate()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if Rect2(335, 15, 20, 17).has_point(p):
					close()
				elif not puzzle.done and not puzzle.scanning():
					var hit := -1
					for index in puzzle.placed.size():
						if not puzzle.placed[index] and (_hit(index, p) or _slot(index).has_point(p)):
							hit = index
					if hit >= 0:
						choose(hit)
						_drag = true
						_offset = p - point
					elif active >= 0:
						point = p
						place()
			elif _drag:
				_drag = false
				place()
	elif not event.is_echo():
		if event.is_action_pressed("glass_rotate"):
			rotate()
		elif event.is_action_pressed("glass_next"):
			cycle()
		elif event.is_action_pressed("glass_previous"):
			cycle(-1)
		elif event.is_action_pressed("glass_place"):
			if puzzle.done:
				close()
			elif active < 0:
				cycle()
			else:
				place()
		elif active < 0 and (event.is_action_pressed("glass_left") or event.is_action_pressed("glass_right") or event.is_action_pressed("glass_up") or event.is_action_pressed("glass_down")):
			cycle()
	get_viewport().set_input_as_handled()


func _anchor(index: int) -> Vector2:
	var a: Array = puzzle.definition["pieces"][index]["anchor"]
	return Vector2(a[0], a[1])


func _draw_piece(index: int, p: Vector2, angle := 0) -> void:
	_canvas.draw_set_transform(p.round(), angle * PI / 2)
	_canvas.draw_texture(_pieces[index], -_anchor(index))
	_canvas.draw_set_transform(Vector2.ZERO)


func _draw_below(texture: Texture2D, position: Vector2, cutoff: float) -> void:
	var size := texture.get_size()
	var top := clampf(cutoff - position.y, 0, size.y)
	if top < size.y:
		_canvas.draw_texture_rect_region(texture, Rect2(position + Vector2(0, top), Vector2(size.x, size.y - top)),
				Rect2(Vector2(0, top), Vector2(size.x, size.y - top)))


func _draw_panel() -> void:
	if not opened:
		return
	_canvas.draw_rect(Rect2(0, 0, 384, 216), Color("#0b0915b3"))
	_canvas.draw_rect(Rect2(26, 14, 336, 194), Color("#0b0915"))
	_canvas.draw_rect(Rect2(24, 11, 336, 194), DARK)
	_canvas.draw_rect(Rect2(25, 12, 334, 192), RIM)
	_canvas.draw_rect(Rect2(27, 14, 330, 188), Color("#141220"))
	_canvas.draw_line(Vector2(28, 14), Vector2(355, 14), Color("#8c8aa5"))
	_canvas.draw_rect(Rect2(30, 37, 324, 1), CORAL)
	for bolt in [Vector2(30, 17), Vector2(352, 17), Vector2(30, 197), Vector2(352, 197)]:
		_canvas.draw_rect(Rect2(bolt, Vector2(2, 2)), MUTED)
	PixelFont.draw(_canvas, Vector2(38, 22), "WINDOW REPAIR", WHITE, 2)
	PixelFont.draw(_canvas, Vector2(342, 22), "X", MUTED)
	_canvas.draw_rect(PANE.grow(1), Color("#8c8aa5"))
	_canvas.draw_texture(_pane, PANE.position)
	var cutoff := PANE.position.y + floorf(puzzle.scan * PANE.size.y) if puzzle.scanning() else PANE.position.y
	if not puzzle.done:
		_draw_below(_damage, PANE.position, cutoff)
		for index in puzzle.placed.size():
			if puzzle.placed[index]:
				_draw_below(_pieces[index], PANE.position + puzzle.target(index) - _anchor(index), cutoff)
	if puzzle.scanning():
		_draw_scan(cutoff)
	for index in puzzle.placed.size():
		var slot := _slot(index)
		_canvas.draw_rect(slot, DARK)
		_canvas.draw_line(slot.position + Vector2(2, 1), slot.position + Vector2(47, 1), RIM)
		_canvas.draw_rect(Rect2(slot.position + Vector2(3, 45), Vector2(44, 1)), RIM)
		if puzzle.placed[index]:
			PixelFont.draw(_canvas, slot.position + Vector2(4, 41), "SET", TEAL)
			_canvas.draw_rect(Rect2(slot.position + Vector2(43, 5), Vector2(2, 2)), TEAL)
		elif index != active:
			_draw_piece(index, slot.get_center().floor(), puzzle.rotations[index])
	if active >= 0 and not puzzle.scanning() and not puzzle.done:
		_draw_piece(active, point, puzzle.rotations[active])
		_canvas.draw_rect(Rect2(_slot(active).position, _slot(active).size), CORAL, false)
	var label := "DRAG TO FIT - R ROTATE - ESC CLOSE"
	if puzzle.done:
		label = "WINDOW SEALED - ESC RETURN"
	elif puzzle.scanning():
		label = "MULTITOOL SEALING - ESC CLOSE"
	elif _notice_time > 0:
		label = _notice
	PixelFont.draw(_canvas, Vector2(38, 196), label, TEAL if puzzle.done else MUTED)
	for i in 6:
		_canvas.draw_rect(Rect2(307 + i * 6, 197, 3, 3), TEAL if i < puzzle.fitted() else RIM)


func _draw_scan(cutoff: float) -> void:
	var sy := clampf(cutoff, 41, 132)
	var left := Vector2(135, sy)
	var right := Vector2(249, sy)
	var tip := Vector2(108, clampf(sy - 13, 55, 119))
	if not reduced_motion:
		_canvas.draw_colored_polygon(PackedVector2Array([tip, left, right]), Color("#7fd8ff38"))
		_canvas.draw_line(tip, left, Color("#7fd8ff73"))
		_canvas.draw_line(tip, right, Color("#7fd8ff73"))
		_canvas.draw_rect(Rect2(left - Vector2(0, 2), Vector2(114, 5)), Color("#7fd8ff38"))
		for i in 6:
			var k := fmod(puzzle.scan_age * 1.6 + i * .17, 1.0)
			_canvas.draw_rect(Rect2(Vector2(left.x + 114 * i / 5.0, sy + roundf((1 - k) * 7)), Vector2.ONE), Color("#f4fdff") if k > .75 else Color("#7fd8ff"))
	_canvas.draw_line(left, right, Color("#f4fdff"))
	var frame := int(puzzle.scan_age * 12) % 6
	_canvas.draw_texture_rect_region(_tool, Rect2(tip - Vector2(30, 16), Vector2(40, 32)), Rect2(frame * 40, 0, 40, 32))


static func _ensure_actions() -> void:
	var actions := {"glass_close": [[KEY_ESCAPE], JOY_BUTTON_B], "glass_rotate": [[KEY_R], JOY_BUTTON_LEFT_SHOULDER],
			"glass_next": [[KEY_TAB], JOY_BUTTON_RIGHT_SHOULDER], "glass_previous": [[KEY_Q], -1],
			"glass_place": [[KEY_ENTER, KEY_SPACE, KEY_F], JOY_BUTTON_A]}
	for action in actions:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key in actions[action][0]:
			var e := InputEventKey.new()
			e.physical_keycode = key
			InputMap.action_add_event(action, e)
		if actions[action][1] >= 0:
			var e := InputEventJoypadButton.new()
			e.button_index = actions[action][1]
			InputMap.action_add_event(action, e)
	var x := InputEventJoypadButton.new()
	x.button_index = JOY_BUTTON_X
	if not InputMap.action_has_event("glass_place", x):
		InputMap.action_add_event("glass_place", x)
	for direction in ["left", "right", "up", "down"]:
		var action: String = "glass_" + direction
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, .25)
		for source in InputMap.action_get_events("move_" + direction):
			InputMap.action_add_event(action, source.duplicate())
		var dpad := InputEventJoypadButton.new()
		dpad.button_index = {"left": JOY_BUTTON_DPAD_LEFT, "right": JOY_BUTTON_DPAD_RIGHT,
				"up": JOY_BUTTON_DPAD_UP, "down": JOY_BUTTON_DPAD_DOWN}[direction]
		InputMap.action_add_event(action, dpad)
