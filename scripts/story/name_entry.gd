class_name NameEntry
extends CanvasLayer
## Telling the bot your name: a plate in the time panel's style with its question, the name in
## big PixelFont with a blinking cursor, and a letter grid (its last keys: SPC, DEL, OK). Type it
## on the keyboard (A-Z, 0-9, space, -; Backspace; Enter), or pick letters on a gamepad (d-pad
## moves, A picks, B deletes, Start confirms) or with the mouse. Prefilled with the name you gave last time. It pauses the
## world and takes every key, button and click while it is open; it cannot be cancelled - the
## bot needs a name.
## remember = false (tests and the --name hook) keeps it out of the player's profile.
## Test hook: auto_name, typed and confirmed a moment after it opens.

const RECT := Rect2(82, 40, 220, 124)
const GRID := "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
const SPECIAL := ["SPC", "DEL", "OK"]
const COLS := 10
const CELL := Vector2(18, 12)
const TEXT := Color("#f2f0f8")
const ACCENT := Color("#7fe6cf")
const DIM := Color("#8f8ba8")

var opened := false
var remember := true
var auto_name := ""
var text := ""

var _canvas: Node2D
var _title := ""
var _max := 12
var _cursor := 0
var _then := Callable()
var _paused_here := false
var _t := 0.0
var _auto_t := 0.0
var _drawn: Variant = null      # what the plate showed last time it was drawn


func _ready() -> void:
	layer = 14
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = Node2D.new()
	_canvas.draw.connect(_draw_entry)
	add_child(_canvas)


## settings: data/bot_story.json -> name_entry (title, max_length).
func open(settings: Dictionary, prefill: String, then: Callable) -> void:
	_title = GameState.story.text(settings["title"])
	_max = int(settings["max_length"])
	text = _clean(prefill).substr(0, _max)
	_cursor = 0
	_then = then
	opened = true
	_auto_t = 0.0
	_paused_here = not get_tree().paused
	get_tree().paused = true
	Audio.play("ui_panel_open")


func _confirm() -> void:
	if text.strip_edges() == "":
		Audio.play("ui_deny")
		return
	opened = false
	if _paused_here:
		get_tree().paused = false
	_paused_here = false
	Audio.play("ui_place")
	var then := _then
	_then = Callable()
	then.call(text.strip_edges())


func _type(ch: String) -> void:
	if text.length() >= _max:
		Audio.play("ui_deny")
		return
	if ch == " " and (text == "" or text.ends_with(" ")):
		return
	text += ch
	Audio.play("ui_slot")


func _delete() -> void:
	if text != "":
		text = text.substr(0, text.length() - 1)
		Audio.play("ui_slot")


## Only what PixelFont can draw and a name needs.
static func _clean(s: String) -> String:
	var out := ""
	for ch in s.to_upper():
		if GRID.contains(ch) or ch == " ":
			out += ch
	return out


func _cells() -> int:
	return GRID.length() + SPECIAL.size()


func _pick(i: int) -> void:
	if i < GRID.length():
		_type(GRID[i])
	elif SPECIAL[i - GRID.length()] == "SPC":
		_type(" ")
	elif SPECIAL[i - GRID.length()] == "DEL":
		_delete()
	else:
		_confirm()


func _input(event: InputEvent) -> void:
	if not opened:
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventMouseButton):
		return
	get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed:
		var k: InputEventKey = event
		match k.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				_confirm()
			KEY_BACKSPACE:
				_delete()
			KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN:
				_move(k.keycode)
			_:
				var ch := _clean(char(k.unicode)) if k.unicode > 0 else ""
				if ch != "" and not k.is_echo():
					_type(ch)
	elif event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_DPAD_LEFT:
				_move(KEY_LEFT)
			JOY_BUTTON_DPAD_RIGHT:
				_move(KEY_RIGHT)
			JOY_BUTTON_DPAD_UP:
				_move(KEY_UP)
			JOY_BUTTON_DPAD_DOWN:
				_move(KEY_DOWN)
			JOY_BUTTON_A:
				_pick(_cursor)
			JOY_BUTTON_B:
				_delete()
			JOY_BUTTON_START:
				_confirm()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var i := _cell_at(_canvas.get_local_mouse_position())
		if i >= 0:
			_cursor = i
			_pick(i)


func _move(key: int) -> void:
	var n := _cells()
	match key:
		KEY_LEFT:
			_cursor = posmod(_cursor - 1, n)
		KEY_RIGHT:
			_cursor = posmod(_cursor + 1, n)
		KEY_UP:
			_cursor = posmod(_cursor - COLS, n)
		KEY_DOWN:
			_cursor = _cursor + COLS if _cursor + COLS < n else _cursor % COLS
	Audio.play("ui_slot")


func _process(delta: float) -> void:
	var view := _canvas.get_viewport_rect().size
	var factor := minf(view.x / 384.0, view.y / 216.0)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = ((view - Vector2(384, 216) * factor) * 0.5).floor()
	_t += delta
	if opened and auto_name != "":
		_auto_t += delta
		if _auto_t > 0.8:
			text = _clean(auto_name).substr(0, _max)
			auto_name = ""
			_confirm()
	# Redraw only when what it shows has changed: the name, the picked key, the cursor blinking,
	# opening or closing (as DayClock does).
	var state := [opened, text, _cursor, fmod(_t, 0.9) < 0.55]
	if state != _drawn:
		_drawn = state
		_canvas.queue_redraw()


# ---------------------------------------------------------------- drawing
func _cell_rect(i: int) -> Rect2:
	var grid := RECT.position + Vector2(20, 58)
	return Rect2(grid + Vector2(i % COLS, i / COLS) * CELL, CELL - Vector2(2, 2))


func _cell_at(p: Vector2) -> int:
	for i in _cells():
		if _cell_rect(i).has_point(p):
			return i
	return -1


func _draw_entry() -> void:
	if not opened:
		return
	var r := RECT
	_canvas.draw_rect(Rect2(Vector2.ZERO, Vector2(384, 216)), Color(0.02, 0.016, 0.04, 0.35))
	_canvas.draw_rect(Rect2(r.position + Vector2(1, 1), r.size - Vector2(2, 2)), DayClock.PLATE)
	_canvas.draw_rect(r, DayClock.EDGE, false, 1.0)
	_canvas.draw_rect(Rect2(r.position + Vector2(2, 1), Vector2(r.size.x - 4, 1)), Color(1, 1, 1, 0.07))
	PixelFont.draw(_canvas, r.position + Vector2(round((r.size.x - PixelFont.width(_title)) / 2.0), 8), _title, ACCENT, 1, DayClock.EDGE)
	var field := Rect2(r.position + Vector2(20, 20), Vector2(r.size.x - 40, 24))
	_canvas.draw_rect(field, Color("#0d0b16", 0.9))
	_canvas.draw_rect(field, DayClock.EDGE, false, 1.0)
	_canvas.draw_rect(Rect2(field.position + Vector2(1, field.size.y - 2), Vector2(field.size.x - 2, 1)), Color(ACCENT, 0.5))
	var w := PixelFont.width(text, 2)
	var at := field.position + Vector2(round((field.size.x - w) / 2.0), 7)
	PixelFont.draw(_canvas, at, text, TEXT, 2, DayClock.EDGE)
	if fmod(_t, 0.9) < 0.55:                                    # the cursor
		_canvas.draw_rect(Rect2(at + Vector2(w + (2 if text != "" else 0), 0), Vector2(2, 10)), ACCENT)
	PixelFont.draw(_canvas, field.position + Vector2(field.size.x - PixelFont.width("%d/%d" % [text.length(), _max]), 27),
			"%d/%d" % [text.length(), _max], DIM)
	for i in _cells():
		var c := _cell_rect(i)
		var label: String = GRID[i] if i < GRID.length() else SPECIAL[i - GRID.length()]
		var sel := i == _cursor
		_canvas.draw_rect(c, Color(ACCENT, 0.9) if sel else Color("#241f36", 0.95))
		var lw := PixelFont.width(label)
		PixelFont.draw(_canvas, c.position + Vector2(round((c.size.x - lw) / 2.0), 3), label, Color("#120f1d") if sel else TEXT)
	PixelFont.draw(_canvas, r.position + Vector2(8, r.size.y - 9), "TYPE OR PICK  ENTER: OK", DIM)
