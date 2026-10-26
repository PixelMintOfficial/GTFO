class_name WindowCracks
extends Node2D
## Storage's three smashed panes, and the cargo box you stand on to reach them. Two are in the wall
## you come in facing; the third is in the wall behind you, cut away in that view: turn the camera
## (G / H) to find it. Lift the box with the tool, set it down under a pane and jump on: it takes
## your weight with a crack - once for each pane, and not again until that pane is mended. When
## the last pane is mended with you standing on it, the box gives way: you go down with it, and
## the ration packs inside spill across the floor, to be gathered with the tool.
##
## Landing only wears the box. The glass puzzle calls fix(id) after its final sealing scan;
## only all three completed repairs can trigger the collapse and ration spill.
##
## State: GameState.window_repair (WindowRepair). Data: base_interior.json -> window_cracks (where
## to stand under each pane, where this view draws it); interior_props.json -> the cargo_box object
## (its footprint, top and contents). Drawn here: chips and dust as the box cracks and bursts, and
## a ring of light where a pane is mended.
## window_restorations supplies the exact combined room colours and lighting masks for sealed
## panes. Completing a scan also removes that hole's live shaft/dust from InteriorFX.
## Paired no_sun pixels follow sealed panes and partial scans, keeping nighttime light separate
## from the daylight image through camera turns, machine swaps and scene changes.
## With every pane mended, all three storage-dome holes outside are mended too:
## GameState.window_repair.dome_mended = "base", drawn on the overworld by DomeFX.
## State changes from the F1 toggles restore/reopen panes and their lighting immediately.

## How near the spot under a pane you must be, standing on the box (world units).
const NEAR := 20.0
## How long the box groans under you before it gives way, seconds.
const GROAN := 0.45
## How far the rations fly, world units from the box's middle: clear of its burst walls.
const SPILL := Vector2(27.0, 33.0)
const FIX := Color("#7fd8ff")                          # the multitool's fix colour
const STEEL := [Color("#3d3c58"), Color("#62627f"), Color("#9496b4")]
const DUST := Color("#c08868")

## This view's panes: {id, world: Vector2 (where to stand under it), hole: Vector2 (the wall under
## it), px: Vector2 (where this view draws it), seen: bool (this view leaves its wall standing)}.
var panes: Array[Dictionary] = []
var box: WorldProp
var repair: WindowRepair
var _player: Player
var _tool: Multitool
var _terrain: MapTerrain
var _groan := -1.0                                     # seconds into the groan; -1 when not breaking
var _controls_were := true
var _shake := 0.0
var _parts: Array = []                                 # [pos, vel, age, life, color, size, gravity, dust]
var _rings: Array = []                                 # [pos, age, life]
var _glow: Node2D
var _discs := {}
var panel: GlassRepairUI
var nearest := ""
var _catalog: Dictionary
var _active := ""
var _release_guard := false
var _panel_controls := true
var _patches: Dictionary = {}
var _map: Sprite2D
var _map_source := ""
var _sun_source := ""
var _light_source := ""
var _no_sun_source := ""
var _restorations: Array = []
var _prompt: Node2D
var _dome := ""                                        # the base room outside, on the overworld
var _composed_fixed := {}


func setup(meta: Dictionary, player: Player, tool: Multitool, terrain: MapTerrain) -> void:
	_player = player
	_tool = tool
	_terrain = terrain
	process_mode = Node.PROCESS_MODE_ALWAYS
	repair = GameState.window_repair
	_map = get_parent().get_node("Map")
	_catalog = JSON.parse_string(FileAccess.get_file_as_string(GlassRepairUI.DIR + "catalog.json"))
	panel = GlassRepairUI.new()
	add_child(panel)
	panel.closed.connect(_panel_closed)
	_prompt = Node2D.new()
	_prompt.set_meta("dn_unlit", true)
	_prompt.draw.connect(_draw_prompt)
	add_child(_prompt)
	z_index = 29                                       # over the actors, under the tool's own light
	_glow = Node2D.new()
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = add
	_glow.draw.connect(_draw_glow)
	add_child(_glow)
	_dome = meta["rooms"]["storage"].get("dome", "")
	set_view(meta)
	_mend_dome()
	repair.changed.connect(_repair_changed)
	box = tool.find_prop("cargo_box")
	if box == null:
		return
	if repair.box_world != null:
		box.place(repair.box_world)
	if repair.box_broken:
		_wreck()
	else:
		box.sprite.frame = mini(repair.damage(), box.sprite.hframes - 2)
	player.landed.connect(_landed)


## The camera turned: where this view draws the panes.
func set_view(meta: Dictionary) -> void:
	panes.clear()
	for p in meta.get("window_cracks", []):
		panes.append({"id": p["id"], "world": Vector2(p["world"][0], p["world"][1]),
				"hole": Vector2(p["hole"][0], p["hole"][1]), "px": Vector2(p["px"][0], p["px"][1]), "seen": p["seen"],
				"reach_min_height": p["reach_min_height"], "patch": p.get("patch", {})})
	for sprite in _patches.values():
		sprite.queue_free()
	_patches.clear()
	_map_source = _terrain.view_json.get_base_dir().path_join(meta["image"])
	_sun_source = _terrain.view_json.get_base_dir().path_join(meta["game"]["sun_png"])
	_light_source = _terrain.view_json.get_base_dir().path_join(meta["game"]["light_png"])
	_no_sun_source = _terrain.view_json.get_base_dir().path_join(meta["game"]["no_sun_png"])
	_restorations = meta.get("window_restorations", [])
	for pane in panes:
		var info: Dictionary = pane["patch"]
		if info.is_empty() or repair.fixed.has(pane["id"]):
			continue
		var dir := _terrain.view_json.get_base_dir()
		var sprite := Sprite2D.new()
		sprite.centered = false
		sprite.texture = load(dir.path_join(info["file"]))
		sprite.position = Vector2(info["position"][0], info["position"][1])
		var material := ShaderMaterial.new()
		material.shader = preload("res://shaders/window_patch.gdshader")
		material.set_shader_parameter("height_map", load(dir.path_join(info["height"])))
		material.set_shader_parameter("sun_mask", load(dir.path_join(info["sun"])))
		material.set_shader_parameter("light_mask", load(dir.path_join(info["light"])))
		material.set_shader_parameter("no_sun_map", load(dir.path_join(info["no_sun"])))
		material.set_shader_parameter("has_no_sun", true)
		material.set_shader_parameter("map_size", _terrain.map_size)
		material.set_shader_parameter("map_position", sprite.position)
		material.set_shader_parameter("patch_size", sprite.texture.get_size())
		sprite.material = material
		_map.add_child(sprite)                        # on the wall, behind FX and actors
		_patches[pane["id"]] = sprite
	_compose_fixed()
	_composed_fixed = repair.fixed.duplicate()
	_parts.clear()
	_rings.clear()


## Standing on the box (not jumping off it).
func on_box() -> bool:
	return (box != null and not box.gone and box.lift < 1.0 and box.top > 0.0 and not _player.is_airborne()
			and _player.height_above_floor() >= box.top - 1.0 and box.covers(_player.world_pos, 2.0))


## The pane a world point is under (on the box), or "".
func pane_near(p: Vector2) -> String:
	var best := ""
	var near := NEAR
	for pane in panes:
		var d: float = p.distance_to(pane["world"])
		if d < near:
			best = pane["id"]
			near = d
	return best


## Mend pane `id` (what the real fix job will call). Once the last is mended with you standing on
## the box, the box gives way (see _process).
func fix(id: String) -> void:
	if not repair.fix(id):
		return
	for pane in panes:
		if pane["id"] == id:
			Audio.play("pane_mend", pane["px"])
			if pane["seen"]:
				_rings.append([pane["px"], 0.0, 0.6])


## Fixing normally or through F1 shares the same room pixels and lighting. Reopening panes
## rebuilds scan sprites and shafts; cargo-box changes alone do not redraw the room.
func _repair_changed() -> void:
	if repair.fixed == _composed_fixed:
		return
	var reopened := false
	for id in _composed_fixed:
		if not repair.fixed.has(id):
			reopened = true
	var fx := get_parent().get_node("InteriorFX") as InteriorFX
	if reopened:
		set_view(ViewData.get_json(_terrain.view_json))
		fx.load_view(_terrain.view_json)
	else:
		_compose_fixed()
		for id in repair.fixed:
			fx.seal_window(id)
			if _patches.has(id):
				_patches[id].queue_free()
				_patches.erase(id)
		_composed_fixed = repair.fixed.duplicate()
	_mend_dome()


## Every pane mended: all three main-base domes outside have whole glass (DomeFX draws it).
func _mend_dome() -> void:
	if _dome != "" and repair.all_fixed(_pane_ids()):
		repair.dome_mended = "base"


## Compose the complete sealed room state, including its colour, sun and light replacements,
## then paused scan rows. The live shader adds new rows while scanning. Camera swings and
## machine variant swaps receive the same fully restored map, rather than a hole-shaped patch.
func _compose_fixed() -> void:
	var image := (load(_map_source) as Texture2D).get_image().duplicate() as Image
	image.convert(Image.FORMAT_RGBA8)
	var sun := (load(_sun_source) as Texture2D).get_image().duplicate() as Image
	var light := (load(_light_source) as Texture2D).get_image().duplicate() as Image
	var no_sun := (load(_no_sun_source) as Texture2D).get_image().duplicate() as Image
	no_sun.convert(Image.FORMAT_RGBA8)
	var dir := _terrain.view_json.get_base_dir()
	for state: Dictionary in _restorations:
		var fixed: Array = state["panes"]
		if fixed.size() != repair.fixed.size() or not fixed.all(func(id: String) -> bool: return repair.fixed.has(id)):
			continue
		if state.has("file"):
			var replacement := (load(dir.path_join(state["file"])) as Texture2D).get_image()
			replacement.convert(Image.FORMAT_RGBA8)
			var at := Vector2i(state["position"][0], state["position"][1])
			var rect := Rect2i(Vector2i.ZERO, replacement.get_size())
			image.blend_rect(replacement, rect, at)
			var night_patch := (load(dir.path_join(state["no_sun"])) as Texture2D).get_image()
			night_patch.convert(Image.FORMAT_RGBA8)
			no_sun.blend_rect(night_patch, rect, at)
			sun.blit_rect((load(dir.path_join(state["sun"])) as Texture2D).get_image(), rect, at)
			light.blit_rect((load(dir.path_join(state["light"])) as Texture2D).get_image(), rect, at)
		break
	for pane in panes:
		var info: Dictionary = pane["patch"]
		if repair.fixed.has(pane["id"]):
			continue
		var progress := 0.0
		if repair.puzzles.has(pane["id"]):
			progress = repair.puzzles[pane["id"]].scan
		if progress <= 0.0 or info.is_empty():
			continue
		var patch := (load(_terrain.view_json.get_base_dir().path_join(info["file"])) as Texture2D).get_image().duplicate() as Image
		patch.convert(Image.FORMAT_RGBA8)
		var night_patch := (load(dir.path_join(info["no_sun"])) as Texture2D).get_image().duplicate() as Image
		night_patch.convert(Image.FORMAT_RGBA8)
		if progress < 1.0:
			var height := (load(_terrain.view_json.get_base_dir().path_join(info["height"])) as Texture2D).get_image()
			for y in patch.get_height():
				for x in patch.get_width():
					if height.get_pixel(x, y).r > progress:
						patch.set_pixel(x, y, Color.TRANSPARENT)
						night_patch.set_pixel(x, y, Color.TRANSPARENT)
		image.blend_rect(patch, Rect2i(Vector2i.ZERO, patch.get_size()), Vector2i(info["position"][0], info["position"][1]))
		no_sun.blend_rect(night_patch, Rect2i(Vector2i.ZERO, patch.get_size()), Vector2i(info["position"][0], info["position"][1]))
	_terrain.map_texture = ImageTexture.create_from_image(image)
	_map.texture = _terrain.map_texture
	_terrain.sun_mask = ImageTexture.create_from_image(sun)
	_terrain.light_mask = ImageTexture.create_from_image(light)
	_terrain.no_sun_map = ImageTexture.create_from_image(no_sun)
	(get_parent().get_node("DayNight") as DayNight).set_masks(_terrain.light_mask, _terrain.sun_mask, _terrain.no_sun_map)


func in_reach(id: String) -> bool:
	for pane in panes:
		if pane["id"] != id:
			continue
		return (pane["seen"] and _player.world_pos.distance_to(pane["world"]) < NEAR
				and _player.height_above_floor() >= float(pane["reach_min_height"])
				and _player.height_above_floor() < 36.0 and (_player.is_airborne() or on_box()))
	return false


func open_window(id: String) -> bool:
	if panel.opened or not _catalog.has(id) or repair.fixed.has(id) or not in_reach(id) or get_tree().paused or _player.puppet or not _player.controls_enabled or _player.turning or _player.tool_state != Player.Tool.READY or _tool._lifted != null or _tool.inventory_suppressed or _tool.repair_suppressed:
		return false
	if GameState.item_count("glass") < int(_catalog[id]["cost"]):
		Audio.play("ui_deny")
		return false
	_tool.cancel_work()
	_tool.window_suppressed = true
	_panel_controls = _player.controls_enabled
	_player.controls_enabled = false
	_active = id
	_tool.window_panel_open = true
	panel.open(repair.puzzle_for(id, _catalog[id]))
	return true


func _panel_closed() -> void:
	Audio.release("window:scan")
	_player.work_target = null
	_player.controls_enabled = _panel_controls
	_release_guard = true
	_tool.window_suppressed = true
	_tool.window_panel_open = false
	_active = ""
	_compose_fixed()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_echo() and event.is_action_pressed("interact") and nearest != "" and not _release_guard:
		open_window(nearest)
		get_viewport().set_input_as_handled()


func _update_panel(delta: float) -> void:
	nearest = ""
	if _release_guard and not Input.is_action_pressed("interact") and not Input.is_action_pressed("tool_use"):
		_release_guard = false
	if panel.opened:
		if not in_reach(_active) or get_tree().paused or _player.puppet or GameState.survival.dead:
			panel.close()
		else:
			var puzzle := panel.puzzle
			if puzzle.scanning():
				for pane in panes:
					if pane["id"] == _active:
						_player.work_target = pane["hole"]
						Audio.loop("beam_fix", "window:scan", pane["px"])
				if puzzle.advance(delta) and GameState.consume_item("glass", int(puzzle.definition["cost"])):
					var completed := _active
					puzzle.done = true
					Audio.release("window:scan")
					_player.work_target = null
					# Release the modal BEFORE the collapse snapshots player controls.
					if repair.fixed.size() == panes.size() - 1:
						panel.close()
					fix(completed)
	else:
		if not get_tree().paused and _player.controls_enabled and not _player.puppet and not _player.turning and not _tool.inventory_suppressed and not _tool.repair_suppressed and not _tool.suppressed and _tool._lifted == null:
			for pane in panes:
				if not repair.fixed.has(pane["id"]) and in_reach(pane["id"]):
					nearest = pane["id"]
					break
	_tool.window_suppressed = panel.opened or _release_guard or (nearest != "" and _player.tool_state == Player.Tool.READY)
	for id in _patches:
		var progress := 0.0
		if repair.puzzles.has(id):
			progress = repair.puzzles[id].scan
		_patches[id].visible = progress > 0.0
		_patches[id].material.set_shader_parameter("scan", progress)


func _exit_tree() -> void:
	Audio.release("window:scan")
	if is_instance_valid(_tool):
		_tool.window_suppressed = false
		_tool.window_panel_open = false
	if is_instance_valid(_player) and panel != null and panel.opened:
		_player.controls_enabled = _panel_controls
		_player.work_target = null


## Test hooks: set the box down under pane `id`, as near the wall as it fits. Returns where.
func place_box_under(id: String) -> Vector2:
	for pane in panes:
		if pane["id"] != id:
			continue
		var spot: Vector2 = pane["world"]
		var inward: Vector2 = (spot - (pane["hole"] as Vector2)).normalized()
		while not box.fits(spot) and spot.distance_to(pane["world"]) < 40.0:
			spot += inward
		box.place(spot)
		repair.box_world = spot
		return spot
	return box.world


func _landed(_impact: float) -> void:
	if box == null or repair.box_broken or not on_box():
		return
	Audio.play("cargo_land", _top_px())                # steel under the boots, over the landing thud
	var pane := pane_near(_player.world_pos)
	if pane == "":
		return
	if repair.crack_box(pane):
		_crack()


func _process(delta: float) -> void:
	if box == null or _player == null:
		return
	_update_panel(delta)
	if get_tree().paused:
		_prompt.queue_redraw()
		return
	if not repair.box_broken:
		if box.lift <= 0.0 and not box.gone:
			repair.box_world = box.world                # wherever it was last set down
		if _groan < 0.0 and not panel.opened and _player.controls_enabled and repair.all_fixed(_pane_ids()) and on_box():
			_start_groan()
	if _groan >= 0.0:
		_groan += delta
		box.sprite.position.x = 1.0 if fmod(_groan, 0.08) < 0.04 else -1.0
		if _groan >= GROAN:
			_give_way()
	elif _shake > 0.0:
		_shake -= delta
		box.sprite.position.x = 0.0 if _shake <= 0.0 else (1.0 if fmod(_shake, 0.06) < 0.03 else 0.0)
	var i := 0
	while i < _parts.size():
		var q: Array = _parts[i]
		q[2] += delta
		if q[2] >= q[3]:
			_parts.remove_at(i)
			continue
		q[1] += Vector2(0, q[6]) * delta
		if q[7]:
			q[1] *= exp(-2.5 * delta)
		q[0] += q[1] * delta
		i += 1
	i = 0
	while i < _rings.size():
		_rings[i][1] += delta
		if _rings[i][1] >= _rings[i][2]:
			_rings.remove_at(i)
			continue
		i += 1
	queue_redraw()
	_glow.queue_redraw()
	_prompt.queue_redraw()


func _pane_ids() -> Array:
	var ids := []
	for pane in panes:
		ids.append(pane["id"])
	return ids


## The box's top on screen, where it takes your weight.
func _top_px() -> Vector2:
	return box.global_position + Vector2(0, -box.top * _terrain.px_per_unit)


## A crack opening under your boots.
func _crack() -> void:
	box.sprite.frame = mini(repair.damage(), box.sprite.hframes - 2)
	var c := _top_px()
	Audio.play("cargo_crack", c)
	_player.camera.shake(1.2, 0.2)
	_shake = 0.25
	_chips(c, 10, 70.0)
	_dust(c, 5)


func _start_groan() -> void:
	_groan = 0.0
	_controls_were = _player.controls_enabled
	_player.controls_enabled = false
	_tool.cancel_work()
	box.sprite.frame = box.sprite.hframes - 2
	Audio.play("cargo_groan", _top_px())


## The box bursts: you go down with it, and the rations inside spill out.
func _give_way() -> void:
	_groan = -1.0
	var c := box.center_px()
	repair.break_box()
	_wreck()
	_player.controls_enabled = _controls_were
	_player.collapse()
	Audio.play("cargo_burst", c)
	_player.camera.shake(2.6, 0.4)
	_chips(c, 24, 110.0)
	_dust(box.global_position, 10)
	var contents: Dictionary = box.get_meta("contents", {})
	var n := int(contents.get("count", 0))
	for k in n:
		var to := box.world
		for attempt in 9:                              # round to open floor if a wall is in the way
			var a := TAU * (k + randf_range(0.2, 0.8)) / n + attempt * 0.7
			var p := box.world + Vector2(cos(a), sin(a)) * randf_range(SPILL.x, SPILL.y)
			if _terrain.surface(p) == MapTerrain.Surface.WALK:
				to = p
				break
		_tool.spill(contents["kind"], box.world, to, k % 3, "%s/spill/%d" % [box.get_meta("inventory_id", "box"), k],
				3.0, k * 0.07, "ration_land", 1.0, 0.0)


## What is left of the box: lies where it broke, nothing to stand on, nothing for the tool.
func _wreck() -> void:
	box.sprite.position.x = 0.0
	box.sprite.frame = box.sprite.hframes - 1
	box.job = ""
	box.set_top(0.0)


func _chips(at: Vector2, n: int, speed: float) -> void:
	for k in n:
		var v := Vector2(randf_range(-1, 1), randf_range(-1.4, -0.2)).normalized() * randf_range(speed * 0.4, speed)
		_parts.append([at + Vector2(randf_range(-6, 6), randf_range(-2, 2)), v, 0.0, randf_range(0.4, 0.8),
				STEEL[k % 3], 1 + k % 2, 220.0, false])


func _dust(at: Vector2, n: int) -> void:
	for k in n:
		var a := TAU * k / n
		_parts.append([at + Vector2(cos(a) * 6, sin(a) * 2), Vector2(cos(a), sin(a) * 0.45) * randf_range(12, 24),
				0.0, randf_range(0.6, 0.9), DUST, 2, -4.0, true])


func _draw_prompt() -> void:
	if nearest != "" and not panel.opened:
		var label := "F - REPAIR WINDOW" if GameState.item_count("glass") >= 6 else "NEED 6 GLASS"
		if _player.tool_state != Player.Tool.READY:
			label = "T - EQUIP MULTITOOL"
		var p := _player.global_position + Vector2(-PixelFont.width(label) / 2.0, -65)
		_prompt.draw_rect(Rect2(p - Vector2(3, 3), Vector2(PixelFont.width(label) + 6, 11)), Color("#22182c"))
		PixelFont.draw(_prompt, p.round(), label, Color("#efb950"))


func _draw() -> void:
	for q in _parts:
		var k: float = q[2] / q[3]
		if q[7]:                                       # dust: a soft puff, thinning
			_disc((q[0] as Vector2).round(), int(round(q[5] + k * 3.0)), Color(q[4], ceilf((1.0 - k) * 3.0) / 3.0 * 0.6))
		else:                                          # a chip of the box's steel
			draw_rect(Rect2((q[0] as Vector2).round(), Vector2(q[5], q[5])), q[4])


## A mended pane: a ring of the fix colour opening round it.
func _draw_glow() -> void:
	for r in _rings:
		var k: float = r[1] / r[2]
		var rad := 6.0 + 14.0 * k
		var n := int(TAU * rad / 1.5) + 6
		for j in n:
			var a := TAU * j / n
			_glow.draw_rect(Rect2(((r[0] as Vector2) + Vector2(cos(a) * rad, sin(a) * rad * 0.5)).round(), Vector2.ONE),
					Color(FIX, 1.0 - k))


func _disc(center: Vector2, r: int, col: Color) -> void:
	r = maxi(r, 0)
	if not _discs.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				if Vector2(x - r, y - r).length() <= r + 0.35:
					img.set_pixel(x, y, Color.WHITE)
		_discs[r] = ImageTexture.create_from_image(img)
	draw_texture(_discs[r], center - Vector2(r, r), col)
