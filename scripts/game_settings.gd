class_name GameSettings
extends RefCounted
## Player preferences, owned by GameState across scenes and saved separately from game progress.
## Master volume controls the existing Master bus, leaving the authored mix intact. GUI sizes
## scale only the clock, stats, hotbar and backpack. Large is the original size; smaller sizes
## use whole display pixels when the window has at least three pixels per logical UI pixel.
## Tests can supply a separate ConfigFile or --settings-path=PATH; normal games use user://.

signal changed

const PATH := "user://settings.cfg"
const SIZES := ["small", "medium", "large"]
const FACTORS := [0.6, 0.8, 1.0]
var volume := 1.0
var gui_size := "large"
var path: String


func _init(file_path := PATH) -> void:
	path = file_path
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--settings-path=") and file_path == PATH:
			path = arg.trim_prefix("--settings-path=")
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return
	var value: Variant = config.get_value("audio", "master_volume", 1.0)
	if (value is float or value is int) and is_finite(float(value)):
		volume = clampf(float(value), 0.0, 1.0)
	var size_value: Variant = config.get_value("interface", "gui_size", "large")
	if size_value in SIZES:
		gui_size = size_value


func apply_volume() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(0, volume <= 0.0)


func set_volume(value: float) -> void:
	if not is_finite(value):
		return
	volume = clampf(value, 0.0, 1.0)
	apply_volume()
	changed.emit()


func set_gui_size(value: String) -> void:
	if value not in SIZES or gui_size == value:
		return
	gui_size = value
	changed.emit()


func save() -> Error:
	var config := ConfigFile.new()
	config.set_value("audio", "master_volume", volume)
	config.set_value("interface", "gui_size", gui_size)
	return config.save(path)


## Relative to the existing UI canvas. Preserve Large exactly at every window size.
func gui_factor(canvas: CanvasItem) -> float:
	var index := SIZES.find(gui_size)
	if index == 2:
		return 1.0
	var view := canvas.get_viewport_rect().size
	var fit := minf(view.x / 384.0, view.y / 216.0)
	var density := fit * absf(canvas.get_viewport().get_stretch_transform().get_scale().x)
	if density < 3.0:
		return FACTORS[index]
	var pixels := floori(density)
	var medium := clampi(roundi(pixels * FACTORS[1]), 2, pixels - 1)
	var small := clampi(roundi(pixels * FACTORS[0]), 1, medium - 1)
	return float(small if index == 0 else medium) / density
