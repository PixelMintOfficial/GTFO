extends Node
## Regression for sealing a storage pane: its sunlight beam and illuminated dust must stop
## immediately, including its baked floor light, camera turns, machine variants and airlocks.
## Also checks the cleared cargo route and real reflective pickups after the art rebuild.

var checks := 0
var failures := 0


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("WINDOW RESTORE TEST: " + label)


func _ready() -> void:
	GameState.heading = 0
	GameState.intro_done = true
	await get_tree().process_frame
	var room := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child(room)
	await get_tree().process_frame
	var before: int = room.fx._shafts.size()
	check(before == 2, "both unsealed sun-facing panes cast beams")
	var original_sun: Image = room.terrain.sun_mask.get_image()
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(room.terrain.view_json))
	var shaft: Dictionary = meta["fx"]["shafts"].filter(func(s: Dictionary) -> bool: return s["pane"] == "crescent")[0]
	var hull := PackedVector2Array()
	for p in shaft["hull"]:
		hull.append(Vector2(p[0], p[1]))
	var pane_bottom := 0
	for pane: Dictionary in room.cracks.panes:
		if pane["id"] == "crescent":
			var texture := load(room.terrain.view_json.get_base_dir().path_join(pane["patch"]["file"])) as Texture2D
			pane_bottom = int(pane["patch"]["position"][1]) + texture.get_height()
	room.cracks.fix("crescent")
	check(room.fx._shafts.size() == before - 1, "sealed crescent stops its beam and dust immediately")
	var sealed_sun: Image = room.terrain.sun_mask.get_image()
	var floor_light_removed := false
	for y in range(pane_bottom + 8, sealed_sun.get_height()):
		for x in sealed_sun.get_width():
			if Geometry2D.is_point_in_polygon(Vector2(x, y), hull) and original_sun.get_pixel(x, y).r - sealed_sun.get_pixel(x, y).r > .2:
				floor_light_removed = true
				break
		if floor_light_removed:
			break
	check(floor_light_removed, "sealed aperture removes baked sunlight well below the pane, on the floor")
	for at: Vector2 in [Vector2(-30, 480), Vector2(-24, 474), Vector2(-36, 472)]:
		check(room.cracks.box.fits(at), "cargo footprint fits through former barrel cluster at %s" % at)
	var glass: WorldProp = room.multitool.find_prop("glass")
	var variant := glass._variant_frame
	var shine := glass.sprite.frame
	glass._process(.2)
	check(glass.sprite.frame != shine and glass._variant_frame == variant, "glass reflections animate without changing the pickup variant")
	for heading in 4:
		room._apply_view(heading, Vector2.DOWN)
		check(room.fx._shafts.size() == 1, "sealed crescent beam stays absent in view %d" % heading)
		check(glass._variant_frame == variant, "reflective glass retains variant through view %d" % heading)
	room.cracks.fix("burst")
	check(room.fx._shafts.is_empty() and room.fx._motes.is_empty(), "sealing both sunny panes leaves no beams or illuminated dust")
	room.cracks.fix("gash")
	for mask in 4:
		room.terrain.replace_variant(room._repair_map(mask))
		for heading in 4:
			room._apply_view(heading, Vector2.DOWN)
			check(room.fx._shafts.is_empty() and room.fx._motes.is_empty(), "sealed beams stay absent in machine variant %d/view %d" % [mask, heading])
	room.queue_free()
	await get_tree().process_frame
	room = load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child(room)
	check(room.fx._shafts.is_empty() and room.fx._motes.is_empty(), "airlock re-entry retains sealed panes and no beams")
	print("WINDOW RESTORE TESTS: %d checks, %d failures" % [checks, failures])
	await Audio.quit(1 if failures else 0)
