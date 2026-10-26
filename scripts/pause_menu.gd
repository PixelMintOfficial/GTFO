class_name PauseMenu
extends CanvasLayer
## Escape options: freeze the scene while a dark-grey overlay leaves 15% of the game visible.
## Master Volume and three GUI sizes use GameState.settings; changes apply immediately and
## save on resume or scene exit. Options stay readable at their original size while resizing HUD.
## Closed menus handle only unhandled Escape, so backpacks, repairs, map and dialogue cancel
## first. While open every pointer/key/pad event is consumed; F/X must be released on resume.
## Test hook: --pause-menu opens after a second; tests/pause_menu_test.tscn drives real input.

const BACKDROP := Color(0.10, 0.10, 0.11, 0.85)
const SLIDER := Rect2(108, 91, 168, 15)
const BUTTON_SIZE := Vector2(50, 16)
var opened := false
var _canvas: Control
var _player: Player
var _tool: Multitool
var _focus := 0                                # volume, small, medium, large
var _dragging := false
var _dirty := false
var _release_guard := false
var _view := Vector2.ZERO


static func attach(scene: Node, player: Player, tool: Multitool) -> PauseMenu:
	var menu := PauseMenu.new()
	scene.add_child(menu)
	menu.setup(player, tool)
	return menu


func setup(player: Player, tool: Multitool) -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = player
	_tool = tool
	_ensure_actions()
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_menu)
	add_child(_canvas)
	GameState.settings.changed.connect(_redraw)
	visible = false
	_layout()
	if OS.get_cmdline_user_args().has("--pause-menu"):
		get_tree().create_timer(1.0).timeout.connect(open)


func open() -> bool:
	if opened or get_tree().paused or not _player.controls_enabled or _player.puppet or _player.turning or GameState.survival.dead:
		return false
	_tool.cancel_work()
	_tool.options_suppressed = true
	_focus = 0
	opened = true
	visible = true
	get_tree().paused = true
	_layout()
	_redraw()
	return true


func close() -> void:
	if not opened:
		return
	if _dirty and GameState.settings.save() != OK:
		push_warning("Could not save options")
	_dirty = false
	_dragging = false
	opened = false
	visible = false
	_release_guard = true
	get_tree().paused = false


func _process(_delta: float) -> void:
	_layout()
	if _release_guard and not Input.is_action_pressed("interact") and not Input.is_action_pressed("tool_use"):
		_release_guard = false
		_tool.options_suppressed = false


func _layout() -> void:
	var view := _canvas.get_viewport_rect().size
	if view == _view:
		return
	_view = view
	var fit := minf(view.x / 384.0, view.y / 216.0)
	_canvas.scale = Vector2.ONE * fit
	_canvas.position = ((view - Vector2(384, 216) * fit) * .5).floor()
	_redraw()


func _redraw() -> void:
	_canvas.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_echo() and event.is_action_pressed("pause_options") and open():
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not opened:
		return
	get_viewport().set_input_as_handled()
	if event.is_echo():
		return
	if event.is_action_pressed("pause_options") or event.is_action_pressed("inventory_cancel"):
		close()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var point: Vector2 = _canvas.get_global_transform_with_canvas().affine_inverse() * event.position
		if not event.pressed:
			_dragging = false
		elif SLIDER.grow(3).has_point(point):
			_focus = 0
			_dragging = true
			_volume_at(point)
		else:
			for i in GameSettings.SIZES.size():
				if _button_rect(i).has_point(point):
					_focus = i + 1
					_choose(i)
	elif event is InputEventMouseMotion and _dragging:
		_volume_at(_canvas.get_global_transform_with_canvas().affine_inverse() * event.position)
	elif event.is_action_pressed("inventory_up"):
		_focus = posmod(_focus - 1, 4)
	elif event.is_action_pressed("inventory_down"):
		_focus = (_focus + 1) % 4
	elif event.is_action_pressed("inventory_left") or event.is_action_pressed("inventory_right"):
		var step := -1 if event.is_action_pressed("inventory_left") else 1
		if _focus == 0:
			GameState.settings.set_volume(snappedf(GameState.settings.volume + step * .05, .01))
			_dirty = true
		else:
			_focus = 1 + posmod(_focus - 1 + step, 3)
	elif event.is_action_pressed("inventory_accept") and _focus > 0:
		_choose(_focus - 1)
	_redraw()


func _volume_at(point: Vector2) -> void:
	GameState.settings.set_volume(clampf((point.x - SLIDER.position.x) / SLIDER.size.x, 0, 1))
	_dirty = true


func _choose(index: int) -> void:
	GameState.settings.set_gui_size(GameSettings.SIZES[index])
	_dirty = true


static func _button_rect(index: int) -> Rect2:
	return Rect2(Vector2(108 + index * 59, 137), BUTTON_SIZE)


func _draw_menu() -> void:
	_canvas.draw_rect(Rect2(-_canvas.position / _canvas.scale, _view / _canvas.scale), BACKDROP)
	var white := InventoryUI.WHITE
	var muted := InventoryUI.MUTED
	var teal := InventoryUI.TEAL
	PixelFont.draw(_canvas, Vector2(192 - PixelFont.width("OPTIONS", 2) / 2.0, 43), "OPTIONS", white, 2)
	_canvas.draw_rect(Rect2(108, 62, 168, 1), Color(teal, .6))
	PixelFont.draw(_canvas, Vector2(108, 79), "VOLUME", white)
	var amount := "%d%%" % roundi(GameState.settings.volume * 100)
	PixelFont.draw(_canvas, Vector2(276 - PixelFont.width(amount), 79), amount, teal)
	_canvas.draw_rect(Rect2(108, 97, 168, 3), Color("#45434b"))
	_canvas.draw_rect(Rect2(108, 97, roundf(168 * GameState.settings.volume), 3), teal)
	var thumb := Rect2(106 + roundf(168 * GameState.settings.volume), 93, 5, 11)
	_canvas.draw_rect(thumb.grow(1), InventoryUI.DARK)
	_canvas.draw_rect(thumb, white if _focus == 0 else teal)
	PixelFont.draw(_canvas, Vector2(108, 123), "GUI SCALE", white)
	for i in GameSettings.SIZES.size():
		var rect := _button_rect(i)
		var selected: bool = GameState.settings.gui_size == GameSettings.SIZES[i]
		_canvas.draw_rect(rect, Color(teal, .22) if selected else Color("#242329"))
		_canvas.draw_rect(rect, teal if selected else white if _focus == i + 1 else muted, false, 1)
		var label: String = GameSettings.SIZES[i].to_upper()
		PixelFont.draw(_canvas, rect.position + Vector2(roundf((rect.size.x - PixelFont.width(label)) * .5), 5), label, white if selected else muted)
	var hint := "ESC / B - RESUME"
	PixelFont.draw(_canvas, Vector2(192 - PixelFont.width(hint) / 2.0, 179), hint, muted)


func _exit_tree() -> void:
	if _dirty and GameState.settings.save() != OK:
		push_warning("Could not save options")
	if opened:
		get_tree().paused = false
	if is_instance_valid(_tool):
		_tool.options_suppressed = false


static func _ensure_actions() -> void:
	if InputMap.has_action("pause_options"):
		return
	InputMap.add_action("pause_options")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_ESCAPE
	InputMap.action_add_event("pause_options", key)
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_MISC1
	InputMap.action_add_event("pause_options", pad)
