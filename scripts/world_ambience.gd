class_name WorldAmbience
extends Node2D
## What the red planet sounds like.
##
## Two layers, the same shape as the two layers WindFX draws:
##
##   beds       The air of each land - dusty wind on the red plains, the deep hum and alien
##              voices of the forest, thin wind and straining ice on the icefields - mixed by
##              how much of each land the astronaut is standing in. The same biome weights
##              that crossfade the weather crossfade the sound, so walking out of the forest
##              sounds like walking out of the forest. Plus the suit's own fan, always there.
##
##   emitters   Things on the map you can hear when you get near them: the glowing pools, the
##              crystal spires, the embers still burning round the ship's wreck, and the
##              two domes that still have power. Their positions are not written down
##              anywhere new - they are clustered out of the glow points the map generator
##              already exports in red_planet_fx.json, so the sound sits exactly where the
##              light is. The base is dead and makes no sound at all.
##
## Only the nearest few emitters play, so a field of pools cannot eat the voice pool.

## Glow kinds in red_planet_fx.json (they match BiomeFX.Kind).
const POOL := 1
const EMBER := 2
const SPIRE := 4
## Glow points this far apart (map px) are treated as one thing you can hear.
const CLUSTER := 420
## How many emitters may sound at once.
const NEARBY := 6
## Which sound each kind of light makes, and how many points make a "full-sized" one.
const VOICES := {
	POOL: {"sound": "amb_pool", "full": 26.0},
	EMBER: {"sound": "amb_wreck", "full": 10.0},
	SPIRE: {"sound": "amb_spire", "full": 12.0},
}

var _player: Player
var _camera: Camera2D
var _biome_source: Callable
var _emitters: Array = []        # [position, sound, key, weight]
var _live := {}                  # key -> true while it is playing


## biome_source returns the land weights (red, forest, ice) where the astronaut stands - the
## same callable WindFX takes.
func setup(meta_path: String, camera: Camera2D, player: Player, biome_source: Callable) -> void:
	_camera = camera
	_player = player
	_biome_source = biome_source
	load_view(meta_path)


## The camera turned: the emitters, where this view puts them (Audio moves the playing ones).
func load_view(meta_path: String) -> void:
	_emitters.clear()
	var meta := ViewData.get_json(meta_path)
	if meta.has("fx"):
		_cluster_glows(ViewData.fx_of(meta_path, meta))
	for name in meta.get("domes", {}):
		if name == "base":
			continue                      # the main base has no power: it is silent
		var d: Dictionary = meta["domes"][name]
		_emitters.append([Vector2(d["center_px"][0], d["center_px"][1]), "amb_dome",
				"dome:" + name, 1.0])


## Turn the generator's glow points into a handful of things you can hear. One pool is one
## pool; a cluster of twenty is a loud one.
func _cluster_glows(fx: Dictionary) -> void:
	var groups := {}                      # kind -> cell -> [sum x, sum y, count]
	for g in fx.get("glows", []):
		var kind := int(g[5])
		if not VOICES.has(kind):
			continue
		var key := Vector3i(kind, floori(float(g[0]) / CLUSTER), floori(float(g[1]) / CLUSTER))
		var cell: Array = groups.get(key, [0.0, 0.0, 0])
		cell[0] += float(g[0])
		cell[1] += float(g[1])
		cell[2] += 1
		groups[key] = cell
	var n := 0
	for key in groups:
		var cell: Array = groups[key]
		var info: Dictionary = VOICES[key.x]
		_emitters.append([Vector2(cell[0] / cell[2], cell[1] / cell[2]), info["sound"],
				"%s:%d" % [info["sound"], n], clampf(cell[2] / info["full"], 0.3, 1.0)])
		n += 1


## A cutscene is somewhere else (out in space, inside the ship): the planet is silent until
## this is cleared again.
var quiet := false


func _process(_delta: float) -> void:
	if _player == null:
		return
	if quiet:
		for bed_name in ["amb_suit", "amb_red", "amb_forest", "amb_ice"]:
			Audio.bed(bed_name, 0.0)
		for key in _live.keys():
			Audio.release(key)
		_live = {}
		return
	_beds()
	_emit()


## The air of the three lands, plus the suit.
func _beds() -> void:
	Audio.bed("amb_suit", 1.0)
	if not _biome_source.is_valid():
		Audio.bed("amb_red", 1.0)
		return
	var w: Vector3 = _biome_source.call()
	Audio.bed("amb_red", w.x)
	Audio.bed("amb_forest", w.y)
	Audio.bed("amb_ice", w.z)


## Start the nearest few emitters and let the rest go. Distance falloff is Godot's job (each
## sound carries its own hearing distance from audio.json); this only decides which ones are
## worth a voice at all.
func _emit() -> void:
	var ear := _camera.get_screen_center_position() if _camera != null else _player.global_position
	var near: Array = []
	for e in _emitters:
		var d: float = (e[0] as Vector2).distance_to(ear)
		if d < Audio.hearing(e[1]):
			near.append([d, e])
	near.sort_custom(func(a, b): return a[0] < b[0])
	var keep := {}
	for i in mini(NEARBY, near.size()):
		var e: Array = near[i][1]
		keep[e[2]] = true
		Audio.loop(e[1], e[2], e[0], e[3])
	for key in _live.keys():
		if not keep.has(key):
			Audio.release(key)
	_live = keep
