class_name MapScreen
extends CanvasLayer
## Whole-map overview, toggled with M (Esc also closes it). The game pauses while it is
## open. Shows the map generator's map-screen image, where the astronaut is, and the
## patch of ground the camera currently sees.

const FRAME := Color("#6d6288")
const FRAME_DARK := Color("#22182c")
const MARKER := Color("#ec7a5a")
const VIEW_BOX := Color(0.96, 0.92, 0.86, 0.75)

var _player: Player
var _tex: Texture2D
var _origin := Vector2.ZERO
var _scale := 1.0
var _canvas: Control
var _time := 0.0


func setup(meta_path: String, player: Player) -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_player = player
	load_view(meta_path)
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_map)
	add_child(_canvas)
	if not InputMap.has_action("toggle_map"):
		InputMap.add_action("toggle_map")
		var key := InputEventKey.new()
		key.physical_keycode = KEY_M
		InputMap.action_add_event("toggle_map", key)
		var pad := InputEventJoypadButton.new()
		pad.button_index = JOY_BUTTON_BACK
		InputMap.action_add_event("toggle_map", pad)


## The camera turned: the map screen turns with it.
func load_view(meta_path: String) -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	var mm: Dictionary = meta["minimap"]
	_tex = load(meta_path.get_base_dir().path_join(mm["file"]))
	_origin = Vector2(mm["origin"][0], mm["origin"][1])
	_scale = mm["scale"]


func toggle() -> void:
	visible = not visible
	Audio.play("ui_map_open" if visible else "ui_map_close")
	get_tree().paused = visible
	_time = 0.0
	_canvas.queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_map") or (visible and event.is_action_pressed("ui_cancel")):
		toggle()
		get_viewport().set_input_as_handled()


func _ready() -> void:
	visible = false  # until setup() and M


func _process(delta: float) -> void:
	if visible and _canvas != null:
		_time += delta
		_canvas.queue_redraw()


func _draw_map() -> void:
	var view := _canvas.get_viewport_rect().size
	_canvas.draw_rect(Rect2(Vector2.ZERO, view), Color(0.03, 0.02, 0.06, 0.85))
	var size := _tex.get_size()
	var at := ((view - size) * 0.5).floor()
	_frame(Rect2(at - Vector2(2, 2), size + Vector2(4, 4)), FRAME_DARK)
	_frame(Rect2(at - Vector2(1, 1), size + Vector2(2, 2)), FRAME)
	_canvas.draw_texture(_tex, at)

	# what the camera sees right now
	var cam := _player.camera.get_screen_center_position()
	var seen := _player.camera.view_size()
	var box := Rect2(((cam - seen * 0.5) - _origin) * _scale + at, (seen * _scale).ceil())
	_frame(Rect2(box.position.floor(), box.size), VIEW_BOX)

	# the astronaut: a blinking dot with a ring that pulses outward
	var p := ((_player.global_position - _origin) * _scale + at).floor()
	var t := fmod(_time, 1.2) / 1.2
	var ring := 3.0 + 6.0 * t
	_canvas.draw_arc(p + Vector2(0.5, 0.5), ring, 0.0, TAU, 24, Color(MARKER, 1.0 - t), 1.0)
	if fmod(_time, 0.8) < 0.6:
		_canvas.draw_rect(Rect2(p - Vector2(2, 2), Vector2(5, 5)), FRAME_DARK)
		_canvas.draw_rect(Rect2(p - Vector2(1, 1), Vector2(3, 3)), MARKER)


## 1px border drawn as filled strips so it stays crisp at pixel scale.
func _frame(r: Rect2, c: Color) -> void:
	_canvas.draw_rect(Rect2(r.position, Vector2(r.size.x, 1)), c)
	_canvas.draw_rect(Rect2(r.position + Vector2(0, r.size.y - 1), Vector2(r.size.x, 1)), c)
	_canvas.draw_rect(Rect2(r.position, Vector2(1, r.size.y)), c)
	_canvas.draw_rect(Rect2(r.position + Vector2(r.size.x - 1, 0), Vector2(1, r.size.y)), c)
