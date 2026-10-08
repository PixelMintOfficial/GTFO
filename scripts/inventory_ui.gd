class_name InventoryUI
extends CanvasLayer
## Six-slot quick access and a paused 24-slot backpack, shared by both scenes.
## E / Start toggles; F / X remains world interaction. Click two slots to swap;
## arrows / d-pad navigate, Enter / A picks and places. 1-6 / wheel select quick access.
## Draws with PixelFont and existing generated sprites, in a 384x216 logical canvas.
## Test hooks (both scenes): --open-inventory opens after setup, --inventory-demo
## seeds ore/scrap explicitly for screenshots; normal games start with only the tool.

const DARK := Color("#22182c")
const VOID := Color("#0b0915")
const WHITE := Color("#fbfbff")
const CORAL := Color("#ec7a5a")
const TEAL := Color("#4fc6b4")
const GOLD := Color("#efb950")
const MUTED := Color("#8f8ba8")
const PANEL := Rect2(40, 23, 304, 147)
const CELL := Vector2(32, 32)

var opened := false
var _player: Player
var _tool: Multitool
var _canvas: Control
var _amount := 0.0
var _focus := 0
var _picked := -1
var _hover := -1
var _textures := {}
var _portrait: Texture2D
var _release_guard := false
var _notice := ""
var _notice_time := 0.0
var _selection_changed := false
var _pending_selection := false


func setup(player: Player, tool: Multitool) -> void:
	layer = 12
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = player
	_tool = tool
	_ensure_actions()
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_inventory)
	add_child(_canvas)
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/maps/red_planet/red_planet_props.json"))
	for kind in ["ore_chunk", "scrap"]:
		var sheet: Dictionary = data["sprites"][kind]
		var tex := AtlasTexture.new()
		tex.atlas = load("res://assets/maps/red_planet/" + sheet["file"])
		tex.region = Rect2(Vector2.ZERO, Vector2(sheet["frame_size"][0], sheet["frame_size"][1]))
		_textures[kind] = tex
	_portrait = player.sprite.sprite_frames.get_frame_texture("idle_SE", 0)
	GameState.inventory_changed.connect(_refresh)
	tool.inventory_full.connect(func() -> void:
		Audio.play("ui_deny")
		_notice = "BACKPACK FULL"
		_notice_time = 2.0)
	_refresh()
	for arg in OS.get_cmdline_user_args():
		if arg == "--inventory-demo":
			for i in 3:
				GameState.store_item("ore_chunk")
			GameState.store_item("scrap")
		if arg == "--open-inventory":
			get_tree().create_timer(0.5).timeout.connect(func() -> void: toggle())


func _refresh() -> void:
	_canvas.queue_redraw()


func toggle() -> void:
	if not opened and (get_tree().paused or not _player.controls_enabled or _player.puppet):
		return
	opened = not opened
	Audio.play("ui_bag_open" if opened else "ui_bag_close")
	get_tree().paused = opened
	_tool.inventory_suppressed = true
	if opened:
		_tool.cancel_work()
		_focus = GameState.selected_slot
		_selection_changed = false
	else:
		_picked = -1
		_release_guard = true
		if _selection_changed:
			_pending_selection = true
			_apply_selection()
	_refresh()


func _apply_selection() -> void:
	if get_tree().paused or not _player.controls_enabled or _player.puppet or _player.is_airborne():
		return
	if _player.tool_state in [Player.Tool.EQUIPPING, Player.Tool.HOLSTERING]:
		return
	var slot: Dictionary = GameState.inventory[GameState.selected_slot]
	var wants_tool: bool = slot.get("kind", "") == "multitool"
	if wants_tool and _player.tool_state == Player.Tool.HOLSTERED:
		_tool.cancel_work()
		_player.toggle_tool()
	elif not wants_tool and _player.tool_state == Player.Tool.READY:
		_tool.cancel_work()
		_player.toggle_tool()
	else:
		_pending_selection = false


func _select(index: int) -> void:
	Audio.play("ui_slot")
	GameState.select_slot(index)
	_focus = index
	_pending_selection = true
	_apply_selection()


func _activate(index: int) -> void:
	_focus = index
	if _picked < 0:
		if index < GameState.HOTBAR_SIZE:
			_selection_changed = _selection_changed or index != GameState.selected_slot
			GameState.select_slot(index)
		if not GameState.inventory[index].is_empty():
			_picked = index
			Audio.play("ui_pick")
	else:
		_selection_changed = _selection_changed or GameState.selected_slot in [_picked, index]
		GameState.swap_slots(_picked, index)
		_picked = -1
		Audio.play("ui_place")
	_refresh()


func _input(event: InputEvent) -> void:
	if event.is_echo():
		if opened:
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toggle_inventory"):
		if opened or (not get_tree().paused and _player.controls_enabled and not _player.puppet):
			toggle()
			get_viewport().set_input_as_handled()
		return
	if not opened and (get_tree().paused or not _player.controls_enabled or _player.puppet):
		return
	if not opened and event.is_action_pressed("tool_toggle"):
		_pending_selection = false
		if _player.tool_state == Player.Tool.HOLSTERED:
			for i in GameState.HOTBAR_SIZE:
				if GameState.inventory[i].get("kind", "") == "multitool":
					GameState.select_slot(i)
					break
	if not opened and event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_LEFT_SHOULDER:
		_select((GameState.selected_slot + 1) % GameState.HOTBAR_SIZE)
		get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed:
		var index: int = event.physical_keycode - KEY_1
		if index >= 0 and index < GameState.HOTBAR_SIZE:
			if opened:
				_focus = index
				_selection_changed = _selection_changed or index != GameState.selected_slot
				GameState.select_slot(index)
			else:
				_select(index)
			get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed:
		if not opened and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_select(posmod(GameState.selected_slot + (-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1), GameState.HOTBAR_SIZE))
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			var at := _slot_at(_canvas.get_global_transform().affine_inverse() * event.position)
			if at >= 0:
				if opened:
					_activate(at)
				else:
					_select(at)
				get_viewport().set_input_as_handled()
	if opened:
		if event.is_action_pressed("inventory_cancel"):
			if _picked >= 0:
				_picked = -1
			else:
				toggle()
		elif event.is_action_pressed("inventory_accept"):
			_activate(_focus)
		elif event.is_action_pressed("inventory_left"):
			_focus = floori(_focus / 6.0) * 6 + posmod(_focus % 6 - 1, 6)
		elif event.is_action_pressed("inventory_right"):
			_focus = floori(_focus / 6.0) * 6 + (_focus + 1) % 6
		elif event.is_action_pressed("inventory_up"):
			_focus = posmod(_focus - 6, GameState.INVENTORY_SIZE)
		elif event.is_action_pressed("inventory_down"):
			_focus = (_focus + 6) % GameState.INVENTORY_SIZE
		elif event.is_action_pressed("consume_item") and _picked < 0:
			Audio.play("ui_place" if GameState.consume_slot(_focus) else "ui_deny")
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	var view := _canvas.get_viewport_rect().size
	var factor := minf(view.x / 384.0, view.y / 216.0)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = ((view - Vector2(384, 216) * factor) * 0.5).floor()
	_amount = move_toward(_amount, 1.0 if opened else 0.0, delta / 0.14)
	if _release_guard and not Input.is_action_pressed("tool_use") and not Input.is_action_pressed("interact"):
		_release_guard = false
		_tool.inventory_suppressed = false
	_notice_time = maxf(0.0, _notice_time - delta)
	_hover = _slot_at(_canvas.get_local_mouse_position())
	if _pending_selection and not opened:
		_apply_selection()
	_canvas.queue_redraw()


func _slot_rect(index: int) -> Rect2:
	if index < 6:
		return Rect2(Vector2(85 + index * 36, 177), CELL)
	var row := floori((index - 6) / 6.0)
	return Rect2(Vector2(122 + (index % 6) * 36, 49 + row * 36), CELL)


func _slot_at(pos: Vector2) -> int:
	for i in GameState.INVENTORY_SIZE if opened else GameState.HOTBAR_SIZE:
		if _slot_rect(i).has_point(pos):
			return i
	return -1


func _draw_inventory() -> void:
	if not opened and (not _player.controls_enabled or (get_tree().paused and _amount == 0.0)):
		return
	if _amount > 0.0:
		_canvas.draw_rect(Rect2(0, 0, 384, 216), Color(VOID, _amount * 0.72))
		# Short, pixel-snapped reveal; controls become modal immediately.
		_canvas.draw_set_transform(Vector2(0, roundf((1.0 - _amount) * 6)))
		_canvas.draw_rect(PANEL.grow(2), DARK)
		_canvas.draw_rect(PANEL, VOID)
		_canvas.draw_rect(Rect2(40, 23, 304, 20), DARK)
		PixelFont.draw(_canvas, Vector2(49, 28), "BACKPACK", WHITE, 2)
		PixelFont.draw(_canvas, Vector2(269, 31), "E - CLOSE", MUTED)
		_canvas.draw_rect(Rect2(40, 43, 304, 1), CORAL)
		_canvas.draw_rect(Rect2(48, 49, 65, 69), DARK)
		_canvas.draw_texture(_portrait, Vector2(48, 48))
		PixelFont.draw(_canvas, Vector2(56, 110), "EXPLORER", TEAL)
		var slot: Dictionary = GameState.inventory[_hover if _hover >= 0 else _focus]
		var kind: String = slot.get("kind", "")
		PixelFont.draw(_canvas, Vector2(49, 127), GameState.ITEMS[kind]["name"] if kind != "" else "EMPTY SLOT", GOLD)
		PixelFont.draw(_canvas, Vector2(49, 137), "SELECT TWO", MUTED)
		PixelFont.draw(_canvas, Vector2(49, 145), "C - EAT/DRINK", MUTED)
		PixelFont.draw(_canvas, Vector2(49, 154), "ARROWS - MOVE   ENTER - PICK   ESC - BACK", MUTED)
		for i in range(6, GameState.INVENTORY_SIZE):
			_draw_slot(i)
		_canvas.draw_set_transform(Vector2.ZERO)
	# Quiet plate behind the quick access strip keeps slots readable on snow and dust.
	_canvas.draw_rect(Rect2(81, 173, 222, 40), Color(VOID, 0.94))
	for i in GameState.HOTBAR_SIZE:
		_draw_slot(i)
	var selected: Dictionary = GameState.inventory[GameState.selected_slot]
	var name: String = GameState.ITEMS[selected["kind"]]["name"] if not selected.is_empty() else "EMPTY SLOT"
	if _notice_time > 0.0:
		name = _notice
	elif opened:
		name = "QUICK ACCESS - " + name
	else:
		name += "   C - USE" if selected.get("kind", "") in ["ration", "water"] else "   E - BACKPACK"
	var w := PixelFont.width(name)
	_canvas.draw_rect(Rect2(192 - floori(w / 2.0) - 4, 163, w + 8, 10), VOID)
	PixelFont.draw(_canvas, Vector2(192 - floori(w / 2.0), 165), name, WHITE)


func _draw_slot(index: int) -> void:
	var r := _slot_rect(index)
	var selected := index == GameState.selected_slot
	var focus := opened and index == _focus
	_canvas.draw_rect(r.grow(1), CORAL if selected else TEAL if focus or index == _hover else DARK)
	_canvas.draw_rect(r, DARK)
	_canvas.draw_rect(Rect2(r.position + Vector2.ONE, Vector2(30, 1)), MUTED if selected else Color("#40344e"))
	if selected:
		_canvas.draw_rect(Rect2(r.position + Vector2(0, 30), Vector2(32, 2)), CORAL)
	var slot: Dictionary = GameState.inventory[index]
	if slot.is_empty():
		_canvas.draw_rect(Rect2(r.position + Vector2(14, 15), Vector2(4, 1)), Color("#40344e"))
	else:
		var kind: String = slot["kind"]
		if kind == "multitool":
			var pattern: Array = Multitool.ICONS["fix"]
			for y in pattern.size():
				for x in pattern[y].length():
					if pattern[y][x] == "#":
						_canvas.draw_rect(Rect2(r.position + Vector2(9 + x * 2, 7 + y * 2), Vector2(2, 2)), GOLD)
		elif kind in ["ration", "water"]:
			SurvivalHUD.draw_icon(_canvas, "hunger" if kind == "ration" else "thirst", r.position + Vector2(9, 9), GOLD if kind == "ration" else TEAL, 2)
		else:
			var tex: Texture2D = _textures[kind]
			# Existing pixel art, rendered at native size; no new generated assets.
			_canvas.draw_texture(tex, (r.position + (CELL - tex.get_size()) * 0.5).floor())
		if slot["count"] > 1:
			var count_text := str(slot["count"])
			var pos := r.end - Vector2(PixelFont.width(count_text) + 2, 7)
			_canvas.draw_rect(Rect2(pos - Vector2.ONE, Vector2(PixelFont.width(count_text) + 2, 7)), VOID)
			PixelFont.draw(_canvas, pos, count_text, WHITE)
	if index < 6:
		PixelFont.draw(_canvas, r.position + Vector2(2, 2), str(index + 1), CORAL if selected else MUTED)
	if index == _picked:
		_canvas.draw_rect(r.grow(1), TEAL, false, 1.0)
		PixelFont.draw(_canvas, r.position + Vector2(13, 24), "P", TEAL)


func _exit_tree() -> void:
	if opened:
		get_tree().paused = false


static func _ensure_actions() -> void:
	var actions := {
		"toggle_inventory": [KEY_E, JOY_BUTTON_START],
		"inventory_accept": [KEY_ENTER, JOY_BUTTON_A],
		"inventory_cancel": [KEY_ESCAPE, JOY_BUTTON_B],
		"inventory_left": [KEY_LEFT, JOY_BUTTON_DPAD_LEFT],
		"inventory_right": [KEY_RIGHT, JOY_BUTTON_DPAD_RIGHT],
		"inventory_up": [KEY_UP, JOY_BUTTON_DPAD_UP],
		"inventory_down": [KEY_DOWN, JOY_BUTTON_DPAD_DOWN],
	}
	for action in actions:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var key := InputEventKey.new()
		key.physical_keycode = actions[action][0]
		InputMap.action_add_event(action, key)
		var pad := InputEventJoypadButton.new()
		pad.button_index = actions[action][1]
		InputMap.action_add_event(action, pad)
