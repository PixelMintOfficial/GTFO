class_name SolarFieldState
extends RefCounted
## Session solar controls and evaluated routes. GameState owns this through scene changes.
## Controls are explicit mutations; evaluation runs only after a change, never every frame.
## All three complete authored paths are required for electrical output. Feeds start closed.
## SOLAR_FIELD_LAYOUT=v1 retains the previous 4/5/4 layout for comparisons.
## bind_world supplies canonical terrain collisions/off-screen ray extents when entering the field.

signal changed

const DATA := "res://data/solar_field.json"
const DATA_V1 := "res://data/solar_field_v1.json"

var field: Dictionary
var mirrors: Array[Dictionary] = []
var orientations: Dictionary = {}
var feeds: Array[bool] = [false, false, false]
var routes: Array[Dictionary] = []
var _world: SolarWorldGeometry


func _init() -> void:
	field = JSON.parse_string(FileAccess.get_file_as_string(DATA_V1 if OS.get_environment("SOLAR_FIELD_LAYOUT") == "v1" else DATA))
	for group in field["routes"].size():
		var route: Dictionary = field["routes"][group]
		for index in route["mirrors"].size():
			var world := SolarOptics.point(route["mirrors"][index])
			var id: String = route["id"] + str(index + 1)
			var before := SolarOptics.point(route["source"] if index == 0 else route["mirrors"][index - 1])
			var after := SolarOptics.point(field["collector"]["world"] if index + 1 == route["mirrors"].size() else route["mirrors"][index + 1])
			var angle := SolarOptics.alignment(world - before, after - world)
			orientations[id] = posmod(angle + 1 + (index + group * 3) % 7, 8)
			var mirror := {"id": id, "world": world, "group": group, "index": index,
					"elevation": SolarOptics.mirror_elevation(route, index)}
			mirror["mount"] = SolarOptics.mount(field, mirror)
			mirrors.append(mirror)
	_evaluate()


func bind_world(terrain: MapTerrain) -> void:
	_world = SolarWorldGeometry.new(terrain)
	_evaluate()


func rotate(id: String) -> bool:
	if not orientations.has(id):
		return false
	orientations[id] = posmod(int(orientations[id]) + 1, 8)
	_evaluate()
	changed.emit()
	return true


func toggle_feed(group: int) -> bool:
	if group < 0 or group >= feeds.size():
		return false
	feeds[group] = not feeds[group]
	_evaluate()
	changed.emit()
	return true


func connected_count() -> int:
	var count := 0
	for route in routes:
		if route["connected"]:
			count += 1
	return count


func supplies_power() -> bool:
	return connected_count() == 3


## Count this channel's unique reflectors, rather than repeated or cross-channel bounces.
func lit_count(group: int) -> int:
	var count := 0
	var route: Dictionary = field["routes"][group]
	for index in route["mirrors"].size():
		if routes[group]["hits"].has(route["id"] + str(index + 1)):
			count += 1
	return count


func _evaluate() -> void:
	routes.clear()
	for group in feeds.size():
		routes.append(SolarOptics.trace(field, mirrors, orientations, group, feeds[group], _world))
