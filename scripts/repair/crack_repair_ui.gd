class_name CrackRepairUI
extends CanvasLayer
## Full-screen untimed crack task, displaying a wall crop of the owner's original panel PNG.
## The generator measures the baked holes; legacy generated inspection panels remain supported.
## The teal console, pale silver scraps and wear marks match the approved browser draft.
## Click/drag a scrap from the tray onto a hole; hold and move to weld its perimeter.
## Draft torch and layered, rounded weld beads with stroke-aligned crescent ridges, sparks,
## and a one-second teal seal glow. Cached pixel discs keep each bead inexpensive to draw.
## Input is modal; Q/left shoulder selects scrap, arrows/d-pad move a virtual torch, F/A holds.
## --reduced-motion removes sparks/flicker. Model and inventory live outside this view.

signal closed
signal continued

const INK := Color("#fbfbff")
const DARK := Color("#22182c")
const STEEL := Color("#62627f")
const LIGHT := Color("#9496b4")
const HOT := Color("#ff5a4a")
const GOLD := Color("#efb950")
const TEAL := Color("#4fc6b4")
const DEEP := Color("#051d28")
const PANEL := Color("#092b36")
const EDGE := Color("#356370")
const MUTED := Color("#9fc5cb")
const SILVER := Color("#d5d8e5")
const SILVER_SHADOW := Color("#9a9bb6")
const CORAL := Color("#ec7a5a")
const W_EDGE := Color("#343648")
const W_COOL := Color("#64646e")
const W_LIGHT := Color("#8e98af")
const W_WARM := Color("#d74e45")
const W_DIM := Color("#8c383a")
const W_CORE := Color("#fda49d")
const W_GROOVE := Color("#2f2e40")
const W_HEAT := Color("#dcbab9")
const CASE := Rect2(12, 8, 360, 200)
const WALL := Rect2(24, 50, 336, 117)
const CLOSE := Rect2(346, 16, 14, 14)
const NEXT := Rect2(321, 184, 39, 17)
const SCUFFS := [
	[[-16,-9, -7,-5], [-12,-10, -4,-6], [5,5, 16,8], [-15,6, -10,9]],
	[[-13,2, -2,-2], [-10,5, 2,1], [9,-9, 15,-4], [-4,12, 7,10]],
	[[-18,-4, -8,-6], [-14,-1, -4,-3], [7,9, 17,5], [2,-11, 5,-6]]]

var opened := false
var repair: MachineRepair
var model: CrackPuzzle
var reduced_motion := OS.get_cmdline_user_args().has("--reduced-motion")
var _canvas: Control
var _machine: Texture2D
var _source_rect := Rect2()
var _baked_damage := false
var _discs: Dictionary = {}
var _origin := Vector2.ZERO
var _cursor := Vector2.ZERO
var _last := Vector2.ZERO
var _held := false
var _carried := -1
var _focus := 0
var _keyboard := false
var _press_at := Vector2.ZERO
var _sparks: Array = []
var _spark_time := 0.0
var _settled := 0.0
var _notice := 0.0
var _anchor := Vector2.ZERO
var _mouse_mode := Input.MOUSE_MODE_VISIBLE
var _contact := false
var _elapsed := 0.0


func _ready() -> void:
	layer = 15
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Control.new()
	_canvas.size = Vector2(384, 216)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_canvas.draw.connect(_draw_board)
	add_child(_canvas)
	CircuitRepairUI._ensure_actions()
	visible = false


func open(state: MachineRepair, info: Dictionary) -> void:
	repair = state
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/maps/base_interior/machines/machines.json"))
	var sprite: Dictionary = meta[state.machine_id + "_generator"]
	var inspection: Dictionary = sprite["repair_panel"]
	_machine = load("res://assets/maps/base_interior/" + inspection["file"])
	var region: Array = inspection.get("source_rect", [0, 0, _machine.get_width(), _machine.get_height()])
	_source_rect = Rect2(region[0], region[1], region[2], region[3])
	_baked_damage = inspection.get("baked_damage", false)
	_origin = WALL.position
	var points := PackedVector2Array()
	for point in inspection["sites"]:
		points.append(_origin + Vector2(point[0], point[1]))
	if state.cracks == null:
		state.cracks = CrackPuzzle.new(points)
	else:
		state.cracks.relocate(points)
	model = state.cracks
	model.damage_samples.clear()
	for samples: Array in inspection.get("damage_samples", []):
		var offsets := PackedVector2Array()
		for sample: Array in samples:
			offsets.append(Vector2(sample[0], sample[1]))
		model.damage_samples.append(offsets)
	_anchor = Vector2(info["progress_px"][0], info["progress_px"][1])
	_carried = -1
	_held = false
	_contact = false
	_settled = 0
	_sparks.clear()
	_cursor = _canvas.get_local_mouse_position()
	_last = _cursor
	opened = true
	visible = true
	_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	Audio.play("ui_panel_open")
	_canvas.queue_redraw()


func close(to_circuit := false) -> void:
	if not opened:
		return
	opened = false
	visible = false
	_held = false
	Input.mouse_mode = _mouse_mode
	Audio.release("repair:weld")
	Audio.play("ui_panel_close")
	if to_circuit:
		continued.emit()
	else:
		closed.emit()


func _exit_tree() -> void:
	if opened:
		Input.mouse_mode = _mouse_mode
		Audio.release("repair:weld")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_held = false
		if opened:
			Audio.release("repair:weld")


func _process(delta: float) -> void:
	if not opened:
		return
	var view := _canvas.get_viewport_rect().size
	var factor := minf(view.x / 384, view.y / 216)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = ((view - Vector2(384, 216) * factor) * .5).floor()
	if _keyboard:
		_cursor += Input.get_vector("repair_left", "repair_right", "repair_up", "repair_down") * delta * 65
		_cursor = _cursor.clamp(Vector2(12, 9), Vector2(371, 207))
	model.advance_visuals(delta)
	_elapsed += delta
	_contact = false
	_notice = maxf(0, _notice - delta)
	if _held and _carried < 0 and not repair.task_completed("cracks"):
		_contact = model.stroke(_last, _cursor, delta)
		if _contact:
			Audio.loop("beam_fix", "repair:weld", _anchor)
			_spark_time -= delta
			if not reduced_motion and _spark_time <= 0:
				_spark_time = .035
				for i in 3:
					if _sparks.size() >= 48:
						_sparks.pop_front()
					var angle := randf_range(-PI, -.08)
					_sparks.append([_cursor, Vector2(cos(angle), sin(angle)) * randf_range(30, 85), 0.0, randf_range(.22, .5)])
		else:
			Audio.release("repair:weld")
	else:
		model.cool(delta)
		Audio.release("repair:weld")
	_last = _cursor
	for i in range(_sparks.size() - 1, -1, -1):
		var spark: Array = _sparks[i]
		spark[2] += delta
		if spark[2] >= spark[3]:
			_sparks.remove_at(i)
		else:
			spark[1] += Vector2(0, 150) * delta
			spark[0] += spark[1] * delta
	if model.solved():
		if not repair.task_completed("cracks"):
			if repair.finish_cracks():
				Audio.play("repair_done")
			else:
				_notice = 1
		_settled += delta
	_canvas.queue_redraw()


func _input(event: InputEvent) -> void:
	if not opened:
		return
	if event.is_action_pressed("repair_cancel") and not event.is_echo():
		close()
	elif event is InputEventMouseMotion:
		_keyboard = false
		_cursor = _canvas.get_global_transform().affine_inverse() * event.position
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_keyboard = false
		_cursor = _canvas.get_global_transform().affine_inverse() * event.position
		if event.pressed:
			_press()
		else:
			_held = false
			if _carried >= 0 and _cursor.distance_to(_press_at) > 4:
				_place()
	elif event.is_action_pressed("repair_back") and not event.is_echo():
		_keyboard = true
		_carried = -1
		for i in 3:
			_focus = (_focus + 1) % 3
			if model.available(_focus):
				break
		_cursor = _slot(_focus).get_center()
	elif event.is_action_pressed("repair_turn") and not event.is_echo():
		_keyboard = true
		_press()
	elif event.is_action_released("repair_turn"):
		_held = false
	elif event.is_action_pressed("repair_left") or event.is_action_pressed("repair_right") or event.is_action_pressed("repair_up") or event.is_action_pressed("repair_down"):
		if not _keyboard:
			_cursor = _slot(_focus).get_center()
		_keyboard = true
	get_viewport().set_input_as_handled()


func _press() -> void:
	_press_at = _cursor
	_last = _cursor
	if CLOSE.has_point(_cursor):
		close()
		return
	if repair.task_completed("cracks"):
		if _settled >= 1 and (NEXT.has_point(_cursor) or _keyboard):
			close(true)
		return
	if _carried >= 0:
		_place()
		return
	for i in 3:
		if _slot(i).has_point(_cursor) and model.available(i):
			_carried = i
			_focus = i
			Audio.play("ui_pick")
			return
	_held = true


func _place() -> void:
	if model.place(_carried, _cursor) >= 0:
		_carried = -1
		Audio.play("ui_place")
	else:
		Audio.play("ui_deny")
		_notice = 1.2
	_held = false


static func _slot(index: int) -> Rect2:
	return Rect2(119 + index * 70, 175, 58, 29)


func _draw_board() -> void:
	if not opened:
		return
	_canvas.draw_rect(Rect2(0, 0, 384, 216), DEEP)
	_canvas.draw_rect(CASE, DARK)
	_canvas.draw_rect(Rect2(13, 9, 358, 197), PANEL)
	_canvas.draw_line(Vector2(14, 10), Vector2(370, 10), EDGE, 1)
	_canvas.draw_texture_rect_region(_machine, WALL, _source_rect)
	PixelFont.draw(_canvas, Vector2(24, 19), "CRACK REPAIR", Color("#d4f3f0"), 2)
	_canvas.draw_rect(Rect2(24, 32, 99, 2), Color("#ec7a5a"))
	PixelFont.draw(_canvas, Vector2(24, 39), "PLACE SCRAP - WELD THE PERIMETER", MUTED)
	PixelFont.draw(_canvas, Vector2(24, 185), "SCRAP", MUTED)
	for i in 3:
		var box := _slot(i)
		_canvas.draw_rect(box, TEAL if _carried == i else EDGE)
		_canvas.draw_rect(box.grow(-1), DEEP)
		_canvas.draw_rect(box.grow(-2), Color("#24505c") if _carried == i else PANEL)
		if model.available(i) and _carried != i:
			_draw_scrap(i, box.get_center(), .4)
		elif model.placed.has(i):
			PixelFont.draw(_canvas, box.position + Vector2(18, 11), "PLACED", MUTED)
		if _keyboard and i == _focus:
			_canvas.draw_rect(box.grow(2), GOLD, false, 1)
	for i in 3:
		if model.placed[i] < 0:
			if not _baked_damage:
				for branch: PackedVector2Array in model.fractures[i]:
					_draw_damage(CrackPuzzle.translated(branch, model.sites[i]))
				_draw_damage(CrackPuzzle.translated(model.holes[i], model.sites[i]))
			continue
		_draw_scrap(model.placed[i], model.positions[i])
	_draw_welds()
	for i in 3:
		if model.glow[i] > 0:
			var shape := CrackPuzzle.translated(model.shapes[model.placed[i]], model.positions[i])
			_canvas.draw_colored_polygon(shape, Color(TEAL, .45 * (1 if reduced_motion else model.glow[i])))
			_outline(shape, Color(TEAL, model.glow[i]))
	if _carried >= 0:
		var valid := false
		for i in 3:
			valid = valid or model.can_place(_carried, _cursor.round(), i)
		_draw_scrap(_carried, _cursor.round())
		_outline(CrackPuzzle.translated(model.shapes[_carried], _cursor.round()), TEAL if valid else HOT)
	elif not repair.task_completed("cracks"):
		_draw_torch()
	for spark in _sparks:
		var p: Vector2 = spark[0].round()
		var fade: float = 1 - spark[2] / spark[3]
		_canvas.draw_line(p, (p - spark[1] * .025).round(), Color(HOT, fade), 1)
		_canvas.draw_rect(Rect2(p, Vector2.ONE), Color(Color("#fff0a0"), fade))
	_canvas.draw_line(CLOSE.position + Vector2(2, 2), CLOSE.end - Vector2(3, 3), MUTED, 1)
	_canvas.draw_line(CLOSE.position + Vector2(2, 11), CLOSE.position + Vector2(11, 2), MUTED, 1)
	if repair.task_completed("cracks"):
		_canvas.draw_rect(NEXT, EDGE, false, 1)
		PixelFont.draw(_canvas, NEXT.position + Vector2(6, 6), "CIRCUIT", TEAL if _settled >= 1 else MUTED)
	elif _notice > 0:
		PixelFont.draw(_canvas, Vector2(24, 197), "COVER THE HOLE" if not model.solved() else "NEED 3 SCRAP", GOLD)
	elif model.overheated or model.heat > .75:
		PixelFont.draw(_canvas, Vector2(24, 197), "LIFT TO COOL" if model.overheated else "KEEP MOVING", HOT)


func _draw_scrap(piece: int, at: Vector2, scale_value := 1.0) -> void:
	var shape := PackedVector2Array()
	for p in model.shapes[piece]:
		shape.append((at + p * scale_value).round())
	_canvas.draw_colored_polygon(CrackPuzzle.translated(shape, Vector2(1, 2)), SILVER_SHADOW)
	_canvas.draw_colored_polygon(shape, SILVER_SHADOW)
	_outline(shape, DARK)
	var inset := PackedVector2Array()
	for p in model.shapes[piece]:
		inset.append((at + p * Vector2(.93, .91) * scale_value).round())
	_canvas.draw_colored_polygon(inset, SILVER)
	for i in shape.size():
		var a := shape[i]
		var b := shape[(i + 1) % shape.size()]
		if b.x > a.x:
			_canvas.draw_line(a + Vector2(0, 1), b + Vector2(0, 1), INK, 1)
	var detail_scale := CrackPuzzle.DAMAGE_SCALE * scale_value
	for scuff in SCUFFS[piece]:
		var a := (at + Vector2(scuff[0], scuff[1]) * detail_scale).round()
		var b := (at + Vector2(scuff[2], scuff[3]) * detail_scale).round()
		_canvas.draw_line(a - Vector2(0, 1), b - Vector2(0, 1), INK, 1)
		_canvas.draw_line(a, b, SILVER_SHADOW, 1)
	# Bent lips and shallow dents retain the approved clean silver palette, without rust.
	var fold := PackedVector2Array([Vector2(-23, -13), Vector2(-14, -20), Vector2(-18, -12)]) if piece == 1 else PackedVector2Array([Vector2(19, -17), Vector2(26, -12), Vector2(18, -11)])
	for i in fold.size():
		fold[i] = (at + fold[i] * detail_scale).round()
	_canvas.draw_colored_polygon(fold, SILVER_SHADOW)
	_canvas.draw_line(fold[0], fold[2], INK, 1)
	_canvas.draw_line((at + Vector2(-16, 12) * detail_scale).round(), (at + Vector2(-8, 14) * detail_scale).round(), SILVER_SHADOW, 1)
	_canvas.draw_line((at + Vector2(-16, 11) * detail_scale).round(), (at + Vector2(-8, 13) * detail_scale).round(), INK, 1)


func _draw_damage(shape: PackedVector2Array) -> void:
	_canvas.draw_colored_polygon(CrackPuzzle.translated(shape, Vector2(1, 1)), STEEL)
	_canvas.draw_colored_polygon(CrackPuzzle.translated(shape, Vector2(-1, -1)), INK)
	_canvas.draw_colored_polygon(shape, Color("#0b0915"))
	_outline(shape, DARK)


func _outline(shape: PackedVector2Array, color: Color) -> void:
	var path := shape.duplicate()
	path.append(path[0])
	_canvas.draw_polyline(path, color, 1)


func _draw_torch() -> void:
	var p := _cursor.round()
	var working := _contact and _held and not model.overheated
	var tip := HOT if model.overheated else GOLD if model.heat >= .75 else Color("#7fe6cf") if working else INK if model.on_perimeter(p) >= 0 else SILVER_SHADOW
	var body := PackedVector2Array([Vector2(3,-7), Vector2(7,-12), Vector2(12,-9), Vector2(14,-5), Vector2(8,1), Vector2(4,-2)])
	_canvas.draw_colored_polygon(CrackPuzzle.translated(body, p + Vector2(1, 2)), SILVER_SHADOW)
	_canvas.draw_colored_polygon(CrackPuzzle.translated(body, p), DARK)
	var inset := PackedVector2Array([Vector2(5,-7), Vector2(8,-10), Vector2(11,-8), Vector2(12,-5), Vector2(8,-1), Vector2(5,-3)])
	_canvas.draw_colored_polygon(CrackPuzzle.translated(inset, p), SILVER_SHADOW if model.overheated else CORAL)
	_pixel_line(p + Vector2(7,-10), p + Vector2(11,-7), GOLD, 2)
	_pixel_line(p + Vector2(10,-5), p + Vector2(8,-3), DARK, 2)
	_canvas.draw_rect(Rect2(p + Vector2(8,-9), Vector2.ONE), INK)
	var nozzle := PackedVector2Array([Vector2.ZERO, Vector2(2,-6), Vector2(6,-3), Vector2(2,1)])
	_canvas.draw_colored_polygon(CrackPuzzle.translated(nozzle, p), DARK)
	_pixel_line(p + Vector2(1,-1), p + Vector2(3,-4), Color("#68909b"), 2)
	_canvas.draw_rect(Rect2(p, Vector2(2, 2)), tip)
	if working:
		_canvas.draw_rect(Rect2(p, Vector2.ONE), INK)


## The approved draft's pixel-disc filler: shoulders, raised metal, then crescent ridges.
func _draw_welds() -> void:
	var radius := CrackPuzzle.BRUSH
	var hits := model.deposits.values()
	for hit: Array in hits:
		_disc(hit[0] + Vector2.ONE, radius + .5, SILVER_SHADOW)
	for hit: Array in hits:
		_disc(hit[0], radius + .2, W_HEAT if hit[3] < 1.8 else W_EDGE)
	for hit: Array in hits:
		var age: float = hit[3]
		_disc(hit[0], radius - .3, HOT if age < .35 else W_WARM if age < 1.2 else W_DIM if age < 3.2 else W_COOL)
	for hit: Array in hits:
		var age: float = hit[3]
		_disc(hit[0] - Vector2(.7, .7), maxf(1, radius - 1.3), W_CORE if age < .35 else CORAL if age < 1.2 else W_WARM if age < 3.2 else W_LIGHT)
	for hit: Array in hits:
		if roundi(hit[2]) % 5 > 1:
			continue
		var p: Vector2 = hit[0]
		var tangent: Vector2 = hit[1]
		var age: float = hit[3]
		var normal := Vector2(-tangent.y, tangent.x)
		var span := maxf(1, radius - 1)
		var ridge := PackedVector2Array()
		for j in range(-2, 3):
			var side := j * span / 2
			var bulge := 1.1 * (1 - pow(float(j) / 2, 2))
			ridge.append(p + normal * side + tangent * bulge)
		for j in range(1, ridge.size()):
			_pixel_line(ridge[j - 1], ridge[j], W_DIM if age < 1.2 else W_GROOVE)
		var light := -1 if normal.x + normal.y < 0 else 1
		var edge := p - normal * span * light - Vector2(.5, .5)
		_pixel_line(edge, edge + tangent, INK if age < .35 else W_CORE if age < 1.2 else CORAL if age < 3.2 else W_LIGHT)
	if _contact and _held and not model.overheated:
		var flicker := 0.0 if reduced_motion else (floori(_elapsed * 24) % 3) * .15
		_disc(_cursor, radius + flicker, W_DIM)
		_disc(_cursor, maxf(1.6, radius - .6) + flicker, HOT)
		_disc(_cursor - Vector2(.5, .5), maxf(1, radius - 1.4), GOLD)
		_canvas.draw_rect(Rect2(_cursor.round() - Vector2.ONE, Vector2(2, 2)), W_CORE)
		_canvas.draw_rect(Rect2(_cursor.round(), Vector2.ONE), INK)


func _disc(at: Vector2, radius: float, color: Color) -> void:
	var key := roundi(radius * 100)
	var extent := floori(radius)
	if not _discs.has(key):
		var image := Image.create(extent * 2 + 1, extent * 2 + 1, false, Image.FORMAT_RGBA8)
		for y in range(-extent, extent + 1):
			var width := floori(sqrt(radius * radius - y * y))
			for x in range(-width, width + 1):
				image.set_pixel(x + extent, y + extent, Color.WHITE)
		_discs[key] = ImageTexture.create_from_image(image)
	_canvas.draw_texture(_discs[key], at.round() - Vector2.ONE * extent, color)


func _pixel_line(from: Vector2, to: Vector2, color: Color, width := 1) -> void:
	var a := Vector2i(from.round())
	var b := Vector2i(to.round())
	var dx := absi(b.x - a.x)
	var dy := -absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var error := dx + dy
	while true:
		_canvas.draw_rect(Rect2(Vector2(a) - Vector2.ONE * floori(float(width) / 2), Vector2.ONE * width), color)
		if a == b:
			break
		var twice := error * 2
		if twice >= dy:
			error += dy
			a.x += sx
		if twice <= dx:
			error += dx
			a.y += sy
