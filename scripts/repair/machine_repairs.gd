class_name MachineRepairs
extends Node2D
## Interior interaction adapter: data-derived machine anchors, local repair bars,
## F/X priority over the multitool, and a paused circuit modal. No map art changes.

const REACH := 30.0
const INK := Color("#fbfbff")
const DARK := Color("#22182c")
const TEAL := Color("#4fc6b4")

var machines: Array[Dictionary] = []
var panel: CircuitRepairUI
var nearest := -1
var _player: Player
var _tool: Multitool
var _release_guard := false
var _controls_were_enabled := true


func setup(meta: Dictionary, player: Player, tool: Multitool) -> void:
	_player = player
	_tool = tool
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 50
	for info in meta.get("repair_machines", []):
		machines.append(info)
		GameState.repair_for(info["id"])
	panel = CircuitRepairUI.new()
	add_child(panel)
	panel.closed.connect(_closed)


func _process(_delta: float) -> void:
	if _player == null:
		return
	nearest = -1
	if not get_tree().paused and _player.controls_enabled and not _player.puppet and not _player.is_airborne():
		var distance := REACH
		for i in machines.size():
			var point: Array = machines[i]["stand_world"]
			var d := _player.world_pos.distance_to(Vector2(point[0], point[1]))
			if d < distance:
				nearest = i
				distance = d
	if _release_guard and not Input.is_action_pressed("interact") and not Input.is_action_pressed("tool_use"):
		_release_guard = false
	_tool.repair_suppressed = nearest >= 0 or panel.opened or _release_guard
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_echo() and event.is_action_pressed("interact") and nearest >= 0 and not get_tree().paused and not _release_guard and not _tool.inventory_suppressed:
		open_machine(machines[nearest]["id"])
		get_viewport().set_input_as_handled()


func open_machine(machine_id: String) -> bool:
	var repair := GameState.repair_for(machine_id)
	if panel.opened or get_tree().paused or not _player.controls_enabled or _player.puppet or repair.task_completed("wiring"):
		return false
	_tool.cancel_work()
	_tool.repair_suppressed = true
	_controls_were_enabled = _player.controls_enabled
	_player.controls_enabled = false
	get_tree().paused = true
	panel.open(repair)
	return true


func _closed() -> void:
	get_tree().paused = false
	_player.controls_enabled = _controls_were_enabled
	_release_guard = true
	_tool.repair_suppressed = true


func _exit_tree() -> void:
	if panel != null and panel.opened:
		get_tree().paused = false
	if is_instance_valid(_tool):
		_tool.repair_suppressed = false


func _draw() -> void:
	if _player == null or panel.opened:
		return
	for i in machines.size():
		var info := machines[i]
		var repair := GameState.repair_for(info["id"])
		var anchor: Array = info["progress_px"]
		var p := Vector2(anchor[0], anchor[1]).round()
		var percent := "%d%%" % roundi(repair.progress() * 100.0)
		var text: String = info["label"] + "  " + percent
		var width := maxi(78, PixelFont.width(text) + 8)
		var box := Rect2(p - Vector2(roundf(width * 0.5), 10), Vector2(width, 17))
		draw_rect(box.grow(1), DARK)
		draw_rect(box, Color("#151c2b"))
		PixelFont.draw(self, box.position + Vector2(4, 3), text, INK)
		draw_rect(Rect2(box.position + Vector2(4, 11), Vector2(width - 8, 3)), Color("#454259"))
		draw_rect(Rect2(box.position + Vector2(4, 11), Vector2((width - 8) * repair.progress(), 3)), TEAL)
		# A notch makes the two equally weighted repair stages visible.
		draw_rect(Rect2(box.position + Vector2(roundf(width * 0.5), 11), Vector2(1, 3)), DARK)
		if i == nearest:
			var label := "REPAIRED" if repair.progress() >= 1.0 else ("CRACKS PENDING" if repair.task_completed("wiring") else "REPAIR CIRCUIT")
			var top := box.position + Vector2(roundf((width - PixelFont.width(label) - 14) * 0.5), 21)
			draw_rect(Rect2(top - Vector2(2, 2), Vector2(PixelFont.width(label) + 18, 9)), DARK)
			if not repair.task_completed("wiring"):
				draw_rect(Rect2(top, Vector2(7, 7)), INK)
				PixelFont.draw(self, top + Vector2(2, 1), "F", DARK)
			PixelFont.draw(self, top + Vector2(11, 1), label, Color("#efb950"))
