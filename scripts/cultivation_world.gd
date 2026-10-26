class_name CultivationWorld
extends Node2D
## World adapter for wild seed plants or the nursery's repaired, reseeded growing beds.
## F/X taps gather, plant or harvest; nursery repairs require an equipped multitool and
## its existing hold-to-fix scanner job. Independent suppression/release ownership
## prevents one press from also firing the multitool or an airlock. Options require release
## before work resumes. State lives in GameState;
## geometry/anchors/sheets come from the native generators. No modal or minigame is used.
## Test hooks are owned by the scenes: --forage-at=ID, --nursery-at=ID and crop-state previews.

const ART := "res://assets/cultivation/cultivation.json"
const SITES := "res://assets/maps/red_planet/forage_sites.json"
const BEDS := "res://assets/maps/nursery_interior/crops.json"
const DARK := Color("#22182c")
const WHITE := Color("#fbfbff")
const TEAL := Color("#7fe6cf")

var state: CultivationState
var nearest := ""
var visuals: Dictionary = {}
var targets: Dictionary = {}
var nursery := false
var _player: Player
var _tool: Multitool
var _terrain: MapTerrain
var _art: Dictionary
var _beds: Dictionary
var _release_guard := false
var _bloom := 0.0
var _last_prompt := ""
var _last_target := ""
var _notice := ""
var _notice_left := 0.0
var _fix_id := ""
var _fixable: Dictionary = {}


func setup(player: Player, tool: Multitool, terrain: MapTerrain, actors: Node2D, indoors := false) -> void:
	_player = player
	_tool = tool
	_terrain = terrain
	nursery = indoors
	state = GameState.cultivation
	process_priority = -15
	z_index = 50
	set_meta("dn_unlit", true)
	_bloom = 1.0 if CultivationState.is_night(GameState.clock) else 0.0
	if nursery:
		_beds = ViewData.get_json(BEDS)
		for bed in _beds["beds"]:
			var id: String = bed["id"]
			targets[id] = bed.duplicate()
			targets[id]["type"] = "bed"
			_make_visual(id, bed["views"][terrain.heading], BEDS.get_base_dir(), actors, false)
	else:
		_art = ViewData.get_json(ART)
		for site in ViewData.get_json(SITES)["sites"]:
			var id: String = site["id"]
			targets[id] = site.duplicate()
			targets[id]["type"] = "wild"
			_make_visual(id, _art["wild"][site["species"]][terrain.heading], ART.get_base_dir(), actors, true)
	state.changed.connect(_changed)
	load_view()


static func point(value: Array) -> Vector2:
	return Vector2(value[0], value[1])


func _make_visual(id: String, sheet: Dictionary, root: String, actors: Node2D, solid: bool) -> void:
	var visual := CropVisual.new()
	actors.add_child(visual)
	visual.setup(sheet, root, _terrain, point(targets[id]["world"]), solid)
	visuals[id] = visual


func load_view() -> void:
	if nursery:
		for key in targets.keys():
			if targets[key]["type"] == "repair":
				targets.erase(key)
		var metadata := ViewData.get_json(_terrain.view_json)
		for repair in metadata["cultivation"]["repairs"]:
			targets[repair["id"]] = repair.duplicate()
			targets[repair["id"]]["type"] = "repair"
	for id in visuals:
		var info: Dictionary = targets[id]
		var sheet: Dictionary = info["views"][_terrain.heading] if nursery else _art["wild"][info["species"]][_terrain.heading]
		(visuals[id] as CropVisual).set_view(sheet)
	_update_frames()
	_place_fixable()
	queue_redraw()


func refresh_window() -> void:
	for visual in visuals.values():
		(visual as CropVisual).refresh_window()


func interaction_point(id: String) -> Vector2:
	if not targets.has(id):
		return Vector2.ZERO
	var entry: Dictionary = targets[id]
	if entry.has("stand_world"):
		return point(entry["stand_world"])
	var world := point(entry["world"])
	# Generator placements have a clear, level 24-unit patch. Stand just off the root.
	return world + Vector2(0., -12.)


func _can_interact() -> bool:
	if get_tree().paused or not _player.controls_enabled or _player.puppet or _player.turning or _player.is_airborne():
		return false
	if _tool.inventory_suppressed or _tool.options_suppressed or _tool.repair_suppressed or _tool.window_suppressed or _tool.solar_suppressed or _tool.bot_suppressed or _tool._lifted != null:
		return false
	# Doors own F before this frame's _process has had time to publish suppression.
	for node in get_tree().get_nodes_in_group("airlock_doors"):
		var door := node as AirlockDoor
		if door != null and not door.is_queued_for_deletion() and (door.busy() or door._in_reach()):
			return false
	return true


func _nearest() -> String:
	if not _can_interact():
		return ""
	var distance := float(state.config["reach"])
	var result := ""
	for id in targets:
		var entry: Dictionary = targets[id]
		if entry["type"] == "repair" and state.repaired(id):
			continue
		var target := point(entry.get("stand_world", entry["world"]))
		if absf(_terrain.height_at(target) - _terrain.height_at(_player.world_pos)) > 8.:
			continue
		var d := _player.world_pos.distance_to(target)
		# A broken rack shares its stand with its bed: repair takes priority until mended.
		if d < distance or (is_equal_approx(d, distance) and entry["type"] == "repair"):
			distance = d
			result = id
	return result


func _update_frames() -> void:
	for id in visuals:
		var info: Dictionary = targets[id]
		var frame := 0
		if nursery:
			frame = state.stage(id, GameState.clock)
			if frame == 0 and id == "silo0" and not state.repaired("light"):
				frame = 3
			if frame == 0 and id == "rack1" and not state.repaired("rack"):
				frame = 3
		elif info["species"] == "moonwell":
			frame = clampi(roundi(_bloom * 8.), 0, 8)
			if GameState.clock < float(state.wild_ready_at.get(id, -1.0)):
				frame += 9
		else:
			frame = 0 if state.wild_ready(id, info["species"], GameState.clock) else 1
		(visuals[id] as CropVisual).set_frame(frame)


func _process(delta: float) -> void:
	if _release_guard and not Input.is_action_pressed("interact") and not Input.is_action_pressed("tool_use"):
		_release_guard = false
	if not nursery:
		_bloom = move_toward(_bloom, 1.0 if CultivationState.is_night(GameState.clock) else 0.0, delta / 1.2)
	_update_frames()
	nearest = _nearest()
	_sync_fixable()
	var scanner_owns := not _fixable.is_empty() and not _release_guard
	_tool.cultivation_suppressed = _release_guard or (not nearest.is_empty() and not scanner_owns)
	var prompt := _prompt(nearest) if not nearest.is_empty() else ""
	if _notice_left > 0.0:
		_notice_left = maxf(0.0, _notice_left - delta)
		prompt = _notice if _notice_left > 0.0 else prompt
	if prompt != _last_prompt or nearest != _last_target:
		_last_prompt = prompt
		_last_target = nearest
		queue_redraw()


func _prompt(id: String) -> String:
	var info: Dictionary = targets[id]
	if info["type"] == "repair":
		if not GameState.story.nursery_awake:
			return "REPAIR UNIT FIRST"
		if _player.tool_state != Player.Tool.READY:
			return "[T] EQUIP MULTITOOL TO REPAIR"
		return "HOLD [F] REPAIR " + info["label"]
	if info["type"] == "bed":
		var crop: Dictionary = state.config["crops"][info["kind"]]
		match state.stage(id, GameState.clock):
			0:
				if state.repairs != 7:
					return "REPAIR THE NURSERY FIRST"
				if GameState.item_count(crop["seed"]) > 0:
					return "[F] PLANT " + crop["label"]
				var source: String = state.config["wild"][crop["wild"]]["label"]
				return "FIND " + source + " SEEDS" + (" AT NIGHT" if crop["wild"] == "moonwell" else "")
			1:
				return crop["label"] + " GROWING"
			2:
				return "[F] HARVEST " + crop["label"]
	if info["species"] == "moonwell":
		if not CultivationState.is_night(GameState.clock):
			return "MOONWELL OPENS AT NIGHT"
		if _bloom < .99:
			return "MOONWELL OPENING"
	if not state.wild_ready(id, info["species"], GameState.clock):
		return "SEEDS GROWING"
	var kind: String = state.config["wild"][info["species"]]["crop"]
	return "[F] COLLECT " + GameState.ITEMS[state.config["crops"][kind]["seed"]]["name"]


func _unhandled_input(event: InputEvent) -> void:
	nearest = _nearest()
	if event.is_echo() or nearest.is_empty() or _release_guard or not event.is_action_pressed("interact"):
		return
	var info: Dictionary = targets[nearest]
	if info["type"] == "repair":
		# The ordinary multitool job owns equipped F/X; it plays use_* and the scan beam.
		if _player.tool_state == Player.Tool.READY:
			return
		Audio.play("ui_deny")
		_release_guard = true
		_tool.cultivation_suppressed = true
		get_viewport().set_input_as_handled()
		return
	var success := false
	match info["type"]:
		"bed":
			success = state.harvest(nearest, GameState.clock) if state.stage(nearest, GameState.clock) == 2 else state.plant(nearest, GameState.clock)
		"wild":
			if info["species"] != "moonwell" or _bloom >= .99:
				success = state.gather(nearest, info["species"], GameState.clock)
	var at := _terrain.to_screen(point(info["world"]), _terrain.height_at(point(info["world"])))
	Audio.play("repair_done" if success and info["type"] == "repair" else "gather_pop" if success else "ui_deny", at)
	if not success:
		_notice = "BACKPACK FULL" if _would_fill_bag(nearest) else _prompt(nearest)
		_notice_left = 1.5
	_tool.cancel_work()
	_release_guard = true
	_tool.cultivation_suppressed = true
	get_viewport().set_input_as_handled()
	_changed()


## Register only the reachable repair, so the tool cannot scan through a door/modal or
## choose another nursery system. Its existing fix job owns timing, pose, beam and sound.
func _sync_fixable() -> void:
	if not _fixable.is_empty():
		state.repair_progress[_fix_id] = float(_fixable["progress"])
	var eligible: bool = not nearest.is_empty() and targets[nearest]["type"] == "repair"
	eligible = eligible and GameState.story.nursery_awake
	eligible = eligible and _player.tool_state == Player.Tool.READY and not _release_guard
	if not eligible:
		_clear_fixable()
		return
	if _fix_id != nearest:
		_clear_fixable()
		_fix_id = nearest
		_fixable = {"world": point(targets[nearest]["world"]), "radius": 4.0,
				"head": Vector2.ZERO, "base": Vector2.ZERO}
		_tool.add_fixable(_fixable, _finish_repair.bind(nearest))
		_fixable["progress"] = float(state.repair_progress.get(nearest, 0.0))
	_place_fixable()


func _place_fixable() -> void:
	if _fixable.is_empty() or not targets.has(_fix_id):
		return
	var info: Dictionary = targets[_fix_id]
	var world := point(info["world"])
	var ground := _terrain.height_at(world)
	_fixable["world"] = world
	_fixable["base"] = _terrain.to_screen(world, ground).round()
	_fixable["head"] = _terrain.to_screen(world, ground + float(info["scan_height"])).round()


func _clear_fixable() -> void:
	if _fixable.is_empty():
		return
	state.repair_progress[_fix_id] = float(_fixable["progress"])
	if is_instance_valid(_tool):
		_tool.remove_fixable(_fixable)
	_fixable = {}
	_fix_id = ""


func _finish_repair(id: String) -> void:
	if state.repair(id):
		Audio.play("repair_done", _fixable["head"])
	_release_guard = true
	_tool.cultivation_suppressed = true


func _would_fill_bag(id: String) -> bool:
	var info: Dictionary = targets[id]
	if info["type"] == "wild" and state.wild_ready(id, info["species"], GameState.clock):
		if info["species"] == "moonwell" and _bloom < .99:
			return false
		var kind: String = state.config["wild"][info["species"]]["crop"]
		return not GameState.can_store_items(state.config["crops"][kind]["seed"], int(state.config["seed_handful"]))
	if info["type"] == "bed" and state.stage(id, GameState.clock) == 2:
		var crop: Dictionary = state.config["crops"][info["kind"]]
		return not GameState.can_store_items(crop["fruit"], int(crop["yield"]))
	return false


func _changed() -> void:
	_update_frames()
	_last_prompt = ""
	queue_redraw()


func _draw() -> void:
	if nearest.is_empty() or _last_prompt.is_empty() or not targets.has(nearest):
		return
	var info: Dictionary = targets[nearest]
	var anchor := _terrain.to_screen(point(info["world"]), _terrain.height_at(point(info["world"]))) + Vector2(0., 10.)
	var width := PixelFont.width(_last_prompt) + 8
	var box := Rect2((anchor - Vector2(roundf(width / 2.), 0.)).round(), Vector2(width, 11))
	var clear_position := SurvivalHUD.plate_position(self, box)
	if clear_position != box.position and (visuals.has(nearest) or info["type"] == "repair"):
		# Prefer above the native plant to pushing a long prompt down behind the hotbar.
		var upper := box
		if visuals.has(nearest):
			var visual := visuals[nearest] as CropVisual
			upper.position.y = roundf(visual.position.y + visual.sprite.offset.y - box.size.y - 3.)
		else:
			upper.position.y = roundf(anchor.y - float(info["scan_height"]) * _terrain.px_per_unit - box.size.y - 13.)
		if SurvivalHUD.plate_position(self, upper) == upper.position:
			clear_position = upper.position
	box.position = clear_position
	draw_rect(box, DARK)
	PixelFont.draw(self, box.position + Vector2(4, 3), _last_prompt, WHITE)


func boards() -> Array:
	var result := []
	var view := Rect2(_player.camera.get_screen_center_position() - _player.camera.get_viewport_rect().size / _player.camera.zoom * .5,
			_player.camera.get_viewport_rect().size / _player.camera.zoom).grow(120.)
	for visual in visuals.values():
		if view.has_point((visual as CropVisual).position):
			result.append_array((visual as CropVisual).boards())
	return result


func _exit_tree() -> void:
	_clear_fixable()
	if is_instance_valid(_tool):
		_tool.cultivation_suppressed = false
