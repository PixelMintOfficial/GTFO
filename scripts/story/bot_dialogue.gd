class_name BotDialogue
extends CanvasLayer
## The bot's words: a plate above the hotbar, in the time panel's style (§7.5) - a dark
## translucent plate with a 1 px edge, the speaker's name on a tab in screen cyan, PixelFont text
## typing out with a little synthesised chirp, and a blinking key when the line is complete.
## It pauses the world while it is open, like the backpack, and takes every key, button and click
## so nothing underneath (the map, the camera) acts on them.
##
## F / Enter / Space (gamepad A or X) shows the whole line, then the next one; the last closes it.
## Esc (gamepad B) closes a conversation you started; in the opening it only finishes the line.
## Test hook: auto_advance >= 0 moves on that many seconds after each line is complete.

const RECT := Rect2(40, 126, 304, 46)
const TEXT := Color("#f2f0f8")
const ACCENT := Color("#7fe6cf")
const CPS := 45.0                       # letters a second
const LINE_H := 8

var opened := false
var auto_advance := -1.0

var _canvas: Node2D
var _speaker := ""
var _lines: Array = []
var _index := 0
var _shown := 0.0
var _closable := false
var _then := Callable()
var _paused_here := false
var _wait := 0.0
var _t := 0.0


func _ready() -> void:
	layer = 13
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_actions()
	_canvas = Node2D.new()
	_canvas.draw.connect(_draw_plate)
	add_child(_canvas)


func open(speaker: String, lines: Array, closable: bool, then: Callable) -> void:
	_speaker = speaker
	_lines = lines
	_index = 0
	_shown = 0.0
	_wait = 0.0
	_closable = closable
	_then = then
	opened = true
	_paused_here = not get_tree().paused
	get_tree().paused = true
	Audio.play("bot_chirp")


func _close() -> void:
	opened = false
	if _paused_here:
		get_tree().paused = false
	_paused_here = false
	var then := _then
	_then = Callable()
	if then.is_valid():
		then.call()


func _advance() -> void:
	if _shown < _current().length():
		_shown = _current().length()
		return
	_index += 1
	_shown = 0.0
	_wait = 0.0
	if _index >= _lines.size():
		_close()
	else:
		Audio.play("bot_chirp")


func _current() -> String:
	return _lines[_index] if _index < _lines.size() else ""


func _input(event: InputEvent) -> void:
	if not opened:
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion or event is InputEventMouseButton):
		return
	get_viewport().set_input_as_handled()
	if event.is_echo():
		return
	if event.is_action_pressed("dialogue_next") or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		_advance()
	elif event.is_action_pressed("dialogue_close"):
		if _closable:
			_close()
		else:
			_shown = _current().length()


func _process(delta: float) -> void:
	var view := _canvas.get_viewport_rect().size
	var factor := minf(view.x / 384.0, view.y / 216.0)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = ((view - Vector2(384, 216) * factor) * 0.5).floor()
	_t += delta
	if opened:
		var before := int(_shown)
		_shown = minf(_shown + CPS * delta, _current().length())
		if int(_shown) / 5 != before / 5 and int(_shown) < _current().length():
			Audio.play("bot_chirp")                          # a chirp every few letters, as it types
		if auto_advance >= 0.0 and _shown >= _current().length():
			_wait += delta
			if _wait >= auto_advance:
				_advance()
	_canvas.queue_redraw()


# ---------------------------------------------------------------- drawing
func _draw_plate() -> void:
	if not opened:
		return
	var r := RECT
	_plate(r)
	var tab := Rect2(r.position + Vector2(6, -6), Vector2(PixelFont.width(_speaker) + 8, 9))
	_canvas.draw_rect(tab, DayClock.EDGE)
	_canvas.draw_rect(tab.grow(-1), Color("#1b2a33"))
	PixelFont.draw(_canvas, tab.position + Vector2(4, 2), _speaker, ACCENT)
	var rows: Array = wrap_text(_current(), int(r.size.x) - 16)
	var left := int(_shown)
	for i in rows.size():
		var row: String = rows[i]
		PixelFont.draw(_canvas, r.position + Vector2(8, 9 + i * LINE_H), row.substr(0, maxi(left, 0)), TEXT, 1, DayClock.EDGE)
		left -= row.length() + 1
	if _shown >= _current().length() and fmod(_t, 0.8) < 0.5:     # the line is done: press to go on
		var key := Rect2(r.end - Vector2(14, 13), Vector2(8, 9))
		_canvas.draw_rect(key, Color("#f2f0f8"))
		_canvas.draw_rect(Rect2(key.position + Vector2(0, 8), Vector2(8, 1)), Color("#8f8ba8"))
		PixelFont.draw(_canvas, key.position + Vector2(3, 2), "F", Color("#241f36"))


## The plate, as the time panel draws its own.
func _plate(r: Rect2) -> void:
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	_canvas.draw_rect(Rect2(x + 1, y + 1, w - 2, h - 2), DayClock.PLATE)
	_canvas.draw_rect(Rect2(x + 2, y, w - 4, 1), DayClock.EDGE)
	_canvas.draw_rect(Rect2(x + 2, y + h - 1, w - 4, 1), DayClock.EDGE)
	_canvas.draw_rect(Rect2(x, y + 2, 1, h - 4), DayClock.EDGE)
	_canvas.draw_rect(Rect2(x + w - 1, y + 2, 1, h - 4), DayClock.EDGE)
	for c in [Vector2(x + 1, y + 1), Vector2(x + w - 2, y + 1), Vector2(x + 1, y + h - 2), Vector2(x + w - 2, y + h - 2)]:
		_canvas.draw_rect(Rect2(c, Vector2.ONE), DayClock.EDGE)
	_canvas.draw_rect(Rect2(x + 2, y + 1, w - 4, 1), Color(1, 1, 1, 0.07))
	_canvas.draw_rect(Rect2(x + 2, y + h - 2, w - 4, 1), Color(ACCENT, 0.5))


## A line broken into rows no wider than `width` pixels, at word boundaries.
static func wrap_text(text: String, width: int) -> Array:
	var rows := []
	var row := ""
	for word in text.split(" ", false):
		var next := word if row == "" else row + " " + word
		if row != "" and PixelFont.width(next) > width:
			rows.append(row)
			row = word
		else:
			row = next
	if row != "":
		rows.append(row)
	return rows


static func _ensure_actions() -> void:
	var setup := {"dialogue_next": [[KEY_F, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE], [JOY_BUTTON_A, JOY_BUTTON_X]],
			"dialogue_close": [[KEY_ESCAPE], [JOY_BUTTON_B]]}
	for action in setup:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for k in setup[action][0]:
			var key := InputEventKey.new()
			key.physical_keycode = k
			InputMap.action_add_event(action, key)
		for b in setup[action][1]:
			var pad := InputEventJoypadButton.new()
			pad.button_index = b
			InputMap.action_add_event(action, pad)
