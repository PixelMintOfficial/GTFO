class_name BasePower
extends Node
## Base and nursery exterior lights, independent of the O2-only reserve.
## Base uses generator + solar routes; nursery uses its repaired console. Inside the base all surfaces
## stay lit; outside separate compact masks light each facility and its nearby ground.
## Shared world shaders sample in map pixels, so streaming cannot move the lights.
## Camera swings receive each view's mask separately through TurnOverlay.view_info.
## Test: tests/base_power_test.tscn (optional --gallery=shots/base-power).

const CATALOG := "res://assets/maps/red_planet/power/catalog.json"
static var active := false
static var nursery_active := false
static var current: Dictionary = {}
static var _images := {}
var _terrain: MapTerrain


func setup(terrain: MapTerrain) -> void:
	_terrain = terrain
	load_view()
	_process(0.0)


static func view_data(terrain: MapTerrain) -> Dictionary:
	var path := terrain.view_json
	var empty := {"indoor": 0.0, "rect": Vector4(0, 0, 1, 1), "mask": null,
			"nursery_rect": Vector4(0, 0, 1, 1), "nursery_mask": null}
	if path.begins_with("res://assets/maps/base_interior/"):
		empty["indoor"] = 1.0
		return empty
	if not path.begins_with("res://assets/maps/red_planet/"):
		return empty
	var catalog := ViewData.get_json(CATALOG)
	var info: Dictionary = catalog["views"][terrain.heading]
	var r: Array = info["rect"]
	var nursery: Dictionary = catalog["nursery_views"][terrain.heading]
	var nr: Array = nursery["rect"]
	return {"indoor": 0.0, "rect": Vector4(r[0], r[1], r[2], r[3]),
			"mask": load(CATALOG.get_base_dir().path_join(info["file"])),
			"nursery_rect": Vector4(nr[0], nr[1], nr[2], nr[3]),
			"nursery_mask": load(CATALOG.get_base_dir().path_join(nursery["file"]))}


func load_view() -> void:
	current = view_data(_terrain)
	RenderingServer.global_shader_parameter_set("bp_indoor", current["indoor"])
	RenderingServer.global_shader_parameter_set("bp_rect", current["rect"])
	RenderingServer.global_shader_parameter_set("bp_mask", current["mask"])
	RenderingServer.global_shader_parameter_set("bp_nursery_rect", current["nursery_rect"])
	RenderingServer.global_shader_parameter_set("bp_nursery_mask", current["nursery_mask"])


func _process(_delta: float) -> void:
	active = GameState.base_powered()
	nursery_active = GameState.nursery_powered()
	RenderingServer.global_shader_parameter_set("bp_active", 1.0 if active else 0.0)
	RenderingServer.global_shader_parameter_set("bp_nursery_active", 1.0 if nursery_active else 0.0)


static func light_at(info: Dictionary, at: Vector2) -> float:
	if not active and not nursery_active:
		return 0.0
	if info["indoor"] > 0.0:
		return 1.0 if active else 0.0
	var amount := 0.0
	for prefix in ["", "nursery_"]:
		if (prefix == "" and not active) or (prefix == "nursery_" and not nursery_active):
			continue
		var mask: Texture2D = info[prefix + "mask"]
		var r: Vector4 = info[prefix + "rect"]
		var p := Vector2i(at - Vector2(r.x, r.y))
		if mask == null or p.x < 0 or p.y < 0 or p.x >= int(r.z) or p.y >= int(r.w):
			continue
		if not _images.has(mask.resource_path):
			_images[mask.resource_path] = mask.get_image()
		amount = maxf(amount, (_images[mask.resource_path] as Image).get_pixelv(p).r)
	return amount


func _exit_tree() -> void:
	active = false
	nursery_active = false
	current.clear()
	_images.clear()
	RenderingServer.global_shader_parameter_set("bp_active", 0.0)
	RenderingServer.global_shader_parameter_set("bp_nursery_active", 0.0)
	RenderingServer.global_shader_parameter_set("bp_indoor", 0.0)
	RenderingServer.global_shader_parameter_set("bp_mask", null)
	RenderingServer.global_shader_parameter_set("bp_nursery_mask", null)
