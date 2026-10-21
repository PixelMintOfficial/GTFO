class_name PlayerProfile
extends RefCounted
## The player's name, remembered between launches (a preference like SurvivalHUDLayout, not a
## save file: nothing about the world is kept). The bot asks for it once per session, prefilled
## with what you told it last time. Tests point `path` elsewhere so they never touch yours.

const PATH := "user://profile.cfg"
static var path := PATH


static func load_name() -> String:
	var settings := ConfigFile.new()
	if settings.load(path) != OK:
		return ""
	var value: Variant = settings.get_value("player", "name", "")
	return str(value).to_upper() if value is String else ""


static func save_name(value: String) -> Error:
	var settings := ConfigFile.new()
	settings.load(path)
	settings.set_value("player", "name", value)
	return settings.save(path)
