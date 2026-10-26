class_name DevPanel
extends CanvasLayer
## The master control panel, for working on the game: F1 (gamepad Guide) opens it in editor and
## debug builds only - never in a shipped game. Set the time to any hour (half-hour steps, or a
## part of the day at once), freeze food/water/oxygen, and toggle task completion remotely.
##
## The clock keeps running while it is open, so the light can be watched changing; the
## astronaut stands still. Up / down picks a row; left / right steps the time or picks a preset;
## Enter / Space / A sets or toggles; Esc / B / F1 closes. Everything is clickable too.
## The time is GameState.clock (DayNight lights it); frozen needs are GameState.survival.frozen,
## so both carry on through the airlock and rescue. Task toggles use the actual machine,
## window and solar session states: DONE bypasses costs, RESET clears that task for replay.
##
## Test hooks (after "--", debug builds): --dev-panel opens it after a second (for captures);
## --dev-freeze=hunger,thirst,oxygen freezes those from the start.

const PLATE := DayClock.PLATE
const EDGE := DayClock.EDGE
const SIZE := Vector2(190, 154)
const STEP := 0.5                                      # hours per time step
const PRESETS := [["DAWN", 5.5], ["MORNING", 8.0], ["NOON", 12.0], ["EVENING", 17.0], ["NIGHT", 22.0]]
const NEEDS := [["FOOD", "hunger", 2], ["WATER", "thirst", 3], ["OXYGEN", "oxygen", 1]]   # label, kind, colour
const TASKS := [["OXYGEN REPAIR", "oxygen"], ["POWER REPAIR", "power"],
		["GLASS CRACKS", "glass"], ["SOLAR REFLECTIONS", "solar"]]
const TASK_ROW := 5                                    # time, presets and three needs
const BASE_META := "res://assets/maps/base_interior/base_interior.json"

var opened := false
var _player: Player
var _canvas: Control
var _row := 0
var _preset := 0
var _controls_were := true
var _hits: Array = []                                  # [Rect2, row, action] drawn this frame


func setup(player: Player) -> void:
	_player = player
	layer = 15
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_actions()
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_panel)
	add_child(_canvas)
	visible = false
	if not OS.is_debug_build():
		set_process_input(false)
		return
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--dev-freeze="):
			for kind in arg.get_slice("=", 1).split(","):
				GameState.survival.frozen[kind] = true
	if args.has("--dev-panel"):
		get_tree().create_timer(1.0).timeout.connect(open)


func open() -> void:
	if opened or not OS.is_debug_build() or get_tree().paused or GameState.survival.dead:
		return
	if not _player.controls_enabled or _player.puppet or _player.turning:
		return
	opened = true
	visible = true
	_controls_were = _player.controls_enabled
	_player.controls_enabled = false
	Audio.play("ui_panel_open")


func close() -> void:
	if not opened:
		return
	opened = false
	visible = false
	_player.controls_enabled = _controls_were
	Audio.play("ui_panel_close")


## Set the clock to an hour of the same day (a new day begins at dawn, as DayNight counts it).
static func set_hour(h: float) -> void:
	var day := floori((GameState.clock - DayNight.DAWN) / 24.0)
	h = fposmod(h, 24.0)
	GameState.clock = day * 24.0 + (h + 24.0 if h < DayNight.DAWN else h)


func _process(_delta: float) -> void:
	if opened:
		_canvas.queue_redraw()


func _input(event: InputEvent) -> void:
	if event.is_echo() and not (event.is_action("ui_left") or event.is_action("ui_right")):
		return
	if not opened:
		if event.is_action_pressed("dev_panel"):
			open()
			if opened:
				get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("dev_panel") or event.is_action_pressed("ui_cancel") \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_B):
		close()
	elif event.is_action_pressed("ui_up"):
		_row = posmod(_row - 1, TASK_ROW + TASKS.size())
		Audio.play("ui_slot")
	elif event.is_action_pressed("ui_down"):
		_row = posmod(_row + 1, TASK_ROW + TASKS.size())
		Audio.play("ui_slot")
	elif event.is_action_pressed("ui_left"):
		_step(-1)
	elif event.is_action_pressed("ui_right"):
		_step(1)
	elif event.is_action_pressed("ui_accept") \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_A):
		_act(_row, -1)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var p: Vector2 = _canvas.get_global_transform_with_canvas().affine_inverse() * event.position
		for h in _hits:
			if (h[0] as Rect2).has_point(p):
				_row = h[1]
				_act(h[1], h[2])
				break
	elif not (event is InputEventKey or event is InputEventJoypadButton):
		return
	get_viewport().set_input_as_handled()                 # nothing else reacts while it is open


## Left / right: the time row steps the clock, the preset row moves along the presets.
func _step(dir: int) -> void:
	if _row == 0:
		set_hour(snappedf(DayNight.hour, STEP) + dir * STEP)
		Audio.play("ui_slot")
	elif _row == 1:
		_preset = posmod(_preset + dir, PRESETS.size())
		Audio.play("ui_slot")


## Enter, or a click: action -1 is "this row's own thing" (a click carries the chip it hit).
func _act(row: int, action: int) -> void:
	if row == 0:
		if action != -1:
			set_hour(snappedf(DayNight.hour, STEP) + action * STEP)
			Audio.play("ui_slot")
	elif row == 1:
		if action != -1:
			_preset = action
		set_hour(PRESETS[_preset][1])
		Audio.play("ui_place")
	elif row < TASK_ROW:
		var kind: String = NEEDS[row - 2][1]
		if GameState.survival.frozen.has(kind):
			GameState.survival.frozen.erase(kind)
		else:
			GameState.survival.frozen[kind] = true
		Audio.play("ui_place")
	else:
		var task: String = TASKS[row - TASK_ROW][1]
		var completed := not task_complete(task)
		match task:
			"oxygen", "power":
				GameState.repair_for(task).debug_complete(completed)
			"glass":
				GameState.window_repair.debug_complete(completed, ViewData.get_json(BASE_META))
			"solar":
				GameState.solar_field.debug_complete(completed)
		Audio.play("ui_place")


## Read the real progress, including work completed manually or undone at a solar feed.
static func task_complete(task: String) -> bool:
	match task:
		"oxygen", "power":
			return GameState.repair_for(task).progress() >= 1.0
		"glass":
			var ids: Array = ViewData.get_json(BASE_META)["window_cracks"].map(func(p: Dictionary) -> String: return p["id"])
			return GameState.window_repair.all_fixed(ids)
		"solar":
			return GameState.solar_field.supplies_power()
	return false


# ---------------------------------------------------------------- drawing
func _draw_panel() -> void:
	_hits.clear()
	var o := ((Vector2(384, 216) - SIZE) * 0.5).round()
	_plate(Rect2(o, SIZE))
	var accent := DayNight.phase_color()
	PixelFont.draw(_canvas, o + Vector2(6, 5), "MASTER CONTROL", InventoryUI.WHITE, 1, EDGE)
	PixelFont.draw(_canvas, o + Vector2(SIZE.x - 6 - PixelFont.width("DEV"), 5), "DEV", InventoryUI.GOLD, 1, EDGE)
	_canvas.draw_rect(Rect2(o + Vector2(6, 12), Vector2(SIZE.x - 12, 1)), Color(accent, 0.6))
	# the time: < 08:30 > and the day, the part of the day in its colour
	var y := o.y + 17
	_cursor(0, y)
	PixelFont.draw(_canvas, Vector2(o.x + 10, y + 2), "TIME", InventoryUI.MUTED)
	var minutes := int(round(DayNight.hour * 60.0)) % (24 * 60)
	var clock := "%02d:%02d" % [minutes / 60, minutes % 60]
	var x := o.x + 48
	_button(Rect2(x, y, 9, 9), "<", 0, -1)
	PixelFont.draw(_canvas, Vector2(x + 13, y + 2), clock, InventoryUI.WHITE)
	_button(Rect2(x + 13 + PixelFont.width(clock) + 4, y, 9, 9), ">", 0, 1)
	PixelFont.draw(_canvas, Vector2(x + 52, y + 2), "DAY %d  %s" % [DayNight.day, DayNight.phase], accent)
	# the parts of the day, one press each
	y += 13
	_cursor(1, y)
	var row_w := -3.0
	for p in PRESETS:
		row_w += PixelFont.width(p[0]) + 6 + 3
	x = o.x + roundf((SIZE.x - row_w) * 0.5) + 2
	for i in PRESETS.size():
		var label: String = PRESETS[i][0]
		var r := Rect2(x, y, PixelFont.width(label) + 6, 9)
		var on := _row == 1 and i == _preset
		_canvas.draw_rect(r, Color(accent, 0.35) if on else Color(InventoryUI.DARK, 0.9))
		if on:
			_canvas.draw_rect(r, accent, false, 1.0)
		PixelFont.draw(_canvas, r.position + Vector2(3, 2), label, InventoryUI.WHITE if on else InventoryUI.MUTED)
		_hits.append([r, 1, i])
		x += r.size.x + 3
	# the needs: frozen or running
	y += 15
	for i in NEEDS.size():
		var row := 2 + i
		_cursor(row, y)
		var kind: String = NEEDS[i][1]
		var colour: Color = SurvivalHUD.COLORS[NEEDS[i][2]]
		SurvivalHUD.draw_icon(_canvas, kind, Vector2(o.x + 10, y + 1), colour)
		PixelFont.draw(_canvas, Vector2(o.x + 21, y + 2), NEEDS[i][0], InventoryUI.WHITE)
		var value := int(round(GameState.survival.values[kind]))
		PixelFont.draw(_canvas, Vector2(o.x + 62, y + 2), str(value), InventoryUI.MUTED)
		var frozen := GameState.survival.frozen.has(kind)
		var r := Rect2(o.x + SIZE.x - 56, y, 46, 9)
		_canvas.draw_rect(r, Color(InventoryUI.TEAL, 0.35) if frozen else Color(InventoryUI.DARK, 0.9))
		_canvas.draw_rect(r, InventoryUI.TEAL if frozen else InventoryUI.MUTED, false, 1.0)
		var state := "FROZEN" if frozen else "RUNNING"
		PixelFont.draw(_canvas, r.position + Vector2(roundf((r.size.x - PixelFont.width(state)) * 0.5), 2), state,
				InventoryUI.WHITE if frozen else InventoryUI.MUTED)
		_hits.append([Rect2(o.x + 6, y - 1, SIZE.x - 12, 11), row, -1])
		y += 11
	# Remote task completion, with the same toggle chips as frozen needs.
	y += 3
	_canvas.draw_rect(Rect2(o.x + 6, y, SIZE.x - 12, 1), Color(accent, 0.6))
	y += 4
	PixelFont.draw(_canvas, Vector2(o.x + 10, y), "TASKS - COMPLETE / RESET", InventoryUI.MUTED)
	y += 8
	for i in TASKS.size():
		var row := TASK_ROW + i
		_cursor(row, y)
		PixelFont.draw(_canvas, Vector2(o.x + 10, y + 2), TASKS[i][0], InventoryUI.WHITE)
		var done := task_complete(TASKS[i][1])
		var r := Rect2(o.x + SIZE.x - 56, y, 46, 9)
		_canvas.draw_rect(r, Color(InventoryUI.TEAL, 0.35) if done else Color(InventoryUI.DARK, 0.9))
		_canvas.draw_rect(r, InventoryUI.TEAL if done else InventoryUI.MUTED, false, 1.0)
		var state := "DONE" if done else "PENDING"
		PixelFont.draw(_canvas, r.position + Vector2(roundf((r.size.x - PixelFont.width(state)) * 0.5), 2), state,
				InventoryUI.WHITE if done else InventoryUI.MUTED)
		_hits.append([Rect2(o.x + 6, y - 1, SIZE.x - 12, 11), row, -1])
		y += 11
	PixelFont.draw(_canvas, Vector2(o.x + 6, o.y + SIZE.y - 9), "ARROWS - ENTER   F1 / ESC CLOSE", InventoryUI.MUTED)


## The selected row: a small accent bar at its left.
func _cursor(row: int, y: float) -> void:
	if row == _row:
		_canvas.draw_rect(Rect2(((384 - SIZE.x) * 0.5) + 5, y + 1, 2, 7), DayNight.phase_color())


func _button(r: Rect2, glyph: String, row: int, action: int) -> void:
	_canvas.draw_rect(r, Color(InventoryUI.DARK, 0.9))
	_canvas.draw_rect(r, InventoryUI.MUTED, false, 1.0)
	PixelFont.draw(_canvas, r.position + Vector2(3, 2), glyph, InventoryUI.WHITE)
	_hits.append([r, row, action])


## The time panel's plate: dark, pixel-rounded corners, a faint highlight along the top.
func _plate(r: Rect2) -> void:
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	_canvas.draw_rect(Rect2(x + 1, y + 1, w - 2, h - 2), PLATE)
	_canvas.draw_rect(Rect2(x + 2, y, w - 4, 1), EDGE)
	_canvas.draw_rect(Rect2(x + 2, y + h - 1, w - 4, 1), EDGE)
	_canvas.draw_rect(Rect2(x, y + 2, 1, h - 4), EDGE)
	_canvas.draw_rect(Rect2(x + w - 1, y + 2, 1, h - 4), EDGE)
	for c in [Vector2(x + 1, y + 1), Vector2(x + w - 2, y + 1), Vector2(x + 1, y + h - 2), Vector2(x + w - 2, y + h - 2)]:
		_canvas.draw_rect(Rect2(c, Vector2.ONE), EDGE)
	_canvas.draw_rect(Rect2(x + 2, y + 1, w - 4, 1), Color(1, 1, 1, 0.07))


static func _ensure_actions() -> void:
	if InputMap.has_action("dev_panel"):
		return
	InputMap.add_action("dev_panel")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_F1
	InputMap.action_add_event("dev_panel", key)
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_GUIDE
	InputMap.action_add_event("dev_panel", pad)
