class_name BasePower
extends Node
## The main base's normal lights, independent of the bot's emergency reserve.
## GameState requires O2 + reactor + all solar routes. Inside the base all surfaces
## stay lit; outside a compact geometry-derived mask lights only the base and spill.
## Shared world shaders sample in map pixels, so streaming cannot move the lights.
## Camera swings receive each view's mask separately through TurnOverlay.view_info.
## Test: tests/base_power_test.tscn (optional --gallery=shots/base-power).

const CATALOG := "res://assets/maps/red_planet/power/catalog.json"
static var active := false
static var current: Dictionary = {}
static var _images := {}
var _terrain: MapTerrain


func setup(terrain: MapTerrain) -> void:
	_terrain = terrain
	load_view()
	_process(0.0)


static func view_data(terrain: MapTerrain) -> Dictionary:
	var path := terrain.view_json
	if path.begins_with("res://assets/maps/base_interior/"):
		return {"indoor": 1.0, "rect": Vector4(0, 0, 1, 1), "mask": null}
	if not path.begins_with("res://assets/maps/red_planet/"):
		return {"indoor": 0.0, "rect": Vector4(0, 0, 1, 1), "mask": null}
	var info: Dictionary = ViewData.get_json(CATALOG)["views"][terrain.heading]
	var r: Array = info["rect"]
	return {"indoor": 0.0, "rect": Vector4(r[0], r[1], r[2], r[3]),
			"mask": load(CATALOG.get_base_dir().path_join(info["file"]))}


func load_view() -> void:
	current = view_data(_terrain)
	RenderingServer.global_shader_parameter_set("bp_indoor", current["indoor"])
	RenderingServer.global_shader_parameter_set("bp_rect", current["rect"])
	RenderingServer.global_shader_parameter_set("bp_mask", current["mask"])


func _process(_delta: float) -> void:
	active = GameState.base_powered()
	RenderingServer.global_shader_parameter_set("bp_active", 1.0 if active else 0.0)


static func light_at(info: Dictionary, at: Vector2) -> float:
	if not active:
		return 0.0
	if info["indoor"] > 0.0:
		return 1.0
	var mask: Texture2D = info["mask"]
	var r: Vector4 = info["rect"]
	var p := Vector2i(at - Vector2(r.x, r.y))
	if mask == null or p.x < 0 or p.y < 0 or p.x >= int(r.z) or p.y >= int(r.w):
		return 0.0
	if not _images.has(mask.resource_path):
		_images[mask.resource_path] = mask.get_image()
	return (_images[mask.resource_path] as Image).get_pixelv(p).r


func _exit_tree() -> void:
	active = false
	current.clear()
	_images.clear()
	RenderingServer.global_shader_parameter_set("bp_active", 0.0)
	RenderingServer.global_shader_parameter_set("bp_indoor", 0.0)
	RenderingServer.global_shader_parameter_set("bp_mask", null)
