class_name ReplyCutscene
extends CanvasLayer
## Earth's answer to the SOS, played once in the comms room (comms.gd starts it).
##
##   ALERT     Letterbox bars slide in and a blinking amber mark beeps over the console.
##             The astronaut walks to the console stand and faces the screen.
##   OPEN      The screen's picture grows out of the console into a large terminal: the
##             in-world screen's own bezel, dark glass, pale lettering and cyan dots.
##   DECODE    INCOMING / DECODING TRANSMISSION, a filling bar and static.
##   MESSAGE   Mission Control's message types out, ending in the arrival time in large type.
##   SHUT      The terminal folds back into the console.
##   SPEAK     The astronaut turns to the camera; their line appears in the dialogue plate.
##
## F / Enter / Space (gamepad A or X) finishes a line or moves on; Esc (gamepad B) skips to
## the end. The world keeps running, like the door and opening cutscenes; the astronaut is a
## puppet. Every line is in data/bot_story.json ("reply"). Sounds reuse the intro's radio and
## the UI panel sounds. CommsMission.reply_shown keeps it from ever playing twice.
## Test hook: auto_advance >= 0 moves on that many seconds after each line is complete.

signal finished

const VOID := Color("#0b0915")
const TEXT := Color("#f2f0f8")
const ACCENT := Color("#7fe6cf")                  # screen cyan
const AMBER := Color("#ffb24a")
const MUSTARD := Color("#efb950")
const CORAL := Color("#ec7a5a")
const DIM := Color("#6a6385")
const OUTLINE := Color("#22182c")
## The in-world screen's own materials (O_RAMPS: WHITE bezel, darkwin glass, screen lettering).
const BEZEL := [Color("#c8bdc0"), Color("#dddce8"), Color("#fbfbff")]
const GLASS := [Color("#121020"), Color("#1f1c34"), Color("#343652"), Color("#5e6888")]
const LETTER := Color("#dcfffa")
const GARBLE := "%/<>?!-:"

const BAR := 18
const TERM := Rect2(70, 34, 244, 96)
const PLATE := Rect2(40, 150, 304, 38)
const CPS := 34.0
const ALERT_TIME := 1.4
const OPEN_TIME := 0.35
const DECODE_TIME := 1.7
const SHUT_TIME := 0.3
const TURN_TIME := 0.45
const END_TIME := 0.6
const ETA_SCALE := 3

enum Step { IDLE, ALERT, OPEN, DECODE, MESSAGE, SHUT, TURN, SPEAK, END }

var playing := false
var auto_advance := -1.0
var step := Step.IDLE

var _player: Player
var _terrain: MapTerrain
var _screen_world := Vector2.ZERO
var _screen_height := 0.0
var _stand := Vector2.ZERO
var _lines: Dictionary
var _canvas: Node2D
var _factor := 1.0
var _t := 0.0                                      # time in this step
var _bars := 0.0                                   # 0..1, letterbox in
var _walked := false
var _shown := 0.0
var _wait := 0.0
var _eta_shown := false
var _releasing := false
var _origin := Vector2.ZERO                         # the console's screen, in design pixels


func setup(player: Player, terrain: MapTerrain, screen_world: Vector2, screen_height: float, stand: Vector2) -> void:
	_player = player
	_terrain = terrain
	_screen_world = screen_world
	_screen_height = screen_height
	_stand = stand
	_lines = GameState.story.data["reply"]
	layer = 13
	BotDialogue._ensure_actions()
	_canvas = Node2D.new()
	_canvas.draw.connect(_draw)
	add_child(_canvas)


func play() -> void:
	if playing:
		return
	GameState.comms_mission.reply_shown = true
	playing = true
	_releasing = false
	_walked = false
	_bars = 0.0
	_player.controls_enabled = false
	_player.puppet = true
	_go(Step.ALERT)
	Audio.play("intro_radio_blip")


func _go(s: Step) -> void:
	step = s
	_t = 0.0
	_shown = 0.0
	_wait = 0.0
	match s:
		Step.OPEN:
			Audio.play("ui_panel_open")
		Step.DECODE:
			Audio.play("intro_radio_glitch")
			Audio.loop("intro_radio_static", "reply:static")
		Step.MESSAGE:
			Audio.release("reply:static")
			Audio.play("intro_radio_blip")
			_eta_shown = false
		Step.SHUT:
			Audio.release("reply:static")
			Audio.play("ui_panel_close")
		Step.TURN:
			_player.puppet_face(_terrain.world_dir(Vector2(0, -1)))   # towards the camera
		Step.END:
			Audio.release("reply:static")
			_player.puppet = false
			_player.puppet_face(_terrain.world_dir(Vector2(0, -1)))
			_releasing = true


func _message() -> String:
	return " ".join(_rows(9999))


## The message as terminal rows: each of its lines starts a new row and wraps within `width`.
func _rows(width: int) -> PackedStringArray:
	var rows := PackedStringArray()
	for line in _lines["message"]:
		for row in BotDialogue.wrap_text(str(line), width):
			rows.append(row)
	return rows


func _speech() -> String:
	return GameState.story.text(str(_lines["astronaut"]))


func _speaker() -> String:
	var name: String = GameState.story.player_name
	return name if name != "" else str(_lines["unnamed"])


func _advance() -> void:
	match step:
		Step.MESSAGE:
			if _shown < _message().length() or not _eta_shown:
				_shown = _message().length()
				_show_eta()
			else:
				_go(Step.SHUT)
		Step.SPEAK:
			if _shown < _speech().length():
				_shown = _speech().length()
			else:
				_go(Step.END)


func _show_eta() -> void:
	if not _eta_shown:
		_eta_shown = true
		Audio.play("intro_radio_blip")


func _skip() -> void:
	if step == Step.END:
		return
	_go(Step.END)


func _input(event: InputEvent) -> void:
	if not playing or step == Step.END:
		return
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton):
		return
	get_viewport().set_input_as_handled()
	if event.is_echo():
		return
	if event.is_action_pressed("dialogue_next") or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		_advance()
	elif event.is_action_pressed("dialogue_close"):
		_skip()


func _process(delta: float) -> void:
	var view := _canvas.get_viewport_rect().size
	_factor = minf(view.x / 384.0, view.y / 216.0)
	_canvas.scale = Vector2.ONE * _factor
	_canvas.position = ((view - Vector2(384, 216) * _factor) * 0.5).floor()
	if _releasing and not playing:
		# the key that ended it (F, Space...) must not also use the tool or jump
		if not (Input.is_action_pressed("interact") or Input.is_action_pressed("tool_use") or Input.is_action_pressed("jump")
				or Input.is_action_pressed("dialogue_next")):
			_releasing = false
			_player.controls_enabled = true
	if not playing:
		return
	_t += delta
	_bars = clampf(_bars + delta / 0.5, 0.0, 1.0) if step != Step.END else clampf(1.0 - _t / END_TIME, 0.0, 1.0)
	_origin = _console_px()
	match step:
		Step.ALERT:
			if not _walked:
				_walked = _player.puppet_walk(_stand, 0.9, delta)
				if _walked:
					_player.puppet_face(_screen_world - _stand)
			if int((_t - delta) / 0.6) != int(_t / 0.6) and _t < ALERT_TIME:
				Audio.play("intro_radio_blip")
			if _walked and _t >= ALERT_TIME:
				_go(Step.OPEN)
		Step.OPEN:
			if _t >= OPEN_TIME:
				_go(Step.DECODE)
		Step.DECODE:
			if _t >= DECODE_TIME:
				_go(Step.MESSAGE)
		Step.MESSAGE:
			var before := int(_shown)
			_shown = minf(_shown + CPS * delta, _message().length())
			if int(_shown) / 6 != before / 6 and int(_shown) < _message().length():
				Audio.play("ui_slot")                       # the terminal ticks as it prints
			if _shown >= _message().length():
				_wait += delta
				if _wait >= 0.35:
					_show_eta()
				if auto_advance >= 0.0 and _eta_shown and _wait >= 0.35 + auto_advance:
					_go(Step.SHUT)
		Step.SHUT:
			if _t >= SHUT_TIME:
				_go(Step.TURN)
		Step.TURN:
			if _t >= TURN_TIME:
				_go(Step.SPEAK)
		Step.SPEAK:
			_shown = minf(_shown + CPS * delta, _speech().length())
			if auto_advance >= 0.0 and _shown >= _speech().length():
				_wait += delta
				if _wait >= auto_advance:
					_go(Step.END)
		Step.END:
			if _t >= END_TIME:
				playing = false
				step = Step.IDLE
				finished.emit()
	_canvas.queue_redraw()


## Where the console's screen is on the screen, in the 384x216 design pixels this layer draws in.
func _console_px() -> Vector2:
	var map_px := _terrain.to_screen(_screen_world, _terrain.height_at(_screen_world) + _screen_height)
	var on_screen := _player.get_viewport().get_canvas_transform() * map_px
	return ((on_screen - _canvas.position) / _factor).round()


# ---------------------------------------------------------------- drawing
func _draw() -> void:
	if not playing:
		return
	if step == Step.ALERT and fmod(_t, 0.6) < 0.4:
		_draw_alert()
	match step:
		Step.OPEN:
			_draw_terminal(_grow(_t / OPEN_TIME), false)
		Step.DECODE, Step.MESSAGE:
			_draw_terminal(TERM, true)
		Step.SHUT:
			_draw_terminal(_grow(1.0 - _t / SHUT_TIME), false)
		Step.SPEAK:
			_draw_plate()
	var h := roundf(BAR * _bars)
	if h > 0.0:
		_canvas.draw_rect(Rect2(0, 0, 384, h), VOID)
		_canvas.draw_rect(Rect2(0, 216 - h, 384, h), VOID)
		if step != Step.END and _bars >= 1.0:
			var hint := str(_lines["skip"])
			PixelFont.draw(_canvas, Vector2(384 - 8 - PixelFont.width(hint), 216 - 11), hint, DIM)


## The console calling: a blinking amber mark above the screen.
func _draw_alert() -> void:
	var at := _origin - Vector2(4, 32)
	var r := Rect2(at, Vector2(9, 11))
	_canvas.draw_rect(r.grow(1), OUTLINE)
	_canvas.draw_rect(r, AMBER)
	PixelFont.draw(_canvas, at + Vector2(3, 3), "!", OUTLINE)


## The terminal's rectangle part way out of the console: a thin line widens first, then opens
## upward and downward, like a screen being switched on.
func _grow(k: float) -> Rect2:
	k = clampf(k, 0.0, 1.0)
	var e := 1.0 - pow(1.0 - k, 2.0)
	var centre := _origin.lerp(TERM.get_center(), e)
	var w := lerpf(12.0, TERM.size.x, clampf(e * 1.6, 0.0, 1.0))
	var h := lerpf(3.0, TERM.size.y, clampf(e * 1.6 - 0.6, 0.0, 1.0))
	return Rect2((centre - Vector2(w, h) * 0.5).round(), Vector2(w, h).round())


func _draw_terminal(r: Rect2, contents: bool) -> void:
	# the bezel: the console's glossy white casing, outlined, with its coral strip and two LEDs
	_canvas.draw_rect(r.grow(1), OUTLINE)
	_canvas.draw_rect(r, BEZEL[1])
	_canvas.draw_rect(Rect2(r.position, Vector2(r.size.x, 1)), BEZEL[2])
	_canvas.draw_rect(Rect2(r.position + Vector2(0, r.size.y - 2), Vector2(r.size.x, 2)), BEZEL[0])
	if r.size.y < 14.0 or r.size.x < 20.0:
		return
	var glass := r.grow_individual(-5, -5, -5, -9)
	_canvas.draw_rect(glass.grow(1), GLASS[0])
	_canvas.draw_rect(glass, GLASS[1])
	for y in range(int(glass.position.y) + 1, int(glass.end.y), 3):       # scan lines
		_canvas.draw_rect(Rect2(glass.position.x, y, glass.size.x, 1), Color(GLASS[2], 0.45))
	_canvas.draw_rect(Rect2(r.position.x + 6, r.end.y - 6, 18, 2), CORAL)
	for i in 2:
		_canvas.draw_rect(Rect2(r.end.x - 12 + i * 4, r.end.y - 6, 2, 2), ACCENT)
	if not contents:
		return
	var x := glass.position.x + 6
	var y := glass.position.y + 5
	PixelFont.draw(_canvas, Vector2(x, y), str(_lines["header"]), LETTER)
	if step == Step.DECODE or fmod(_t, 0.8) < 0.55:
		var inc := str(_lines["incoming"])
		PixelFont.draw(_canvas, Vector2(glass.end.x - 6 - PixelFont.width(inc), y), inc, AMBER)
	for dx in range(0, int(glass.size.x) - 12, 4):                       # the screen's cyan dots
		_canvas.draw_rect(Rect2(x + dx, y + 9, 2, 1), Color(ACCENT, 0.7))
	y += 15
	if step == Step.DECODE:
		_draw_decode(Vector2(x, y), glass.size.x - 12)
		return
	PixelFont.draw(_canvas, Vector2(x, y), str(_lines["from"]), GLASS[3])
	y += 11
	var left := int(_shown)
	for row in _rows(int(glass.size.x) - 12):
		PixelFont.draw(_canvas, Vector2(x, y), row.substr(0, maxi(left, 0)), LETTER, 1, GLASS[0])
		left -= row.length() + 1
		y += 8
	if _eta_shown:
		var eta := str(_lines["eta"])
		var w := PixelFont.width(eta, ETA_SCALE)
		var at := Vector2(roundf(glass.get_center().x - w / 2.0), y + 8)
		PixelFont.draw(_canvas, at, eta, MUSTARD, ETA_SCALE, GLASS[0])
		if fmod(_t, 0.8) < 0.5:
			_draw_key(Vector2(glass.end.x - 12, glass.end.y - 13))


func _draw_decode(at: Vector2, width: float) -> void:
	var dots := ".".repeat(int(_t * 3.0) % 4)
	PixelFont.draw(_canvas, at, str(_lines["decoding"]) + dots, LETTER)
	var cells := 24
	var cw := floorf((width - (cells - 1)) / cells)
	var filled := int(clampf(_t / DECODE_TIME, 0.0, 1.0) * cells)
	for i in cells:
		var c := Rect2(at.x + i * (cw + 1), at.y + 12, cw, 5)
		_canvas.draw_rect(c, ACCENT if i < filled else GLASS[2])
	var rs := RandomNumberGenerator.new()
	rs.seed = int(_t * 10.0)
	for row in 3:
		var line := ""
		for i in 26:
			line += GARBLE[rs.randi() % GARBLE.length()] if rs.randf() < 0.7 else " "
		PixelFont.draw(_canvas, at + Vector2(0, 25 + row * 8), line, GLASS[3])


## The astronaut's words, on the bot's dialogue plate (§7.5), their name on the tab.
func _draw_plate() -> void:
	var r := PLATE
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	_canvas.draw_rect(Rect2(x + 1, y + 1, w - 2, h - 2), DayClock.PLATE)
	_canvas.draw_rect(Rect2(x + 2, y, w - 4, 1), DayClock.EDGE)
	_canvas.draw_rect(Rect2(x + 2, y + h - 1, w - 4, 1), DayClock.EDGE)
	_canvas.draw_rect(Rect2(x, y + 2, 1, h - 4), DayClock.EDGE)
	_canvas.draw_rect(Rect2(x + w - 1, y + 2, 1, h - 4), DayClock.EDGE)
	_canvas.draw_rect(Rect2(x + 2, y + 1, w - 4, 1), Color(1, 1, 1, 0.07))
	_canvas.draw_rect(Rect2(x + 2, y + h - 2, w - 4, 1), Color(CORAL, 0.6))
	var speaker := _speaker()
	var tab := Rect2(r.position + Vector2(6, -6), Vector2(PixelFont.width(speaker) + 8, 9))
	_canvas.draw_rect(tab, DayClock.EDGE)
	_canvas.draw_rect(tab.grow(-1), Color("#2a1d26"))
	PixelFont.draw(_canvas, tab.position + Vector2(4, 2), speaker, CORAL)
	var rows := BotDialogue.wrap_text(_speech(), int(w) - 16)
	var left := int(_shown)
	for i in rows.size():
		var row: String = rows[i]
		PixelFont.draw(_canvas, r.position + Vector2(8, 9 + i * 8), row.substr(0, maxi(left, 0)), TEXT, 1, DayClock.EDGE)
		left -= row.length() + 1
	if _shown >= _speech().length() and fmod(_t, 0.8) < 0.5:
		_draw_key(r.end - Vector2(14, 13))


func _draw_key(at: Vector2) -> void:
	var key := Rect2(at, Vector2(8, 9))
	_canvas.draw_rect(key, TEXT)
	_canvas.draw_rect(Rect2(key.position + Vector2(0, 8), Vector2(8, 1)), Color("#8f8ba8"))
	PixelFont.draw(_canvas, key.position + Vector2(3, 2), "F", Color("#241f36"))
