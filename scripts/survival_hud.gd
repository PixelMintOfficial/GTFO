class_name SurvivalHUD
extends CanvasLayer
## Compact SurvivalMeter children, anchored at the top left in every facility/view.
## Fixed placement: pointer input and old saved HUD positions cannot move the stats.
## Compact O2 reserve counter only after O2 repair while mains are off; hides again on mains.
## Owns scene ticking/input only; vitals remain in GameState. Pauses in ordinary modals and
## cutscenes; the live window inspection keeps survival ticking along with world physics.
## Explicit development mode: --survival-debug enables F6 damage, F7 air, F8 empty needs,
## F9 refill, F10 60x time. --vitals=H,O,F,W and --survival-speed=N require that flag.
## --hud-preview=H,O,F,W is UI-only; F11 cycles 0/25/50/75/100, F12 restores live display.
## GUI preferences resize the entire group while retaining fixed top-left placement.

const COLORS := [Color("#ec7a5a"), Color("#7fe6cf"), Color("#efb950"), Color("#4fc6b4")]
const ICONS := {
	"health": [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."],
	"oxygen": ["...#...", ".#.#.#.", "##.#.##", "##.#.##", "###.###", ".#...#."],
	"hunger": ["..###..", ".#####.", ".#####.", "..###..", "...#...", "..###.."],
	"thirst": ["...#...", "..###..", "..###..", ".#####.", ".#####.", "..###.."],
}
const PANEL_SIZE := Vector2(159, 34)
const METER_ORIGIN := Vector2(2, 2)
const METER_SPACING := 31
const MARGIN := Vector2(6, 6)
var _player: Player
var _tool: Multitool
var _indoors := true
var _canvas: Control
var oxygen_counter: Node2D
var _panel: Control
var meters: Array[SurvivalMeter] = []
var _bounds := Rect2(0, 0, 384, 216)
var _preview_step := -1
var debug_enabled := false
var speed := 1.0
var _pulse := 0.0


func setup(player: Player, tool: Multitool, indoors := true) -> void:
	add_to_group("survival_hud")
	layer = 11
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = player
	_tool = tool
	_indoors = indoors
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_hud)
	add_child(_canvas)
	oxygen_counter = Node2D.new()
	oxygen_counter.draw.connect(_draw_oxygen_supply)
	_canvas.add_child(oxygen_counter)
	_panel = Control.new()
	_panel.size = PANEL_SIZE
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.draw.connect(_draw_container)
	_canvas.add_child(_panel)
	for i in SurvivalState.KINDS.size():
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
	GameState.settings.changed.connect(_layout)
	_layout()


func _refresh() -> void:
	_canvas.queue_redraw()
	for meter in meters:
		meter.refresh()


func _position_panel() -> void:
	_panel.position = (_bounds.position + MARGIN).round()


## Shared preference scale for all persistent HUD elements; the compact default is Small.
static func compact_scale(canvas: CanvasItem) -> float:
	var view := canvas.get_viewport_rect().size
	return minf(view.x / 384.0, view.y / 216.0) * GameState.settings.gui_factor(canvas)


## Labels in a UI canvas or the world can avoid the fixed panel in their own coordinates.
## Including the canvas transform handles the world's camera/zoom as well as UI scaling.
static func plate_position(canvas: CanvasItem, desired: Rect2) -> Vector2:
	var hud := canvas.get_tree().get_first_node_in_group("survival_hud") as SurvivalHUD
	if hud == null or not hud._panel.visible:
		return desired.position
	var transform := canvas.get_global_transform_with_canvas().affine_inverse() * hud._panel.get_global_transform_with_canvas()
	var panel_rect := Rect2(transform.origin, PANEL_SIZE * transform.get_scale())
	if panel_rect.intersects(desired):
		return Vector2(desired.position.x, panel_rect.end.y + 5).round()
	return desired.position


## Existing room/day toasts retain their margins and timers.
static func toast_position(canvas: CanvasItem, desired: Vector2, width: int) -> Vector2:
	var plate := Rect2(desired - Vector2(8, 5), Vector2(width + 16, 22))
	return plate_position(canvas, plate) + Vector2(8, 5)


var _hud_drawn := []
var _air_state := ""
var _air_notice := 0.0
var _solar_activity := SurvivalState.SolarActivity.QUIET


func _layout() -> void:
	var view := _canvas.get_viewport_rect().size
	var factor := compact_scale(_canvas)
	_canvas.scale = Vector2.ONE * factor
	_canvas.position = Vector2.ZERO
	# Cover the whole viewport even when inventory centers its 16:9 logical canvas.
	_bounds = Rect2(-_canvas.position / factor, view / factor)
	_position_panel()


func _process(delta: float) -> void:
	_solar_activity = GameState.survival.solar_activity(GameState.clock)
	var air_state := GameState.facility_air.status() + str(GameState.facility_air.sealed())
	if air_state != _air_state:
		_air_state = air_state
		_air_notice = 8.0
	if not get_tree().paused:
		_air_notice = maxf(0., _air_notice - delta)
	_layout()
	_panel.visible = _player.controls_enabled and not _player.puppet and not get_tree().paused and not GameState.survival.dead
	_canvas.visible = not get_tree().paused or GameState.survival.dead
	oxygen_counter.visible = GameState.facility_air.status() in ["reserve", "empty"] \
			and _player.controls_enabled and not _player.puppet and not GameState.survival.dead
	if not get_tree().paused and (_player.controls_enabled or _tool.window_panel_open) and not _player.puppet and not _player.turning:
		GameState.survival.advance(delta * speed, _player.can_breathe(), _player.sprinting)
		GameState.survival.advance_radiation(delta * speed, _indoors, _solar_activity)
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
	var hud := [_player.controls_enabled, _player.can_breathe(), GameState.survival.dead,
			debug_enabled, meters[0].preview, _air_state, _air_notice > 0.,
			roundi(GameState.facility_air.reserve_fraction() * 100.), _solar_activity]
	if hud != _hud_drawn:                                 # a few lines of text, and only on a change
		_hud_drawn = hud
		_canvas.queue_redraw()
		oxygen_counter.queue_redraw()


func _input(event: InputEvent) -> void:
	if GameState.survival.dead:
		get_viewport().set_input_as_handled()
		if not event.is_echo() and event.is_action_pressed("inventory_accept"):
			GameState.rescue()
		return


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


func _draw_hud() -> void:
	var state := GameState.survival
	if not _player.controls_enabled and not state.dead:
		return
	if not state.dead and not _indoors and _solar_activity != SurvivalState.SolarActivity.QUIET:
		var label := "SOLAR FLARE - FIND SHELTER"
		if _solar_activity == SurvivalState.SolarActivity.STORM:
			label = "RADIATION STORM - GET INSIDE"
		var at := MARGIN + Vector2(PANEL_SIZE.x + 6, 4)
		_canvas.draw_rect(Rect2(at, Vector2(PixelFont.width(label) + 8, 11)), InventoryUI.DARK)
		PixelFont.draw(_canvas, at + Vector2(4, 3), label, InventoryUI.GOLD)
	if debug_enabled:
		PixelFont.draw(_canvas, Vector2(6, 39), "DEV %dX AIR %s" % [int(speed), "ON" if _player.can_breathe() else "OFF"], InventoryUI.GOLD)
		if meters[0].preview >= 0:
			PixelFont.draw(_canvas, Vector2(6, 47), "HUD PREVIEW - F12 LIVE", InventoryUI.GOLD)
	if _air_notice > 0. and not get_tree().paused:
		var messages := GameState.facility_air.message()
		for i in messages.size():
			var width := PixelFont.width(messages[i])
			var at := Vector2((_bounds.size.x - width) * .5, _bounds.end.y - 73 + i * 9).round()
			_canvas.draw_rect(Rect2(at - Vector2(3, 2), Vector2(width + 6, 9)), InventoryUI.VOID)
			PixelFont.draw(_canvas, at, messages[i], InventoryUI.GOLD)
	if state.dead:
		_canvas.draw_rect(_bounds, Color(InventoryUI.VOID, 0.9))
		var center := _bounds.get_center()
		PixelFont.draw(_canvas, center + Vector2(-60, -28), "SUIT OFFLINE", InventoryUI.CORAL, 2)
		PixelFont.draw(_canvas, center + Vector2(-PixelFont.width(state.cause) / 2, -6), state.cause, InventoryUI.WHITE)
		PixelFont.draw(_canvas, center + Vector2(-82, 14), "ENTER / A - RETURN TO BASE", InventoryUI.TEAL)


## Temporary reserve battery beside the clock; the owning node hides before repair/on mains.
func _draw_oxygen_supply() -> void:
	var air := GameState.facility_air
	var status := air.status()
	var at := Vector2(86, 44)
	var label := "O2 RESERVE" if status == "reserve" else "O2 MAIN" if status == "online" else "O2 NO POWER" if status == "empty" else "O2 OFFLINE"
	var col := InventoryUI.GOLD if status == "reserve" else InventoryUI.TEAL if status == "online" else InventoryUI.CORAL
	oxygen_counter.draw_rect(Rect2(at, Vector2(84, 28)), DayClock.PLATE)
	oxygen_counter.draw_rect(Rect2(at, Vector2(84, 28)), DayClock.EDGE, false)
	PixelFont.draw(oxygen_counter, at + Vector2(4, 3), label, col)
	var fraction := air.reserve_fraction() if status == "reserve" else 1. if status == "online" else 0.
	for i in 10:
		oxygen_counter.draw_rect(Rect2(at + Vector2(4 + i * 5, 12), Vector2(4, 4)), col if fraction * 10. > i else Color("#3b3253"))
	PixelFont.draw(oxygen_counter, at + Vector2(57, 12), "%d%%" % roundi(fraction * 100.), col)
	var detail := "AIR LEAK" if status in ["reserve", "online"] and not air.sealed() else "AIR OK" if air.breathable() else "NO O2"
	PixelFont.draw(oxygen_counter, at + Vector2(4, 21), detail, InventoryUI.MUTED)
