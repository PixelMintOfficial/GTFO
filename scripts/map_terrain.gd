class_name MapTerrain
extends RefCounted

## What the ground at a point allows.
enum Surface { SOLID, STEEP, WALK }
## Ground data for a pre-rendered isometric map, read from the map generator's JSON:
## where you can walk, how high the ground is, and the projection between world
## coordinates (X right, Y away from the camera, in world units) and map pixels.
##
## The camera can turn round the world in quarter turns (ViewTurn): the generator renders the
## map once per view. The world stays put - world_pos, walk grid, props, doors are all in view
## 0's frame - and to_screen() shows it the way the current view does: turned `heading` quarter
## turns (clockwise, seen from above) about view_center. load_view() switches the view.
## replace_variant() changes an interior's repaired artwork and walk grid while keeping
## this terrain instance, world positions, and the current heading shared by all systems.
## to_screen_in_view/to_screen_direction share the projection for view-independent ray extents.

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
## How much of each map pixel is its own light (kept lit at night), and how much is daylight
## coming in (indoors: taken away at night). From the map generator; null if a map has none.
var light_mask: Texture2D
var sun_mask: Texture2D
## Things that block like buildings but can move or go away (rocks, crates): id -> (x, y, radius).
var blockers := {}
## Things you can stand on that can move or go away (the cargo box): id -> [centre: Vector2,
## half its footprint: Vector2, yaw, the height of its top]. Below the top they block like a wall.
var platforms := {}
## The current view: how many quarter turns the camera has made, the point it turns round,
## its meta JSON, its picture and its depth map.
var heading := 0
var view_center := Vector2.ZERO
var view_json := ""
var map_texture: Texture2D
var depth_map: Texture2D
## Every view of this map (meta JSON paths, by heading); just one if it has no others.
var views: Array[String] = []

var _grid_size := 0
var _height_offset := 100.0
var _height_scale := 300.0
var _walk := PackedByteArray()
var _biome := PackedByteArray()
var _biome_size := 0
var _biome_cell := 4.0


## json_path: the map's meta JSON (view 0). It opens on view `view` if the map has it.
func _init(json_path: String, view := 0) -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	var game: Dictionary = meta["game"]
	var dir := json_path.get_base_dir()
	for v in meta.get("views", []):
		views.append(dir.path_join(v))
	if views.is_empty():
		views.append(json_path)
	units_per_px = game["world_units_per_px"]
	depth_to_px = game["depth_to_px"]
	depth_scale = game["depth_scale"]
	px_per_unit = game.get("px_per_unit", 1.0)
	character_scale = game.get("character_scale", 1.0)
	spawn = Vector2(game["spawn_world"][0], game["spawn_world"][1])
	_grid_size = int(game["grid_size"])
	_height_offset = game["height_offset"]
	_height_scale = game["height_scale"]
	var img := _load_image(json_path.get_base_dir().path_join(game["walk_png"]))
	img.convert(Image.FORMAT_RGBA8)
	_walk = img.get_data()
	if meta.has("biomes"):
		var b: Dictionary = meta["biomes"]
		var bimg := _load_image(json_path.get_base_dir().path_join(b["png"]))
		bimg.convert(Image.FORMAT_RGB8)
		_biome = bimg.get_data()
		_biome_size = int(b["grid_size"])
		_biome_cell = float(b["cell"])
	load_view(view if view < views.size() else 0)


## Switch to another view of the map: its picture, depth, light, frame and zoom boxes.
func load_view(k: int) -> void:
	view_json = views[posmod(k, views.size())]
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(view_json))
	var game: Dictionary = meta["game"]
	var dir := view_json.get_base_dir()
	heading = int(game.get("heading", 0))
	var c: Array = game.get("view_center", [0.0, 0.0])
	view_center = Vector2(c[0], c[1])
	map_size = Vector2(meta["size"][0], meta["size"][1])
	origin = Vector2(meta["origin_px"][0], meta["origin_px"][1])
	frames.clear()
	if meta.has("zoom"):
		max_view_px = Vector2(meta["zoom"]["max_view_px"][0], meta["zoom"]["max_view_px"][1])
		for f in meta["zoom"].get("frames", {}).values():
			frames.append(Rect2(f[0], f[1], f[2], f[3]))
	map_texture = load(dir.path_join(meta["image"]))
	depth_map = load(dir.path_join(game["depth_png"]))
	light_mask = load(dir.path_join(game["light_png"])) if game.has("light_png") else null
	sun_mask = load(dir.path_join(game["sun_png"])) if game.has("sun_png") else null


func replace_variant(json_path: String) -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	var dir := json_path.get_base_dir()
	views.clear()
	for path in meta["views"]:
		views.append(dir.path_join(path))
	var image := _load_image(dir.path_join(meta["game"]["walk_png"]))
	image.convert(Image.FORMAT_RGBA8)
	_walk = image.get_data()
	load_view(heading)


## A world point (or the point under it) as the current view lays it out.
func view_point(p: Vector2, view := -1) -> Vector2:
	var d := p - view_center
	match heading if view < 0 else view:
		1:
			return Vector2(d.y, -d.x) + view_center
		2:
			return -d + view_center
		3:
			return Vector2(-d.y, d.x) + view_center
	return p


## A point as the current view lays it out, back in the world.
func world_point(v: Vector2) -> Vector2:
	return world_dir(v - view_center) + view_center


## How far from the camera a world point is in this view (what the depth map holds).
func view_depth(p: Vector2) -> float:
	return view_point(p).y


## A world direction as the current view sees it, and back.
func view_dir(w: Vector2, view := -1) -> Vector2:
	match heading if view < 0 else view:
		1:
			return Vector2(w.y, -w.x)
		2:
			return -w
		3:
			return Vector2(-w.y, w.x)
	return w


func world_dir(v: Vector2) -> Vector2:
	match heading:
		1:
			return Vector2(-v.y, v.x)
		2:
			return -v
		3:
			return Vector2(v.y, -v.x)
	return v


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
	return to_screen_in_view(p, z, heading, origin)


## Project using generated view metadata without changing this terrain's current view.
func to_screen_in_view(p: Vector2, z: float, view: int, view_origin: Vector2) -> Vector2:
	var v := view_point(p, view)
	return Vector2(view_origin.x + v.x / units_per_px, view_origin.y - (depth_to_px * v.y + z) * px_per_unit)


func to_screen_direction(direction: Vector3, view := -1) -> Vector2:
	var v := view_dir(Vector2(direction.x, direction.y), view)
	return Vector2(v.x / units_per_px, -(depth_to_px * v.y + direction.z) * px_per_unit)


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
	if b <= 63:
		return Surface.SOLID
	for k in blockers:
		var c: Vector3 = blockers[k]
		if p.distance_squared_to(Vector2(c.x, c.y)) < c.z * c.z:
			return Surface.SOLID
	return Surface.WALK if b > 191 else Surface.STEEP


## The top of whatever platform covers a world point (its footprint grown by margin), or -INF
## where none does.
func platform_top(p: Vector2, margin := 0.0) -> float:
	var top := -INF
	for k in platforms:
		var b: Array = platforms[k]
		var q := (p - (b[0] as Vector2)).rotated(-float(b[2])).abs()
		if q.x <= b[1].x + margin and q.y <= b[1].y + margin:
			top = maxf(top, b[3])
	return top


## How high you would stand at a world point: the ground, or the top of a platform over it.
func stand_height(p: Vector2) -> float:
	return maxf(height_at(p), platform_top(p))


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


## How much of each land a world point is in: x red dust, y alien forest, z ice. Sums to 1.
func biome_at(p: Vector2) -> Vector3:
	if _biome_size == 0:
		return Vector3(1, 0, 0)
	var g := _to_grid(p) / _biome_cell - Vector2(0.5, 0.5)
	var u := int(floor(g.x))
	var v := int(floor(g.y))
	var f := g - Vector2(u, v)
	var top := _biome_px(u, v).lerp(_biome_px(u + 1, v), f.x)
	var bottom := _biome_px(u, v + 1).lerp(_biome_px(u + 1, v + 1), f.x)
	return top.lerp(bottom, f.y)


func _biome_px(u: int, v: int) -> Vector3:
	var i := (clampi(v, 0, _biome_size - 1) * _biome_size + clampi(u, 0, _biome_size - 1)) * 3
	return Vector3(_biome[i], _biome[i + 1], _biome[i + 2]) / 255.0


func _height(u: int, v: int) -> float:
	var i := (clampi(v, 0, _grid_size - 1) * _grid_size + clampi(u, 0, _grid_size - 1)) * 4
	return float(_walk[i] * 256 + _walk[i + 1]) / _height_scale - _height_offset


func _to_grid(p: Vector2) -> Vector2:
	return Vector2(p.x + p.y, p.y - p.x) / sqrt(2.0)
