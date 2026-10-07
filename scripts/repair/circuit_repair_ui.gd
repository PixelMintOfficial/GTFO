class_name CircuitRepairUI
extends CanvasLayer
## Modal native circuit board, drawn at the game's pixel scale. The model owns ports;
## this view owns octagonal housings, PCB detail and pointer/keyboard/gamepad input.

signal closed

const INK := Color("#d4f3f0")
const MUTED := Color("#9fc5cb")
const DEEP := Color("#051d28")
const PANEL := Color("#092b36")
const MODULE := Color("#0d3540")
const EDGE := Color("#356370")
const TRACE := Color("#24505c")
const LIVE := Color("#72ff3b")
const WIRE := Color("#68909b")
const AMBER := Color("#efb950")
const CASE := Rect2(22, 6, 340, 204)
const CLOSE := Rect2(340, 14, 14, 14)
const DONE := Rect2(294, 194, 56, 10)

var opened := false
var repair: MachineRepair
var _canvas: Control
var _focus := -1
var _hover := -1
var _keyboard := false
var _rotations: Dictionary = {}
var _notice_time := 0.0
var _flow: CircuitPowerFlow
var _completion_seen := false
## Native accessibility hook; the browser also follows the OS reduced-motion preference.
var reduced_motion := OS.get_cmdline_user_args().has("--reduced-motion")


func _ready() -> void:
	layer = 15
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.size = Vector2(384, 216)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_board)
	add_child(_canvas)
	_ensure_actions()
	visible = false


func open(state: MachineRepair) -> void:
	repair = state
	repair.circuit_switched.connect(_switched)
	repair.changed.connect(_changed)
	opened = true
	visible = true
	_keyboard = false
	_switched()
	_notice_time = 0.0
	_canvas.queue_redraw()


func close() -> void:
	if not opened:
		return
	repair.circuit_switched.disconnect(_switched)
	repair.changed.disconnect(_changed)
	_flow = null
	opened = false
	visible = false
	closed.emit()


func _switched() -> void:
	_rotations.clear()
	_flow = null
	_completion_seen = repair.puzzle.solved
	_focus = -1
	for index in repair.puzzle.masks.size():
		if repair.puzzle.movable(index):
			_focus = index
			break
	_hover = -1
	_notice_time = 1.3


func _changed() -> void:
	if not repair.puzzle.solved or _completion_seen:
		return
	_completion_seen = true
	if reduced_motion:
		return
	var route := PackedVector2Array([_terminal_center(true) + Vector2(5, 0)])
	for index in repair.puzzle.connected_path:
		route.append(cell_center(index))
	route.append(_terminal_center(false) + Vector2(2, 0))
	_flow = CircuitPowerFlow.new(route)


func _process(delta: float) -> void:
	if not opened:
		return
	var view := _canvas.get_viewport_rect().size
	var factor := minf(view.x / 384.0, view.y / 216.0)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = ((view - Vector2(384, 216) * factor) * 0.5).floor()
	repair.advance(delta)
	if _flow != null:
		_flow.advance(delta)
	_notice_time = maxf(0.0, _notice_time - delta)
	for index in _rotations.keys():
		_rotations[index][1] -= delta
		if _rotations[index][1] <= 0.0:
			_rotations.erase(index)
	_hover = _at(_canvas.get_local_mouse_position())
	_canvas.queue_redraw()


func _input(event: InputEvent) -> void:
	if not opened:
		return
	if not event.is_echo():
		if event.is_action_pressed("repair_cancel"):
			close()
		elif event is InputEventMouseButton and event.pressed:
			var point: Vector2 = _canvas.get_global_transform().affine_inverse() * event.position
			if event.button_index == MOUSE_BUTTON_LEFT and (CLOSE.has_point(point) or (repair.puzzle.solved and DONE.has_point(point))):
				close()
			elif event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
				var index := _at(point)
				if index >= 0:
					_focus = index
					_keyboard = false
					_turn(index, event.button_index == MOUSE_BUTTON_LEFT)
		elif event.is_action_pressed("repair_turn"):
			_keyboard = true
			if repair.puzzle.solved:
				close()
			else:
				_turn(_focus)
		elif event.is_action_pressed("repair_back"):
			_keyboard = true
			_turn(_focus, false)
		else:
			for direction in ["left", "right", "up", "down"]:
				if event.is_action_pressed("repair_" + direction):
					_move_focus(direction)
	get_viewport().set_input_as_handled()


func _turn(index: int, clockwise := true) -> void:
	if repair.rotate(index, clockwise):
		var offset := -PI / 2.0 if clockwise else PI / 2.0
		if _rotations.has(index):
			offset += _rotation_angle(index)
		if not reduced_motion:
			_rotations[index] = [offset, 0.15]


func _rotation_angle(index: int) -> float:
	if not _rotations.has(index):
		return 0.0
	return _rotations[index][0] * pow(_rotations[index][1] / 0.15, 3)


func _move_focus(direction: String) -> void:
	_keyboard = true
	var p := repair.puzzle
	var step: Vector2i = {"left": Vector2i.LEFT, "right": Vector2i.RIGHT, "up": Vector2i.UP, "down": Vector2i.DOWN}[direction]
	var at := Vector2i(_focus % p.cols, _focus / p.cols)
	for tries in maxi(p.cols, p.rows):
		at = Vector2i(posmod(at.x + step.x, p.cols), posmod(at.y + step.y, p.rows))
		var index := at.y * p.cols + at.x
		if p.movable(index):
			_focus = index
			break


func _pitch() -> int:
	return int(floor(minf(224.0 / repair.puzzle.cols, 136.0 / repair.puzzle.rows)))


func _grid_origin() -> Vector2:
	var p := repair.puzzle
	return (Vector2(192, 124) - Vector2(p.cols, p.rows) * _pitch() * 0.5).floor()


func cell_center(index: int) -> Vector2:
	var p := repair.puzzle
	return (_grid_origin() + Vector2(index % p.cols + 0.5, floori(float(index) / p.cols) + 0.5) * _pitch()).floor()


static func _octagon(center: Vector2, half: float) -> PackedVector2Array:
	var cut := half * 0.58
	return PackedVector2Array([center + Vector2(-cut, -half), center + Vector2(cut, -half),
		center + Vector2(half, -cut), center + Vector2(half, cut),
		center + Vector2(cut, half), center + Vector2(-cut, half),
		center + Vector2(-half, cut), center + Vector2(-half, -cut)])


func _outline(polygon: PackedVector2Array, color: Color) -> void:
	var loop := polygon.duplicate()
	loop.append(polygon[0])
	_canvas.draw_polyline(loop, color, 1)


func _at(point: Vector2) -> int:
	if repair == null:
		return -1
	for index in repair.puzzle.masks.size():
		if repair.puzzle.movable(index) and Geometry2D.is_point_in_polygon(point, _octagon(cell_center(index), (_pitch() - 2) * 0.5)):
			return index
	return -1


func _draw_board() -> void:
	if not opened:
		return
	var p := repair.puzzle
	_canvas.draw_rect(Rect2(0, 0, 384, 216), Color(0.01, 0.025, 0.05, 0.84))
	_canvas.draw_rect(CASE.grow(1), EDGE)
	_canvas.draw_rect(CASE, PANEL)
	_canvas.draw_rect(Rect2(28, 50, 328, 143), DEEP)
	PixelFont.draw(_canvas, Vector2(34, 18), "CIRCUIT REPAIR", INK, 2)
	PixelFont.draw(_canvas, Vector2(34, 36), "ROTATE WIRES TO CONNECT BOTH TERMINALS", MUTED)
	var seconds := "%02d S" % ceili(repair.remaining)
	PixelFont.draw(_canvas, Vector2(300, 21), seconds, AMBER if repair.remaining <= 5.0 else INK)
	_canvas.draw_line(Vector2(344, 18), Vector2(350, 24), MUTED, 1)
	_canvas.draw_line(Vector2(350, 18), Vector2(344, 24), MUTED, 1)
	_canvas.draw_rect(Rect2(34, 45, 316, 1), TRACE)
	_canvas.draw_rect(Rect2(34, 45, 316 * repair.remaining / MachineRepair.ATTEMPT_SECONDS, 1), LIVE if p.solved else EDGE)
	_draw_pcb()
	for index in p.masks.size():
		_draw_module(index)
	_draw_terminal(true)
	_draw_terminal(false)
	_draw_power_flow()
	if p.solved:
		PixelFont.draw(_canvas, Vector2(34, 197), "CIRCUIT CONNECTED", LIVE)
		_canvas.draw_rect(DONE, TRACE)
		PixelFont.draw(_canvas, Vector2(304, 197), "RETURN", INK)
	elif _notice_time > 0.0:
		PixelFont.draw(_canvas, Vector2(34, 197), "CIRCUIT CHANGED", AMBER)
	for corner in [CASE.position + Vector2(4, 4), Vector2(CASE.end.x - 4, CASE.position.y + 4), CASE.end - Vector2(4, 4), Vector2(CASE.position.x + 4, CASE.end.y - 4)]:
		_bolt(corner)


func _draw_pcb() -> void:
	# Symmetric buses sit outside the playable grid; no decoration crosses a live path.
	for side in [-1, 1]:
		var x: int = 192 + side * 143
		for bus in 3:
			var inset: int = side * bus * 4
			var line := PackedVector2Array([Vector2(x - inset, 59), Vector2(x - inset, 75),
				Vector2(x - inset - side * 11, 86), Vector2(x - inset - side * 11, 151),
				Vector2(x - inset, 162), Vector2(x - inset, 181)])
			_canvas.draw_polyline(line, TRACE, 1)
			_canvas.draw_circle(line[0], 1, EDGE)
			_canvas.draw_circle(line[-1], 1, EDGE)
		var chip := Vector2(x - side * 4, 120)
		_canvas.draw_rect(Rect2(chip - Vector2(6, 12), Vector2(12, 24)), MODULE)
		_canvas.draw_rect(Rect2(chip - Vector2(4, 10), Vector2(8, 20)), DEEP)
		for pin in 5:
			for edge in [-1, 1]:
				_canvas.draw_line(chip + Vector2(edge * 5, -8 + pin * 4), chip + Vector2(edge * 8, -8 + pin * 4), EDGE, 1)
		_canvas.draw_rect(Rect2(chip + Vector2(-2, -8), Vector2.ONE), WIRE)
		for part in 3:
			var c := Vector2(x - side * 29, 65 + part * 54)
			_canvas.draw_rect(Rect2(c - Vector2(1, 3), Vector2(2, 6)), MODULE)
			_canvas.draw_rect(Rect2(c - Vector2(1, 3), Vector2(2, 1)), EDGE)
			_canvas.draw_rect(Rect2(c + Vector2(-1, 2), Vector2(2, 1)), EDGE)
			_canvas.draw_polyline(PackedVector2Array([c + Vector2(0, 4), c + Vector2(0, 9), c + Vector2(side * 8, 17)]), TRACE, 1)
		for hole in [Vector2(x, 57), Vector2(x, 185)]:
			_canvas.draw_circle(hole, 2, TRACE)
			_canvas.draw_circle(hole, 1, DEEP)


func _draw_module(index: int) -> void:
	var p := repair.puzzle
	var c := cell_center(index)
	var half := (_pitch() - 2) * 0.5
	var polygon := _octagon(c, half)
	var live := p.powered[index] != 0
	var empty := p.masks[index] == 0
	_canvas.draw_colored_polygon(polygon, TRACE if p.fixed[index] else MODULE)
	var focus := not p.solved and ((_keyboard and index == _focus) or index == _hover)
	_outline(polygon, INK if focus else (WIRE if p.fixed[index] else EDGE))
	var inset := _octagon(c, half - 1.5)
	_canvas.draw_colored_polygon(inset, Color("#0c342f") if live else (DEEP if empty else PANEL))
	_outline(inset, TRACE)
	_canvas.draw_line(polygon[0], polygon[1], INK if focus else WIRE, 1)
	if empty:
		_canvas.draw_line(c + Vector2(-2, 0), c + Vector2(2, 0), TRACE, 1)
		return
	for x in [-1, 1]:
		for y in [-1, 1]:
			var detail := PackedVector2Array([c + Vector2(x * half * 0.7, y * half * 0.2),
				c + Vector2(x * half * 0.7, y * half * 0.42), c + Vector2(x * half * 0.42, y * half * 0.7),
				c + Vector2(x * half * 0.2, y * half * 0.7)])
			_canvas.draw_polyline(detail, TRACE, 1)
			_canvas.draw_rect(Rect2(detail[-1].floor(), Vector2.ONE), EDGE)
	_canvas.draw_set_transform(c, _rotation_angle(index))
	for direction in 4:
		if p.masks[index] & (1 << direction):
			var end := Vector2(CircuitPuzzle.STEPS[direction]) * (_pitch() * 0.5)
			_canvas.draw_line(Vector2.ZERO, end, Color(LIVE, 0.14) if live else DEEP, 4)
			_canvas.draw_line(Vector2.ZERO, end, LIVE if live else WIRE, 1)
			_canvas.draw_line(end * 0.77, end * 0.88, Color("#c5ff9e") if live else INK, 1)
	_canvas.draw_circle(Vector2.ZERO, 2, LIVE if live else EDGE, false, 1)
	_canvas.draw_circle(Vector2.ZERO, 1, Color("#c5ff9e") if live else WIRE)
	_canvas.draw_set_transform(Vector2.ZERO)
	if p.fixed[index]:
		for x in [-1, 1]:
			for y in [-1, 1]:
				var mount := (c + Vector2(x, y) * half * 0.55).round()
				_canvas.draw_rect(Rect2(mount - Vector2(2, 2), Vector2(4, 4)), MODULE)
				_bolt(mount)


func _bolt(point: Vector2) -> void:
	_canvas.draw_circle(point, 1.7, WIRE)
	_canvas.draw_rect(Rect2(point + Vector2(-1, -1), Vector2.ONE), INK)
	_canvas.draw_line(point - Vector2(1, 0), point + Vector2(1, 0), DEEP, 1)


func _terminal_center(supply: bool) -> Vector2:
	var p := repair.puzzle
	var row := int(p.definition["startRow"] if supply else p.definition["endRow"])
	var index := row * p.cols + (0 if supply else p.cols - 1)
	var center := cell_center(index)
	return center + Vector2((-1 if supply else 1) * (_pitch() * 0.5 + 24), 0)


static func _terminal_housing(c: Vector2, inset := 0.0) -> PackedVector2Array:
	var x := 16.0 - inset
	var y := 13.0 - inset
	return PackedVector2Array([c + Vector2(-x + 4, -y), c + Vector2(x - 4, -y),
		c + Vector2(x, -y + 4), c + Vector2(x, y - 4), c + Vector2(x - 4, y),
		c + Vector2(-x + 4, y), c + Vector2(-x, y - 4), c + Vector2(-x, -y + 4)])


func _receiver_live() -> bool:
	return repair.puzzle.solved and (_flow == null or _flow.arrived())


func _draw_terminal(supply: bool) -> void:
	var c := _terminal_center(supply)
	var direction := 1 if supply else -1
	var color := LIVE if supply or _receiver_live() else AMBER
	var lead := c + Vector2(direction * 24, 0)
	_canvas.draw_line(c, lead, DEEP, 4)
	_canvas.draw_line(c, lead, color, 1)
	_canvas.draw_rect(Rect2(c + Vector2(direction * 17 - 1, -2), Vector2(3, 4)), WIRE)
	_canvas.draw_line(c + Vector2(direction * 16, 0), lead, color, 1)
	_canvas.draw_colored_polygon(_terminal_housing(c), MODULE)
	_outline(_terminal_housing(c), WIRE)
	_canvas.draw_colored_polygon(_terminal_housing(c, 2), PANEL)
	_outline(_terminal_housing(c, 2), TRACE)
	_canvas.draw_line(c + Vector2(-11, -13), c + Vector2(11, -13), INK, 1)
	for x in [-1, 1]:
		for y in [-1, 1]:
			_bolt(c + Vector2(x * 12, y * 9))
	if supply:
		# Three charged capacitors feed the right-facing bus and socket.
		for x in [-8, -2, 4]:
			_canvas.draw_rect(Rect2(c + Vector2(x - 2, -4), Vector2(4, 9)), WIRE)
			_canvas.draw_line(c + Vector2(x - 1, -4), c + Vector2(x + 1, -4), INK, 1)
			_canvas.draw_rect(Rect2(c + Vector2(x - 1, 1), Vector2(2, 3)), LIVE)
		_canvas.draw_polyline(PackedVector2Array([c + Vector2(8, -3), c + Vector2(8, 0), c + Vector2(16, 0)]), LIVE, 1)
		_canvas.draw_polyline(PackedVector2Array([c + Vector2(0, 7), c + Vector2(-2, 9), c + Vector2(1, 9), c + Vector2(-1, 11)]), LIVE, 1)
		for led in 3:
			_canvas.draw_rect(Rect2(c + Vector2(-6 + led * 4, -9), Vector2(3, 2)), LIVE)
	else:
		# A relay contact closes when the pulse reaches the receiving module.
		_canvas.draw_line(c + Vector2(-16, 0), c + Vector2(-3, 0), color, 1)
		_canvas.draw_rect(Rect2(c + Vector2(-3, -5), Vector2(10, 10)), DEEP)
		_canvas.draw_rect(Rect2(c + Vector2(-3, -5), Vector2(10, 10)), color, false, 1)
		_canvas.draw_line(c + Vector2(-1, 0), c + Vector2(4, 0 if _receiver_live() else -2), color, 1)
		for y in [-3, 0, 3]:
			_canvas.draw_line(c + Vector2(8, y), c + Vector2(12, y), EDGE, 1)
		for led in 3:
			_canvas.draw_rect(Rect2(c + Vector2(-6 + led * 4, 8), Vector2(3, 2)), color if _receiver_live() else TRACE)
		_canvas.draw_rect(Rect2(c + Vector2(-5, -9), Vector2(10, 1)), color)
		if _flow != null and _flow.arrived() and not _flow.finished():
			var phase := _flow.arrival_phase()
			_outline(_terminal_housing(c, -phase * 3), Color(LIVE, 1.0 - phase))


func _draw_power_flow() -> void:
	if _flow == null or _flow.finished() or _flow.elapsed <= CircuitPowerFlow.START_DELAY:
		return
	var head := _flow.progress() * _flow.length
	var tail := float(_pitch()) * 1.8
	var fade := 1.0 - _flow.arrival_phase()
	for part in 3:
		var section := _flow.section(head - tail + tail * part / 3.0, head - tail + tail * (part + 1) / 3.0)
		if section.size() < 2:
			continue
		_canvas.draw_polyline(section, Color(LIVE, fade * 0.15), 5)
		_canvas.draw_polyline(section, Color(LIVE, fade * (0.4 + part * 0.3)), 2)
	var point := _flow.sample(head).round()
	_canvas.draw_circle(point, 2, Color(LIVE, fade))
	_canvas.draw_rect(Rect2(point - Vector2.ONE, Vector2(2, 2)), Color("#e4ffcb", fade))


static func _ensure_actions() -> void:
	var setup := {
		"repair_cancel": [[KEY_ESCAPE], JOY_BUTTON_B],
		"repair_turn": [[KEY_ENTER, KEY_SPACE, KEY_F], JOY_BUTTON_A],
		"repair_back": [[KEY_Q], JOY_BUTTON_LEFT_SHOULDER],
		"repair_left": [[KEY_LEFT, KEY_A], JOY_BUTTON_DPAD_LEFT],
		"repair_right": [[KEY_RIGHT, KEY_D], JOY_BUTTON_DPAD_RIGHT],
		"repair_up": [[KEY_UP, KEY_W], JOY_BUTTON_DPAD_UP],
		"repair_down": [[KEY_DOWN, KEY_S], JOY_BUTTON_DPAD_DOWN],
	}
	for action in setup:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for code in setup[action][0]:
			var key := InputEventKey.new()
			key.physical_keycode = code
			InputMap.action_add_event(action, key)
		var pad := InputEventJoypadButton.new()
		pad.button_index = setup[action][1]
		InputMap.action_add_event(action, pad)
