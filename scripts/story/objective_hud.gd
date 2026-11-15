class_name ObjectiveHUD
extends CanvasLayer
## Base, nursery and SOS tasks under the time panel (top left): one row per
## objective with a small box that ticks when it is done (the done ones dim and struck through),
## in the time panel's plate. Base tasks follow UNIT's introduction; nursery tasks show on entry and
## lights up when one is done. Hidden in cutscenes, while the world is paused and once everything
## is done and the moment has passed. Owner-approved exception to the compact HUD (§9, §12).
## Resetting a task through F1 brings its objective back after the completion linger.
## GUI changes update layout immediately, including while the options menu pauses the world.

const ORIGIN := Vector2(6, 75)
const ROW := 9
const TEXT := Color("#f2f0f8")
const DONE := Color("#7fe6cf")
const DIM := Color("#8f8ba8")
## How long the line stays up once everything is done, seconds.
const LINGER := 6.0

var _player: Player
var _context := "base"
var _panel: Node2D
var _was := {}
var _flash := 0.0
var _all_done_t := -1.0
var _drawn: Variant = null      # what the panel showed last time it was drawn


func setup(player: Player, context := "base") -> void:
	_player = player
	_context = context
	layer = 6
	_panel = Node2D.new()
	_panel.draw.connect(_draw_panel)
	add_child(_panel)
	GameState.settings.changed.connect(_layout)
	_layout()
	var objectives := _objectives()
	for o in objectives:
		_was[o["id"]] = o["done"]
	if not objectives.is_empty() and objectives.all(func(o: Dictionary) -> bool: return o["done"]):
		_all_done_t = LINGER


func _objectives() -> Array:
	var objectives := [] if _context == "comms" else GameState.story.objectives(_context)
	objectives.append_array(GameState.story.comms_objectives(_context))
	return objectives


func _layout() -> void:
	_panel.scale = Vector2.ONE * SurvivalHUD.compact_scale(_panel)
	_panel.queue_redraw()


func _process(delta: float) -> void:
	var next_scale := Vector2.ONE * SurvivalHUD.compact_scale(_panel)
	if _panel.scale != next_scale:
		_layout()
	_flash = maxf(0.0, _flash - delta * 1.4)
	var objectives := _objectives()
	for o in objectives:
		if o["done"] and not _was.get(o["id"], false):
			_flash = 1.0
		_was[o["id"]] = o["done"]
	if not objectives.is_empty() and objectives.all(func(o: Dictionary) -> bool: return o["done"]):
		_all_done_t = maxf(_all_done_t, 0.0) + delta
	else:
		_all_done_t = -1.0
	_panel.visible = not objectives.is_empty() and _all_done_t < LINGER and _player.controls_enabled \
			and not _player.puppet and not get_tree().paused
	# Redraw only when something it shows has changed (as DayClock does): the ticks, the flash
	# fading in steps, or the plate moving aside for the survival panel.
	var state := [objectives, ceili(_flash * 8.0),
			_plate_rect(objectives).position if not objectives.is_empty() else Vector2.ZERO]
	if state != _drawn:
		_drawn = state
		_panel.queue_redraw()


## The compact plate sits under the fixed stats/time/supply panels.
func _plate_rect(objectives: Array) -> Rect2:
	var w := 0
	for o in objectives:
		w = maxi(w, PixelFont.width(o["label"]))
	var r := Rect2(ORIGIN, Vector2(w + 18, objectives.size() * ROW + 5))
	r.position = SurvivalHUD.plate_position(_panel, r)
	return r


func _draw_panel() -> void:
	var objectives := _objectives()
	if objectives.is_empty():
		return
	var r := _plate_rect(objectives)
	var at := r.position
	_plate(r)
	for i in objectives.size():
		var o: Dictionary = objectives[i]
		var y := at.y + 4 + i * ROW
		var box := Rect2(at.x + 5, y, 5, 5)
		_panel.draw_rect(box, DONE if o["done"] else DIM)
		_panel.draw_rect(box.grow(-1), Color("#241f36"))
		if o["done"]:                                       # a tick
			for p in [Vector2(1, 2), Vector2(2, 3), Vector2(3, 2), Vector2(4, 1), Vector2(5, 0)]:
				_panel.draw_rect(Rect2(box.position + p, Vector2.ONE), DONE)
		var col := DIM if o["done"] else TEXT
		PixelFont.draw(_panel, Vector2(at.x + 13, y), o["label"], col, 1, DayClock.EDGE)
		if o["done"]:
			_panel.draw_rect(Rect2(at.x + 12, y + 2, PixelFont.width(o["label"]) + 2, 1), Color(DIM, 0.8))
	if _flash > 0.0:
		_panel.draw_rect(r.grow(1), Color(DONE, 0.6 * _flash), false, 1.0)


func _plate(r: Rect2) -> void:
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	_panel.draw_rect(Rect2(x + 1, y + 1, w - 2, h - 2), DayClock.PLATE)
	_panel.draw_rect(Rect2(x + 2, y, w - 4, 1), DayClock.EDGE)
	_panel.draw_rect(Rect2(x + 2, y + h - 1, w - 4, 1), DayClock.EDGE)
	_panel.draw_rect(Rect2(x, y + 2, 1, h - 4), DayClock.EDGE)
	_panel.draw_rect(Rect2(x + w - 1, y + 2, 1, h - 4), DayClock.EDGE)
	for c in [Vector2(x + 1, y + 1), Vector2(x + w - 2, y + 1), Vector2(x + 1, y + h - 2), Vector2(x + w - 2, y + h - 2)]:
		_panel.draw_rect(Rect2(c, Vector2.ONE), DayClock.EDGE)
	_panel.draw_rect(Rect2(x + 2, y + 1, w - 4, 1), Color(1, 1, 1, 0.07))
