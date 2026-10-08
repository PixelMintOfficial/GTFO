class_name SurvivalHUDLayout
extends RefCounted
## Small UI-only ConfigFile: normalized placement within available screen travel.
## Missing/invalid files fall back to top right. Save only when drag ends or on reset.
## Tests use a separate path and never overwrite the player's preference.

const PATH := "user://survival_hud.cfg"
const DEFAULT := Vector2(1, 0)
var normalized := DEFAULT
var path := PATH


func _init(file_path := PATH) -> void:
	path = file_path
	var settings := ConfigFile.new()
	if settings.load(path) == OK:
		var value: Variant = settings.get_value("layout", "position", DEFAULT)
		if value is Vector2 and is_finite(value.x) and is_finite(value.y):
			normalized = value.clamp(Vector2.ZERO, Vector2.ONE)


func save() -> Error:
	var settings := ConfigFile.new()
	settings.set_value("layout", "position", normalized)
	return settings.save(path)


func reset() -> Error:
	normalized = DEFAULT
	return save()
