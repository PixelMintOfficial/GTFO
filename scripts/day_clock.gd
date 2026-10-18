class_name DayClock
extends CanvasLayer
## The time panel, top left: a little window onto the sky (the sun or the moon crossing it,
## stars coming out at night, the red hills and a tiny dome below), the day number, and the
## part of the day (MORNING, NOON, EVENING, NIGHT) with four pips, the current one filling as
## it passes. The part of the day lights up as it changes, and when a new day dawns its number
## comes up big at the top of the screen. Drawn in pixels with PixelFont, in the game's palette.

const ORIGIN := Vector2(6, 6)
const HEIGHT := 28
const DIAL := Vector2i(30, 21)
const PLATE := Color(0.07, 0.06, 0.11, 0.84)
const EDGE := Color("#22182c")
const LABEL := Color("#a99bb4")
const NUMBER := Color("#fff4d0")
const PIP_OFF := Color("#3b3253")
const STAR := Color("#e8f6ff")
const SUN := [Color("#fff7d2"), Color("#ffd468"), Color("#ff9a48")]    # core, disc, low on the horizon
const MOON := Color("#e6ecff")
const DOME := [Color("#dddce8"), Color("#4a4660")]                     # by day, by night
## The sky in the window: hour, colour at the top, colour at the horizon.
const SKY := [
	[0.0, Color("#0e1230"), Color("#1d2a58")],
	[4.6, Color("#10142b"), Color("#26305e")],
	[5.8, Color("#3b3253"), Color("#ec7a5a")],
	[7.4, Color("#5aa8b4"), Color("#ffd27a")],
	[10.0, Color("#4f9fc0"), Color("#b6ece6")],
	[15.5, Color("#5aa8b4"), Color("#e6fff8")],
	[18.0, Color("#574d70"), Color("#ffb24a")],
	[19.5, Color("#272038"), Color("#c04e57")],
	[21.0, Color("#0e1230"), Color("#1d2a58")],
	[24.0, Color("#0e1230"), Color("#1d2a58")],
]
const HILLS_DAY := [Color("#6e2e38"), Color("#a95747")]                # body, sunlit rim
const HILLS_NIGHT := [Color("#1d1127"), Color("#4f2133")]
const STARS := [Vector2i(3, 3), Vector2i(8, 6), Vector2i(13, 2), Vector2i(19, 5), Vector2i(24, 2),
		Vector2i(27, 8), Vector2i(5, 10), Vector2i(16, 9), Vector2i(22, 12)]
## When the sun rises and sets (the moon has the rest of the sky).
const SUNRISE := 5.5
const SUNSET := 19.75

var _panel: Node2D
var _dial: Image
var _dial_tex: ImageTexture
var _flash := 0.0
var _toast := ""
var _toast_t := 99.0
var _t := 0.0


func _ready() -> void:
	layer = 6
	_dial = Image.create(DIAL.x, DIAL.y, false, Image.FORMAT_RGBA8)
	_dial_tex = ImageTexture.create_from_image(_dial)
	_panel = Node2D.new()
	_panel.draw.connect(_draw_panel)
	add_child(_panel)


## Bring up a title at the top of the screen ("DAY 2").
func announce(text: String) -> void:
	_toast = text
	_toast_t = 0.0


## The part of the day lights up as it changes.
func on_phase_changed(_phase: String) -> void:
	_flash = 1.0


func on_new_day(day: int) -> void:
	announce("DAY %d" % day)


## How often the stars are allowed to twinkle, times a second. They are a handful of pixels
## fading in and out; any faster is work nobody can see.
const STAR_HZ := 8.0

var _dial_state := Vector3(-1, -1, -1)


func _process(delta: float) -> void:
	_t += delta
	_flash = maxf(0.0, _flash - delta * 1.6)
	_toast_t += delta
	# The dial is a 30x21 image painted a pixel at a time and uploaded to the GPU, and the panel
	# redrawn with it. None of that is worth doing 60 times a second for a clock: repaint only
	# when something it draws has actually moved on - the minute, the darkness, a twinkling star
	# (which only shows at night), the phase flash or a toast.
	var state := Vector3(roundf(DayNight.hour * 60.0), roundf(DayNight.night * 64.0),
			roundf(_t * STAR_HZ) if DayNight.night > 0.02 else 0.0)
	if state == _dial_state and _flash <= 0.0 and (_toast.is_empty() or _toast_t > 3.0):
		return
	_dial_state = state
	_paint_dial()
	_panel.queue_redraw()


# ---------------------------------------------------------------- the sky window
func _paint_dial() -> void:
	var h := DayNight.hour
	var n := DayNight.night
	var sky := _sky_at(h)
	var horizon := DIAL.y - 5
	var body := _body_at(h)
	for x in DIAL.x:
		var top := horizon + _hill(x)
		for y in DIAL.y:
			var col: Color
			if y < top:
				var lv := floorf(float(y) / float(horizon) * 4.0 + _bayer(x, y) * 0.99) / 4.0
				col = (sky[0] as Color).lerp(sky[1], clampf(lv, 0.0, 1.0))
			elif y == top:
				col = (HILLS_DAY[1] as Color).lerp(HILLS_NIGHT[1], n)
			else:
				col = (HILLS_DAY[0] as Color).lerp(HILLS_NIGHT[0], n)
			_dial.set_pixel(x, y, col)
	for i in STARS.size():                                # stars come out as it gets dark
		var s: Vector2i = STARS[i]
		var a := n * (0.55 + 0.45 * sin(_t * (1.3 + i * 0.37) + i * 1.7))
		if a > 0.3 and s.y < horizon + _hill(s.x):
			_dial.set_pixel(s.x, s.y, _dial.get_pixelv(s).lerp(STAR, a))
	_paint_body(body, horizon)
	for p in [Vector2i(21, -3), Vector2i(22, -3), Vector2i(23, -3), Vector2i(20, -2), Vector2i(21, -2), Vector2i(22, -2),
			Vector2i(23, -2), Vector2i(24, -2), Vector2i(20, -1), Vector2i(21, -1), Vector2i(22, -1), Vector2i(23, -1),
			Vector2i(24, -1)]:                              # a little dome on the hills: home
		var q := Vector2i(p.x, horizon + _hill(22) + p.y)
		_dial.set_pixelv(q, (DOME[0] as Color).lerp(DOME[1], n * 0.8) * (0.86 if p.x >= 23 else 1.0))
	_dial_tex.update(_dial)


## The sun by day, the moon by night: [is the sun, x, y] in the window.
func _body_at(h: float) -> Array:
	var sun := h >= SUNRISE and h < SUNSET
	var p := 0.0
	if sun:
		p = (h - SUNRISE) / (SUNSET - SUNRISE)
	else:
		var hn := h if h >= SUNSET else h + 24.0
		p = (hn - SUNSET) / (24.0 - SUNSET + SUNRISE)
	var horizon := DIAL.y - 5
	var x := 3.0 + p * (DIAL.x - 7)
	var y := horizon + 1.0 - sin(p * PI) * (horizon - 3.0)
	return [sun, int(round(x)), int(round(y))]


func _paint_body(body: Array, horizon: int) -> void:
	var cx: int = body[1]
	var cy: int = body[2]
	var sun: bool = body[0]
	var low := clampf(float(cy - 4) / float(horizon - 4), 0.0, 1.0)  # redder near the horizon
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			var x := cx + dx
			var y := cy + dy
			if x < 0 or y < 0 or x >= DIAL.x or y >= horizon + _hill(x):
				continue
			var d2 := dx * dx + dy * dy
			var c := _dial.get_pixel(x, y)
			if sun:
				if d2 <= 1:
					c = SUN[0]
				elif d2 <= 5:
					c = (SUN[1] as Color).lerp(SUN[2], low * low)
				elif d2 <= 10:
					c = c.lerp(Color("#ffe9a8"), 0.4)
			else:
				var shade := (dx + 1.5) * (dx + 1.5) + dy * dy <= 4.0      # the crescent's dark side
				if d2 <= 5:
					c = c.lerp(MOON, 0.18) if shade else MOON
				elif d2 <= 8:
					c = c.lerp(MOON, 0.15)
			_dial.set_pixel(x, y, c)


func _sky_at(h: float) -> Array:
	for i in SKY.size() - 1:
		var a: Array = SKY[i]
		var b: Array = SKY[i + 1]
		if h <= b[0]:
			var t := smoothstep(a[0], b[0], h)
			return [(a[1] as Color).lerp(b[1], t), (a[2] as Color).lerp(b[2], t)]
	return [SKY[-1][1], SKY[-1][2]]


static func _hill(x: int) -> int:
	return int(round(1.1 * sin(x * 0.42) + 0.8 * sin(x * 0.19 + 1.0)))


static func _bayer(x: int, y: int) -> float:
	const M := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
	return (M[(y % 4) * 4 + x % 4] + 0.5) / 16.0


# ---------------------------------------------------------------- the panel
func _draw_panel() -> void:
	var tx := ORIGIN.x + 3 + DIAL.x + 5
	var num := str(DayNight.day)
	var text_w := maxi(PixelFont.width("MORNING"), PixelFont.width("DAY") + 3 + PixelFont.width(num, 2))
	var r := Rect2(ORIGIN, Vector2(tx - ORIGIN.x + text_w + 5, HEIGHT))
	_plate(r)
	var d := Rect2(ORIGIN + Vector2(3, 3), Vector2(DIAL))
	_panel.draw_rect(d.grow(1), EDGE)
	_panel.draw_texture(_dial_tex, d.position)
	for c in [d.position, Vector2(d.end.x - 1, d.position.y), Vector2(d.position.x, d.end.y - 1), d.end - Vector2.ONE]:
		_panel.draw_rect(Rect2(c, Vector2.ONE), EDGE)      # rounded corners
	_panel.draw_rect(Rect2(d.position + Vector2(1, 0), Vector2(DIAL.x - 2, 1)), Color(1, 1, 1, 0.12))   # the glass
	var pc := DayNight.phase_color()
	PixelFont.draw(_panel, Vector2(tx, ORIGIN.y + 6), "DAY", LABEL, 1, EDGE)
	PixelFont.draw(_panel, Vector2(tx + PixelFont.width("DAY") + 3, ORIGIN.y + 3), num, NUMBER, 2, EDGE)
	PixelFont.draw(_panel, Vector2(tx, ORIGIN.y + 15), DayNight.phase, pc.lerp(Color.WHITE, _flash * 0.8), 1, EDGE)
	var idx := DayNight.phase_index()
	for i in DayNight.PHASES.size():
		var pr := Rect2(tx + i * 7, ORIGIN.y + 22, 5, 2)
		_panel.draw_rect(pr, PIP_OFF)
		if i < idx:
			_panel.draw_rect(pr, Color(DayNight.PHASES[i][2], 0.35))
		elif i == idx:
			var w := maxf(1.0, roundf(5.0 * DayNight.phase_progress()))
			_panel.draw_rect(Rect2(pr.position, Vector2(w, 2)), pc)
	if _flash > 0.0:                                      # a ring of light round the window as it turns
		_panel.draw_rect(d.grow(2), Color(pc, 0.5 * _flash), false, 1.0)
	_draw_toast()


## A dark plate with pixel-rounded corners and a faint highlight along its top.
func _plate(r: Rect2) -> void:
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	_panel.draw_rect(Rect2(x + 1, y + 1, w - 2, h - 2), PLATE)
	_panel.draw_rect(Rect2(x + 2, y, w - 4, 1), EDGE)
	_panel.draw_rect(Rect2(x + 2, y + h - 1, w - 4, 1), EDGE)
	_panel.draw_rect(Rect2(x, y + 2, 1, h - 4), EDGE)
	_panel.draw_rect(Rect2(x + w - 1, y + 2, 1, h - 4), EDGE)
	for c in [Vector2(x + 1, y + 1), Vector2(x + w - 2, y + 1), Vector2(x + 1, y + h - 2), Vector2(x + w - 2, y + h - 2)]:
		_panel.draw_rect(Rect2(c, Vector2.ONE), EDGE)
	_panel.draw_rect(Rect2(x + 2, y + 1, w - 4, 1), Color(1, 1, 1, 0.07))


## The new day's number, big, fading in at the top of the screen (like the room names indoors).
func _draw_toast() -> void:
	if _toast == "" or _toast_t > 3.0:
		return
	var a := clampf(_toast_t / 0.5, 0.0, 1.0) * clampf((3.0 - _toast_t) / 0.7, 0.0, 1.0)
	var view := get_viewport().get_visible_rect().size
	var w := PixelFont.width(_toast, 2)
	var pos := Vector2(round((view.x - w) / 2.0), 30.0)
	pos = SurvivalHUD.toast_position(_panel, pos, w)
	_panel.draw_rect(Rect2(pos - Vector2(8, 5), Vector2(w + 16, 20)), Color(0.07, 0.06, 0.11, 0.7 * a))
	_panel.draw_rect(Rect2(pos + Vector2(-8, 16), Vector2(w + 16, 1)), Color(DayNight.phase_color(), a))
	PixelFont.draw(_panel, pos, _toast, Color(0.96, 0.95, 1.0, a), 2, Color(0.1, 0.08, 0.16, a))
