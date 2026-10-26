class_name NurseryCleanup
extends Node
## Removable native soil/leaves/tray chips on nursery or main-base floors. StoryState owns fractions
## across views, airlocks and rescue. UNIT advances a pile only while vacuuming in reach;
## the four baked stages shrink progressively, and complete piles disappear permanently.
const ART := "res://assets/maps/nursery_interior/cleanup/cleanup.json"
const BASE_ART := "res://assets/maps/base_interior/cleanup/cleanup.json"
var sites: Array = []
var visuals: Array[CropVisual] = []
var clean_seconds := 4.5
var _terrain: MapTerrain

func setup(terrain: MapTerrain, actors: Node2D, art_path := ART) -> void:
	_terrain = terrain
	var data := ViewData.get_json(art_path)
	sites = data["sites"]
	clean_seconds = float(data["clean_seconds"])
	for site in sites:
		var visual := CropVisual.new()
		actors.add_child(visual)
		visual.setup(site["views"][terrain.heading], art_path.get_base_dir(), terrain, point(site), false)
		visuals.append(visual)
	load_view()

func point(site: Dictionary) -> Vector2:
	return Vector2(site["world"][0], site["world"][1])

func progress(index: int) -> float:
	return float(GameState.story.cleanup_progress.get(sites[index]["id"], 0.))

func done(index: int) -> bool:
	return progress(index) >= 1.

func all_clean() -> bool:
	for index in sites.size():
		if not done(index): return false
	return true

func advance(index: int, seconds: float, bot_world: Vector2) -> void:
	if bot_world.distance_to(point(sites[index])) > 6. or seconds <= 0.: return
	GameState.story.cleanup_progress[sites[index]["id"]] = minf(1., progress(index) + seconds / clean_seconds)
	_sync(index)

func _sync(index: int) -> void:
	visuals[index].visible = not done(index)
	visuals[index].set_frame(mini(3, floori(progress(index) * 4.)))

func load_view() -> void:
	for index in sites.size():
		visuals[index].set_view(sites[index]["views"][_terrain.heading])
		_sync(index)

func refresh_window() -> void:
	for visual in visuals: visual.refresh_window()

func boards() -> Array:
	var result := []
	for visual in visuals:
		if visual.visible: result.append_array(visual.boards())
	return result
