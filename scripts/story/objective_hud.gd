class_name ObjectiveHUD
extends CanvasLayer
## What the bot asked of you, just under the time panel (top left), in both scenes: one row per
## objective with a small box that ticks when it is done (the done ones dim and struck through),
## in the time panel's plate. It appears once the bot hands the objectives out (StoryState) and
## lights up when one is done. Hidden in cutscenes, while the world is paused and once everything
## is done and the moment has passed. Owner-approved exception to the compact HUD (§9, §12).

const ORIGIN := Vector2(6, 37)
const ROW := 9
const TEXT := Color("#f2f0f8")
const DONE := Color("#7fe6cf")
const DIM := Color("#8f8ba8")
## How long the line stays up once everything is done, seconds.
const LINGER := 6.0

var _player: Player
var _panel: Node2D
var _was := {}
var _flash := 0.0
var _all_done_t := -1.0


func setup(player: Player) -> void:
	_player = player
	layer = 6
	_panel = Node2D.new()
	_panel.draw.connect(_draw_panel)
	add_child(_panel)
	for o in GameState.story.objectives():
		_was[o["id"]] = o["done"]
	if GameState.story.objectives_given and GameState.story.all_done():
		_all_done_t = LINGER


func _process(delta: float) -> void:
	_flash = maxf(0.0, _flash - delta * 1.4)
	var objectives := GameState.story.objectives()
	for o in objectives:
		if o["done"] and not _was.get(o["id"], false):
			_flash = 1.0
		_was[o["id"]] = o["done"]
	if not objectives.is_empty() and GameState.story.all_done():
		_all_done_t = maxf(_all_done_t, 0.0) + delta
	_panel.visible = not objectives.is_empty() and _all_done_t < LINGER and _player.controls_enabled \
			and not _player.puppet and not get_tree().paused
	_panel.queue_redraw()


func _draw_panel() -> void:
	var objectives := GameState.story.objectives()
	if objectives.is_empty():
		return
	var w := 0
	for o in objectives:
		w = maxi(w, PixelFont.width(o["label"]))
	var r := Rect2(ORIGIN, Vector2(w + 18, objectives.size() * ROW + 5))
	r.position = SurvivalHUD.plate_position(_panel, r)      # out of the way of the movable survival panel
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
