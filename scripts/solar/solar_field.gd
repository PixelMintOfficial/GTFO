class_name SolarField
extends Node2D
## World adapter for the solar field. Uses WorldProp for generated equipment/depth/shadows;
## renders depth-tested optical meshes and a local three-channel receiver indicator.
## F/X activates feeds or rotates reflectors clockwise in reach. No modal or navigation
## HUD. Independent solar_suppressed ownership protects the multitool and release transitions.
## load_view redraws equipment/meshes without mutating SolarFieldState. Test hooks live in
## overworld.gd (--solar-at=ID, --solar-solved, --solar-active); tests drive real F/pad input.
## Reflector-owned depth-clipped replays share the entire world beam mesh. This preserves
## front/behind order at faces/posts without cropping rays or covering foreground actors.

const ART := "res://assets/maps/red_planet/solar_field.json"
const BEAM := preload("res://shaders/solar_beam.gdshader")
const DARK := Color("#22182c")
const WHITE := Color("#fbfbff")

var state: SolarFieldState
var nearest := ""
var equipment: Dictionary = {}
var _info: Dictionary
var _player: Player
var _tool: Multitool
var _terrain: MapTerrain
var _rays: Node2D
var _meshes: Array[MeshInstance2D] = []
var _impacts: Array[MeshInstance2D] = []
var _reflectors: Dictionary = {}
var _all_beams: Array[MeshInstance2D] = []
var _cable: MeshInstance2D
var _indicator := Vector2.ZERO
var _release_guard := false
var _last_power := 0
var fx: SolarFieldFX


func setup(player: Player, tool: Multitool, terrain: MapTerrain, actors: Node2D) -> void:
	_player = player
	_tool = tool
	_terrain = terrain
	state = GameState.solar_field
	state.bind_world(terrain)
	_info = JSON.parse_string(FileAccess.get_file_as_string(ART))
	process_priority = -20
	z_index = 50
	set_meta("dn_unlit", true)
	_rays = Node2D.new()
	_rays.name = "SolarBeams"
	_rays.set_meta("dn_unlit", true)
	get_parent().add_child(_rays)
	get_parent().move_child(_rays, get_parent().get_node("Map").get_index() + 1)
	for group in state.feeds.size():
		for width in SolarBeamVisuals.WIDTHS:
			var mesh := _beam_mesh(group, width)
			_rays.add_child(mesh)
			_meshes.append(mesh)
			var impact := _beam_mesh(group, width)
			_rays.add_child(impact)
			_impacts.append(impact)
		var route: Dictionary = state.field["routes"][group]
		_make_equipment(route["id"] + " SUN", SolarOptics.point(route["source"]), group, true, actors)
	for mirror in state.mirrors:
		_make_equipment(mirror["id"], mirror["world"], mirror["group"], false, actors)
	_cable = MeshInstance2D.new()
	var cable_material := ShaderMaterial.new()
	cable_material.shader = BEAM
	cable_material.set_shader_parameter("beam_color", Color("#4fc6b4"))
	_cable.material = cable_material
	_rays.add_child(_cable)
	_last_power = state.connected_count()
	state.changed.connect(_changed)
	fx = SolarFieldFX.new()
	_rays.add_child(fx)
	fx.setup(state, _terrain, _info, equipment)
	load_view()


func _make_equipment(id: String, world: Vector2, group: int, source: bool, actors: Node2D) -> void:
	var prop := WorldProp.new()
	prop.kind = "solar_feed" if source else "solar_mirror"
	prop.radius = 9.0 if source else 7.0
	prop.solid = true
	var entry := {"id": id, "prop": prop, "group": group, "source": source, "world": world}
	equipment[id] = entry
	prop.setup(_sheet(entry), 0, _terrain, _terrain.depth_map)
	actors.add_child(prop)
	prop.place(world)
	if not source:
		var reflector := SolarReflectorLight.new()
		prop.add_child(reflector)
		var mirror: Dictionary = state.mirrors.filter(func(m): return m["id"] == id)[0]
		reflector.setup(_terrain, prop, _art_sheet(entry), _meshes, state, mirror)
		_reflectors[id] = reflector
		_all_beams.append_array(reflector.meshes)


func _beam_mesh(group: int, width: float) -> MeshInstance2D:
	var mesh := MeshInstance2D.new()
	var mat := ShaderMaterial.new()
	mat.shader = BEAM
	var color := Color(state.field["routes"][group]["color"])
	color.a = .18 if width > 3.0 else .94
	mat.set_shader_parameter("beam_color", color)
	mesh.material = mat
	mesh.set_meta("width", width)
	mesh.set_meta("group", group)
	mesh.set_meta("dn_unlit", true)
	_all_beams.append(mesh)
	return mesh


## Generator-owned, reachable approach used by capture hooks and placement checks.
func interaction_point(id: String) -> Vector2:
	return SolarOptics.point(_info["stands"][id])


func _art_sheet(entry: Dictionary) -> Dictionary:
	var route_id: String = state.field["routes"][entry["group"]]["id"]
	var sheet: Dictionary = _info["sheets"][route_id]["source" if entry["source"] else "mirror"]
	if _info.get("special_mirrors", {}).has(entry["id"]):
		sheet = _info["special_mirrors"][entry["id"]][_terrain.heading]
	return sheet


func _sheet(entry: Dictionary) -> Dictionary:
	var sheet := _art_sheet(entry)
	return {"tex": load(ART.get_base_dir().path_join(sheet["file"])), "frames": sheet["frames"],
			"anchor": SolarOptics.point(sheet["anchor"])}


func load_view() -> void:
	_indicator = SolarOptics.point(_info["views"][_terrain.heading]["indicator_px"])
	for entry in equipment.values():
		(entry["prop"] as WorldProp).set_view(_sheet(entry), _terrain.depth_map)
		if not entry["source"]:
			(_reflectors[entry["id"]] as SolarReflectorLight).load_view(_art_sheet(entry))
	for mesh in _all_beams:
		var mat := mesh.material as ShaderMaterial
		mat.set_shader_parameter("depth_map", _terrain.depth_map)
		mat.set_shader_parameter("map_size", _terrain.map_size)
		mat.set_shader_parameter("depth_scale", _terrain.depth_scale)
	var cable_material := _cable.material as ShaderMaterial
	cable_material.set_shader_parameter("depth_map", _terrain.depth_map)
	cable_material.set_shader_parameter("map_size", _terrain.map_size)
	cable_material.set_shader_parameter("depth_scale", _terrain.depth_scale)
	var segments := []
	var cable: Array = state.field["cable"]
	for index in cable.size() - 1:
		segments.append([Vector3(cable[index][0], cable[index][1], 1.5), Vector3(cable[index + 1][0], cable[index + 1][1], 1.5)])
	_cable.mesh = SolarBeamVisuals.mesh(_terrain, segments, 1.5)
	fx.load_view()
	_refresh()


func _refresh() -> void:
	_cable.visible = state.supplies_power()
	fx.refresh()
	for group in state.routes.size():
		for layer in 2:
			var mesh := _meshes[group * 2 + layer]
			mesh.mesh = SolarBeamVisuals.mesh(_terrain, state.routes[group]["segments"], mesh.get_meta("width"))
			var impact := _impacts[group * 2 + layer]
			impact.mesh = SolarBeamVisuals.mesh(_terrain, _impact_segments(state.routes[group]), impact.get_meta("width"))
	for reflector in _reflectors.values():
		(reflector as SolarReflectorLight).refresh()
	queue_redraw()


## A tiny ground glint makes a physical stop readable even when it lands on flat soil.
func _impact_segments(route: Dictionary) -> Array:
	var segments := []
	if route["termination"] != "terrain":
		return segments
	var hit: Vector3 = route["segments"][-1][1]
	for side in 8:
		var a := Vector2(hit.x, hit.y) + Vector2.from_angle(side * TAU / 8)
		var b := Vector2(hit.x, hit.y) + Vector2.from_angle((side + 1) * TAU / 8)
		segments.append([Vector3(a.x, a.y, _terrain.height_at(a) + .2), Vector3(b.x, b.y, _terrain.height_at(b) + .2)])
	return segments


func _changed() -> void:
	var power := state.connected_count()
	if power > _last_power:
		Audio.play("repair_done" if power == 3 else "wire_connect", _indicator)
	_last_power = power
	_refresh()


func _can_interact() -> bool:
	return (_player.controls_enabled and not _player.puppet and not _player.turning
			and not _player.is_airborne() and not get_tree().paused
			and not _tool.inventory_suppressed and not _tool.suppressed
			and not _tool.repair_suppressed and not _tool.window_suppressed)


func _nearest() -> String:
	if not _can_interact():
		return ""
	var distance: float = state.field["reach"]
	var id := ""
	for key in equipment:
		if absf(_terrain.height_at(equipment[key]["world"]) - _terrain.height_at(_player.world_pos)) > 18:
			continue
		var d := _player.world_pos.distance_to(equipment[key]["world"])
		if d < distance:
			distance = d
			id = key
	return id


func _process(_delta: float) -> void:
	nearest = _nearest()
	if _release_guard and not Input.is_action_pressed("interact") and not Input.is_action_pressed("tool_use"):
		_release_guard = false
	_tool.solar_suppressed = not nearest.is_empty() or _release_guard
	for mesh in _all_beams:
		var group: int = mesh.get_meta("group")
		(mesh.material as ShaderMaterial).set_shader_parameter("daylight", DayNight.daylight * smoothstep(.6, 1.0, fx.deployment[group]))
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	nearest = _nearest()
	if event.is_echo() or nearest.is_empty() or _release_guard:
		return
	if event.is_action_pressed("interact"):
		var entry: Dictionary = equipment[nearest]
		if entry["source"]:
			state.toggle_feed(entry["group"])
			Audio.play("door_unseal" if state.feeds[entry["group"]] else "door_close", (entry["prop"] as Node2D).position)
		else:
			state.rotate(nearest)
			Audio.play("wire_turn", (entry["prop"] as Node2D).position)
		_tool.cancel_work()
		_release_guard = true
		_tool.solar_suppressed = true
		get_viewport().set_input_as_handled()


func _draw() -> void:
	if state == null:
		return
	var box := Rect2(_indicator - Vector2(51, 8), Vector2(102, 19))
	box.position = SurvivalHUD.plate_position(self, box)
	draw_rect(box.grow(1), DARK)
	draw_rect(box, Color("#151c2b"))
	var title := "SOLAR %d/3" % state.connected_count()
	PixelFont.draw(self, box.position + Vector2((102 - PixelFont.width(title)) / 2, 2).round(), title, WHITE)
	for group in state.routes.size():
		var color := Color(state.field["routes"][group]["color"])
		var segment := Rect2(box.position + Vector2(3 + group * 33, 10), Vector2(30, 6))
		draw_rect(segment, color.darkened(.75))
		if state.routes[group]["connected"]:
			draw_rect(segment, color)
		elif state.feeds[group]:
			draw_rect(Rect2(segment.position, Vector2(30 * float(state.lit_count(group)) / state.field["routes"][group]["mirrors"].size(), 6)), color.darkened(.35))
		PixelFont.draw(self, segment.position + Vector2(13, 1), state.field["routes"][group]["id"], WHITE)
	if nearest.is_empty():
		return
	var entry: Dictionary = equipment[nearest]
	var anchor := (entry["prop"] as Node2D).position + Vector2(0, 10)
	var text: String
	if entry["source"]:
		text = "[F] SHUT " if state.feeds[entry["group"]] else "[F] ACTIVATE "
		text += state.field["routes"][entry["group"]]["label"]
	else:
		text = "[F] TURN  " + nearest
	var width := PixelFont.width(text) + 8
	var position_px := anchor - Vector2(roundf(width / 2.0), 0)
	var plate := Rect2(position_px, Vector2(width, 11))
	plate.position = SurvivalHUD.plate_position(self, plate)
	draw_rect(plate, DARK)
	PixelFont.draw(self, plate.position + Vector2(4, 3), text, WHITE)


func _exit_tree() -> void:
	if is_instance_valid(_tool):
		_tool.solar_suppressed = false


## During the camera swing, optical segments stand in the existing relief's 3D world.
func beam_boards() -> Array:
	var out := []
	for group in state.routes.size():
		for segment in state.routes[group]["segments"]:
			var color := Color(state.field["routes"][group]["color"])
			color.a = DayNight.daylight
			out.append({"beam": segment, "color": color, "radius": SolarBeamVisuals.WIDTHS[1] / (2.0 * _terrain.px_per_unit)})
	return out
