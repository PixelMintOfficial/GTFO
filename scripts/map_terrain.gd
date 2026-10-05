class_name MapTerrain
extends RefCounted

## What the ground at a point allows.
enum Surface { SOLID, STEEP, WALK }
## Ground data for a pre-rendered isometric map, read from the map generator's JSON:
## where you can walk, how high the ground is, and the projection between world
## coordinates (X right, Y away from the camera, in world units) and map pixels.

var map_size := Vector2.ZERO
var origin := Vector2.ZERO
var units_per_px := 0.866
var depth_to_px := 0.577
var depth_scale := 25.0
## Map pixels per world unit of height.
var px_per_unit := 1.0
## World units per sprite pixel of height: sprites are drawn 1:1 on the map, so their
## speeds and sizes (authored in sprite pixels) are converted with this.
var character_scale := 1.0
var spawn := Vector2.ZERO
## Map pixels the furthest zoom-out may show (the whole main base).
var max_view_px := Vector2(1920, 1080)
## Boxes (map pixels) around each dome that the furthest zoom frames as a whole.
var frames: Array[Rect2] = []

var _grid_size := 0
var _height_offset := 100.0
var _height_scale := 300.0
var _walk := PackedByteArray()


func _init(json_path: String) -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	var game: Dictionary = meta["game"]
	map_size = Vector2(meta["size"][0], meta["size"][1])
	origin = Vector2(meta["origin_px"][0], meta["origin_px"][1])
	units_per_px = game["world_units_per_px"]
	depth_to_px = game["depth_to_px"]
	depth_scale = game["depth_scale"]
	px_per_unit = game.get("px_per_unit", 1.0)
	character_scale = game.get("character_scale", 1.0)
	spawn = Vector2(game["spawn_world"][0], game["spawn_world"][1])
	if meta.has("zoom"):
		max_view_px = Vector2(meta["zoom"]["max_view_px"][0], meta["zoom"]["max_view_px"][1])
		for f in meta["zoom"].get("frames", {}).values():
			frames.append(Rect2(f[0], f[1], f[2], f[3]))
	_grid_size = int(game["grid_size"])
	_height_offset = game["height_offset"]
	_height_scale = game["height_scale"]
	var img := _load_image(json_path.get_base_dir().path_join(game["walk_png"]))
	img.convert(Image.FORMAT_RGBA8)
	_walk = img.get_data()


static func _load_image(path: String) -> Image:
	var res: Resource = load(path)
	if res is Image:
		return res
	if res is Texture2D:
		return (res as Texture2D).get_image()
	push_error("MapTerrain: could not load %s" % path)
	return Image.create(1, 1, false, Image.FORMAT_RGBA8)


## Map pixel position of a world point standing at height z.
func to_screen(p: Vector2, z: float) -> Vector2:
	return Vector2(origin.x + p.x / units_per_px, origin.y - (depth_to_px * p.y + z) * px_per_unit)


func is_walkable(p: Vector2) -> bool:
	return surface(p) == Surface.WALK


## WALK: you can walk here. STEEP: too steep to walk (slopes, boulders) but you can jump
## over, onto or down it. SOLID: buildings and props, always in the way.
func surface(p: Vector2) -> Surface:
	var g := _to_grid(p)
	var u := int(floor(g.x))
	var v := int(floor(g.y))
	if u < 0 or v < 0 or u >= _grid_size or v >= _grid_size:
		return Surface.SOLID
	var b := _walk[(v * _grid_size + u) * 4 + 2]
	if b > 191:
		return Surface.WALK
	return Surface.STEEP if b > 63 else Surface.SOLID


## Unit direction (world X/Y) the ground falls away fastest.
func downhill(p: Vector2) -> Vector2:
	var gx := height_at(p + Vector2(1.5, 0)) - height_at(p - Vector2(1.5, 0))
	var gy := height_at(p + Vector2(0, 1.5)) - height_at(p - Vector2(0, 1.5))
	var g := -Vector2(gx, gy)
	return g.normalized() if g.length() > 0.0001 else Vector2.ZERO


## Ground height under a world point, bilinear between grid cells.
func height_at(p: Vector2) -> float:
	var g := _to_grid(p) - Vector2(0.5, 0.5)
	var u := int(floor(g.x))
	var v := int(floor(g.y))
	var f := g - Vector2(u, v)
	var top := lerpf(_height(u, v), _height(u + 1, v), f.x)
	var bottom := lerpf(_height(u, v + 1), _height(u + 1, v + 1), f.x)
	return lerpf(top, bottom, f.y)


func _height(u: int, v: int) -> float:
	var i := (clampi(v, 0, _grid_size - 1) * _grid_size + clampi(u, 0, _grid_size - 1)) * 4
	return float(_walk[i] * 256 + _walk[i + 1]) / _height_scale - _height_offset


func _to_grid(p: Vector2) -> Vector2:
	return Vector2(p.x + p.y, p.y - p.x) / sqrt(2.0)
