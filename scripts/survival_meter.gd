class_name SurvivalMeter
extends Control
## One pixel-rasterized twelve-segment dial. Reads the existing survival model directly;
## percentage normalization and debug preview affect presentation only. No gameplay timers.

const SEGMENTS := 12
const SIZE := Vector2(30, 30)
const CENTER := Vector2(15, 15)
const COLORS := [Color("#ff4869"), Color("#26d9ed"), Color("#ffb24a"), Color("#25b9ff")]
const ICONS := [
	[".22...22.", "2332.2221", "233322221", ".2322221.", "..22221..", "...221...", "....1...."],
	["....2....", "..2.2.2..", ".32.2.23.", "332222223", "3321.1223", "3221.1222", ".21...12."],
	["....222..", "...23321.", "...33221.", "...22211.", "....211..", "...32....", "..32.....", ".33......"],
	["....2....", "...232...", "..23321..", "..33221..", ".2332221.", ".2322221.", "..22211..", "...111..."],
]

var kind := "health"
var index := 0
## Explicit UI-only preview; negative means display live gameplay state.
var preview := -1
var pulse := 0.0
var _ring_pixels: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = SIZE
	# A finer, nearest-filtered pixel grid keeps the thin ring's arcs deliberate rather
	# than stair-stepping in oversized blocks; it remains hard-edged pixel art.
	for y in int(SIZE.y * 2):
		for x in int(SIZE.x * 2):
			var point := Vector2(x * 0.5 + 0.25, y * 0.5 + 0.25) - CENTER
			var radius := point.length()
			if radius < 12.0 or radius > 14.5:
				continue
			var angle := fposmod(point.angle() + PI / 2.0, TAU)
			var part := angle / TAU * SEGMENTS
			# Small radial cuts leave every segment distinguishable, including at 100%.
			if fposmod(part, 1.0) < 0.07 or fposmod(part, 1.0) > 0.93:
				continue
			_ring_pixels.append([Vector2(x, y) * 0.5, floori(part), 0 if radius > 14.0 else 2 if radius < 12.5 else 1])


static func percentage(current: float, maximum: float) -> int:
	if maximum <= 0.0 or not is_finite(current) or not is_finite(maximum):
		return 0
	return clampi(roundi(current / maximum * 100.0), 0, 100)


func displayed_value() -> int:
	if preview >= 0:
		return clampi(preview, 0, 100)
	return percentage(float(GameState.survival.values[kind]), GameState.survival.maximum(kind))


func active_segments() -> int:
	return roundi(displayed_value() * SEGMENTS / 100.0)


func refresh() -> void:
	queue_redraw()


func _draw() -> void:
	var color: Color = COLORS[index]
	var active := active_segments()
	# Circular recessed face and its shadow, with whole-pixel edges, no AA or blur.
	for y in int(SIZE.y):
		var dy := y + 0.5 - CENTER.y
		if absf(dy) < 15.0:
			var half := floorf(sqrt(15.0 * 15.0 - dy * dy))
			draw_rect(Rect2(Vector2(CENTER.x - half, y + 1), Vector2(half * 2, 1)), Color("#060610"))
	for y in range(3, 27):
		var dy := y + 0.5 - CENTER.y
		var half := floorf(sqrt(maxf(0.0, 12.0 * 12.0 - dy * dy)))
		draw_rect(Rect2(Vector2(CENTER.x - half, y), Vector2(half * 2, 1)), InventoryUI.VOID)
	var lit := [color.lightened(0.12), color, color.darkened(0.2)]
	var unlit := [Color("#403c52"), Color("#302d40"), Color("#252233")]
	for pixel in _ring_pixels:
		draw_rect(Rect2(pixel[0], Vector2(0.5, 0.5)), lit[pixel[2]] if pixel[1] < active else unlit[pixel[2]])
	var pattern: Array = ICONS[index]
	var tones := [color.darkened(0.3), color, color.lightened(0.35)]
	for y in pattern.size():
		for x in pattern[y].length():
			var tone := int(pattern[y][x])
			if tone > 0:
				draw_rect(Rect2(Vector2(11 + x, 5 + y), Vector2.ONE), tones[tone - 1])
	var number := str(displayed_value())
	PixelFont.draw(self, Vector2(CENTER.x - PixelFont.width(number) / 2.0, 15).floor(), number, InventoryUI.WHITE)
	# Existing PixelFont on the finer UI pixel grid: smaller, correctly shaped /100.
	draw_set_transform(Vector2(floorf(CENTER.x - PixelFont.width("/100") * 0.25), 22), 0, Vector2(0.5, 0.5))
	PixelFont.draw(self, Vector2.ZERO, "/100", Color("#79758e"))
	draw_set_transform(Vector2.ZERO)
	var ratio := displayed_value() / 100.0
	if ratio <= float(GameState.survival.config["warning_fraction"]):
		# Quiet warning below the dial; ring and number always represent the same value.
		draw_rect(Rect2(13, 28, 4, 1), Color(color, 0.5 + 0.3 * sin(pulse * 4)))
