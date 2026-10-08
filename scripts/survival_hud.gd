class_name SurvivalHUD
extends CanvasLayer
## One draggable parent panel with four SurvivalMeter children; top right by default.
## Grip only: left-drag moves, right-click resets; Home/left-stick click also resets.
## SurvivalHUDLayout persists normalized UI placement in user://survival_hud.cfg.
## Owns scene ticking/input only; vitals remain in GameState. Pauses in modals/cutscenes.
## Explicit development mode: --survival-debug enables F6 damage, F7 air, F8 empty needs,
## F9 refill, F10 60x time. --vitals=H,O,F,W and --survival-speed=N require that flag.
## --hud-preview=H,O,F,W is UI-only; F11 cycles 0/25/50/75/100, F12 restores live display.

const COLORS := [Color("#ec7a5a"), Color("#7fe6cf"), Color("#efb950"), Color("#4fc6b4")]
const ICONS := {
	"health": [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."],
	"oxygen": ["...#...", ".#.#.#.", "##.#.##", "##.#.##", "###.###", ".#...#."],
	"hunger": ["..###..", ".#####.", ".#####.", "..###..", "...#...", "..###.."],
	"thirst": ["...#...", "..###..", "..###..", ".#####.", ".#####.", "..###.."],
}
const PANEL_SIZE := Vector2(138, 34)
const HANDLE := Rect2(2, 6, 9, 22)
const METER_ORIGIN := Vector2(11, 2)
const METER_SPACING := 31
const MARGIN := Vector2(6, 6)
var _player: Player
var _tool: Multitool
var _canvas: Control
var _panel: Control
var meters: Array[SurvivalMeter] = []
var layout: SurvivalHUDLayout
var _bounds := Rect2(0, 0, 384, 216)
var _dragging := false
var _drag_offset := Vector2.ZERO
var _hover_grip := false
var _preview_step := -1
var debug_enabled := false
var speed := 1.0
var _pulse := 0.0


func setup(player: Player, tool: Multitool) -> void:
	add_to_group("survival_hud")
	layer = 11
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = player
	_tool = tool
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_hud)
	add_child(_canvas)
	layout = SurvivalHUDLayout.new()
	_panel = Control.new()
	_panel.size = PANEL_SIZE
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.draw.connect(_draw_container)
	_canvas.add_child(_panel)
	for i in 4:
		var meter := SurvivalMeter.new()
		meter.kind = SurvivalState.KINDS[i]
		meter.index = i
		meter.position = METER_ORIGIN + Vector2(i * METER_SPACING, 0)
		_panel.add_child(meter)
		meters.append(meter)
	GameState.survival.changed.connect(_refresh)
	InventoryUI._ensure_actions()
	if not InputMap.has_action("consume_item"):
		InputMap.add_action("consume_item")
		var key := InputEventKey.new()
		key.physical_keycode = KEY_C
		InputMap.action_add_event("consume_item", key)
		var pad := InputEventJoypadButton.new()
		pad.button_index = JOY_BUTTON_RIGHT_STICK
		InputMap.action_add_event("consume_item", pad)
	if not InputMap.has_action("reset_survival_hud"):
		InputMap.add_action("reset_survival_hud")
		var key := InputEventKey.new()
		key.physical_keycode = KEY_HOME
		InputMap.action_add_event("reset_survival_hud", key)
		var pad := InputEventJoypadButton.new()
		pad.button_index = JOY_BUTTON_LEFT_STICK
		InputMap.action_add_event("reset_survival_hud", pad)
	var args := OS.get_cmdline_user_args()
	debug_enabled = OS.is_debug_build() and args.has("--survival-debug")
	if debug_enabled:
		for arg in args:
			if arg.begins_with("--survival-speed="):
				speed = clampf(float(arg.get_slice("=", 1)), 1.0, 120.0)
			if arg.begins_with("--vitals=") and not GameState.survival_debug_initialized:
				var numbers := arg.get_slice("=", 1).split(",")
				if numbers.size() == 4:
					for i in 4:
						GameState.survival.set_value(SurvivalState.KINDS[i], float(numbers[i]))
			if arg.begins_with("--hud-preview="):
				var numbers := arg.get_slice("=", 1).split(",")
				if numbers.size() == 4:
					for i in 4:
						meters[i].preview = clampi(int(numbers[i]), 0, 100)
		GameState.survival_debug_initialized = true
	_position_panel()


func _refresh() -> void:
	_canvas.queue_redraw()
	for meter in meters:
		meter.refresh()


func _position_panel() -> void:
	var travel := (_bounds.size - PANEL_SIZE - MARGIN * 2).max(Vector2.ZERO)
	_panel.position = (_bounds.position + MARGIN + travel * layout.normalized).round()


func _move_panel(point: Vector2) -> void:
	var travel := (_bounds.size - PANEL_SIZE - MARGIN * 2).max(Vector2.ZERO)
	var low := _bounds.position + MARGIN
	var pos := point.clamp(low, low + travel)
	layout.normalized = Vector2((pos.x - low.x) / travel.x if travel.x > 0 else 0,
			(pos.y - low.y) / travel.y if travel.y > 0 else 0)
	_position_panel()


func reset_position() -> void:
	_dragging = false
	if layout.reset() != OK:
		push_warning("Could not save survival HUD position")
	_position_panel()


func _save_position() -> void:
	if layout.save() != OK:
		push_warning("Could not save survival HUD position")


## Existing room/day toasts can avoid the moved panel without changing their timers/state.
static func toast_position(canvas: CanvasItem, desired: Vector2, width: int) -> Vector2:
	var hud := canvas.get_tree().get_first_node_in_group("survival_hud") as SurvivalHUD
	if hud == null or not hud._panel.visible:
		return desired
	var transform := canvas.get_global_transform().affine_inverse() * hud._panel.get_global_transform()
	var panel_rect := Rect2(transform.origin, PANEL_SIZE * transform.get_scale())
	if panel_rect.intersects(Rect2(desired - Vector2(8, 5), Vector2(width + 16, 22))):
		return Vector2(desired.x, panel_rect.end.y + 10).round()
	return desired


func _process(delta: float) -> void:
	var view := _canvas.get_viewport_rect().size
	var factor := minf(view.x / 384.0, view.y / 216.0)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = ((view - Vector2(384, 216) * factor) * 0.5).floor()
	# Cover the whole viewport even when inventory centers its 16:9 logical canvas.
	_bounds = Rect2(-_canvas.position / factor, view / factor)
	_position_panel()
	_panel.visible = _player.controls_enabled and not _player.puppet and not get_tree().paused and not GameState.survival.dead
	if _dragging and (not _panel.visible or _player.turning):
		_dragging = false
		_save_position()
	_hover_grip = HANDLE.has_point(_canvas.get_local_mouse_position() - _panel.position)
	_panel.queue_redraw()
	if not get_tree().paused and _player.controls_enabled and not _player.puppet and not _player.turning:
		GameState.survival.advance(delta * speed, _player.can_breathe(), _player.sprinting)
	if GameState.survival.dead:
		layer = 20
		_tool.cancel_work()
		_player.controls_enabled = false
		_player.forced_input = Vector2.ZERO
		_player.forced_run = false
		get_tree().paused = true
	_pulse += delta
	for meter in meters:
		meter.pulse = _pulse
		meter.refresh()
	_canvas.queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and _dragging:
		_dragging = false
		_save_position()


func _input(event: InputEvent) -> void:
	if GameState.survival.dead:
		get_viewport().set_input_as_handled()
		if not event.is_echo() and event.is_action_pressed("inventory_accept"):
			GameState.rescue()
		return
	if get_tree().paused or not _player.controls_enabled or _player.puppet or _player.turning:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed and _dragging:
		_dragging = false
		_save_position()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		_move_panel(_canvas.get_global_transform().affine_inverse() * event.position - _drag_offset)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		var local: Vector2 = _canvas.get_global_transform().affine_inverse() * event.position
		if HANDLE.has_point(local - _panel.position):
			if event.button_index == MOUSE_BUTTON_LEFT:
				_dragging = true
				_drag_offset = local - _panel.position
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				reset_position()
			else:
				return
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if GameState.survival.dead:
		return
	if get_tree().paused or not _player.controls_enabled or _player.puppet or _player.turning:
		return
	if event.is_action_pressed("consume_item"):
		Audio.play("ui_place" if GameState.consume_slot(GameState.selected_slot) else "ui_deny")
		get_viewport().set_input_as_handled()
	if event.is_action_pressed("reset_survival_hud"):
		reset_position()
		get_viewport().set_input_as_handled()
	if debug_enabled and event is InputEventKey and event.pressed:
		match event.physical_keycode:
			KEY_F6: _player.take_damage(25.0)
			KEY_F7: _player.breathable = not _player.breathable
			KEY_F8:
				GameState.survival.set_value("hunger", 0.0)
				GameState.survival.set_value("thirst", 0.0)
			KEY_F9: GameState.survival.reset()
			KEY_F10: speed = 60.0 if speed == 1.0 else 1.0
			KEY_F11:
				_preview_step = (_preview_step + 1) % 5
				for meter in meters:
					meter.preview = _preview_step * 25
			KEY_F12:
				for meter in meters:
					meter.preview = -1


static func draw_icon(canvas: Control, kind: String, origin: Vector2, color: Color, size := 1) -> void:
	var pattern: Array = ICONS[kind]
	for y in pattern.size():
		for x in pattern[y].length():
			if pattern[y][x] == "#":
				canvas.draw_rect(Rect2(origin + Vector2(x, y) * size, Vector2.ONE * size), color)


func _draw_container() -> void:
	# Pixel-rounded capsule, recessed rim and top bevel. Procedural UI, no imported art.
	for y in int(PANEL_SIZE.y):
		var dy := absf(y + 0.5 - PANEL_SIZE.y / 2.0)
		var inset := ceili(10 - sqrt(maxf(0.0, 10 * 10 - pow(maxf(0.0, dy - 7), 2))))
		_panel.draw_rect(Rect2(inset, y + 1, PANEL_SIZE.x - inset * 2, 1), Color("#060610"))
		_panel.draw_rect(Rect2(inset, y, PANEL_SIZE.x - inset * 2, 1), InventoryUI.DARK)
		if y >= 1 and y < PANEL_SIZE.y - 1:
			_panel.draw_rect(Rect2(inset + 1, y, PANEL_SIZE.x - inset * 2 - 2, 1), Color("#14111f"))
	_panel.draw_rect(Rect2(11, 1, PANEL_SIZE.x - 22, 1), Color("#332d42"))
	var grip := InventoryUI.TEAL if _dragging else InventoryUI.WHITE if _hover_grip else InventoryUI.MUTED
	for y in 3:
		for x in 2:
			_panel.draw_rect(Rect2(4 + x * 3, 12 + y * 4, 2, 2), grip)
	if _hover_grip or _dragging:
		var hint := "DRAG - RIGHT CLICK RESET"
		var pos := Vector2(4, PANEL_SIZE.y + 3)
		if _panel.position.y + PANEL_SIZE.y + 11 > _bounds.end.y:
			pos.y = -10
		_panel.draw_rect(Rect2(pos - Vector2.ONE, Vector2(PixelFont.width(hint) + 2, 7)), InventoryUI.VOID)
		PixelFont.draw(_panel, pos, hint, InventoryUI.MUTED)


func _draw_hud() -> void:
	var state := GameState.survival
	if not _player.controls_enabled and not state.dead:
		return
	if debug_enabled:
		PixelFont.draw(_canvas, Vector2(6, 39), "DEV %dX AIR %s" % [int(speed), "ON" if _player.can_breathe() else "OFF"], InventoryUI.GOLD)
		if meters[0].preview >= 0:
			PixelFont.draw(_canvas, Vector2(6, 47), "HUD PREVIEW - F12 LIVE", InventoryUI.GOLD)
	if not _player.can_breathe():
		PixelFont.draw(_canvas, Vector2(145, 137), "O2 RESERVE IN USE", InventoryUI.GOLD)
	if state.dead:
		_canvas.draw_rect(Rect2(0, 0, 384, 216), Color(InventoryUI.VOID, 0.9))
		PixelFont.draw(_canvas, Vector2(132, 80), "SUIT OFFLINE", InventoryUI.CORAL, 2)
		PixelFont.draw(_canvas, Vector2(192 - PixelFont.width(state.cause) / 2, 102), state.cause, InventoryUI.WHITE)
		PixelFont.draw(_canvas, Vector2(110, 122), "ENTER / A - RETURN TO BASE", InventoryUI.TEAL)
