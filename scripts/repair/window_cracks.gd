class_name WindowCracks
extends Node2D
## Storage's three smashed panes, and the cargo box you stand on to reach them. Two are in the wall
## you come in facing; the third is in the wall behind you, cut away in that view: turn the camera
## (G / H) to find it. Lift the box with the tool, set it down under a pane and jump on: it takes
## your weight with a crack - once for each pane, and not again until that pane is mended. When
## the last pane is mended with you standing on it, the box gives way: you go down with it, and
## the ration packs inside spill across the floor, to be gathered with the tool.
##
## Mending a pane is not built yet. STAND_IN_FIX stands in for it: landing on the box under a pane
## counts as mending it. The real job will call fix(id) instead, and STAND_IN_FIX goes; the box's
## cracks, the break and what is kept stay as they are.
##
## State: GameState.window_repair (WindowRepair). Data: base_interior.json -> window_cracks (where
## to stand under each pane, where this view draws it); interior_props.json -> the cargo_box object
## (its footprint, top and contents). Drawn here: chips and dust as the box cracks and bursts, and
## a ring of light where a pane is mended.

## Until panes can be mended with the tool: landing on the box under one mends it.
const STAND_IN_FIX := true
## How near the spot under a pane you must be, standing on the box (world units).
const NEAR := 20.0
## How long the box groans under you before it gives way, seconds.
const GROAN := 0.45
## How far the rations fly, world units from the box's middle: clear of its burst walls.
const SPILL := Vector2(27.0, 33.0)
const FIX := Color("#7fd8ff")                          # the multitool's fix colour
const STEEL := [Color("#3d3c58"), Color("#62627f"), Color("#9496b4")]
const DUST := Color("#c08868")

## This view's panes: {id, world: Vector2 (where to stand under it), hole: Vector2 (the wall under
## it), px: Vector2 (where this view draws it), seen: bool (this view leaves its wall standing)}.
var panes: Array[Dictionary] = []
var box: WorldProp
var repair: WindowRepair
var _player: Player
var _tool: Multitool
var _terrain: MapTerrain
var _groan := -1.0                                     # seconds into the groan; -1 when not breaking
var _controls_were := true
var _shake := 0.0
var _parts: Array = []                                 # [pos, vel, age, life, color, size, gravity, dust]
var _rings: Array = []                                 # [pos, age, life]
var _glow: Node2D
var _discs := {}


func setup(meta: Dictionary, player: Player, tool: Multitool, terrain: MapTerrain) -> void:
	_player = player
	_tool = tool
	_terrain = terrain
	repair = GameState.window_repair
	z_index = 29                                       # over the actors, under the tool's own light
	_glow = Node2D.new()
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = add
	_glow.draw.connect(_draw_glow)
	add_child(_glow)
	set_view(meta)
	box = tool.find_prop("cargo_box")
	if box == null:
		return
	if repair.box_world != null:
		box.place(repair.box_world)
	if repair.box_broken:
		_wreck()
	else:
		box.sprite.frame = mini(repair.damage(), box.sprite.hframes - 2)
	player.landed.connect(_landed)


## The camera turned: where this view draws the panes.
func set_view(meta: Dictionary) -> void:
	panes.clear()
	for p in meta.get("window_cracks", []):
		panes.append({"id": p["id"], "world": Vector2(p["world"][0], p["world"][1]),
				"hole": Vector2(p["hole"][0], p["hole"][1]), "px": Vector2(p["px"][0], p["px"][1]), "seen": p["seen"]})
	_parts.clear()
	_rings.clear()


## Standing on the box (not jumping off it).
func on_box() -> bool:
	return (box != null and box.top > 0.0 and not _player.is_airborne()
			and _player.height_above_floor() >= box.top - 1.0 and box.covers(_player.world_pos, 2.0))


## The pane a world point is under (on the box), or "".
func pane_near(p: Vector2) -> String:
	var best := ""
	var near := NEAR
	for pane in panes:
		var d: float = p.distance_to(pane["world"])
		if d < near:
			best = pane["id"]
			near = d
	return best


## Mend pane `id` (what the real fix job will call). Once the last is mended with you standing on
## the box, the box gives way (see _process).
func fix(id: String) -> void:
	if not repair.fix(id):
		return
	for pane in panes:
		if pane["id"] == id:
			Audio.play("pane_mend", pane["px"])
			if pane["seen"]:
				_rings.append([pane["px"], 0.0, 0.6])


## Test hooks: set the box down under pane `id`, as near the wall as it fits. Returns where.
func place_box_under(id: String) -> Vector2:
	for pane in panes:
		if pane["id"] != id:
			continue
		var spot: Vector2 = pane["world"]
		var inward: Vector2 = (spot - (pane["hole"] as Vector2)).normalized()
		while not box.fits(spot) and spot.distance_to(pane["world"]) < 40.0:
			spot += inward
		box.place(spot)
		repair.box_world = spot
		return spot
	return box.world


func _landed(_impact: float) -> void:
	if box == null or repair.box_broken or not on_box():
		return
	Audio.play("cargo_land", _top_px())                # steel under the boots, over the landing thud
	var pane := pane_near(_player.world_pos)
	if pane == "":
		return
	if repair.crack_box(pane):
		_crack()
	if STAND_IN_FIX and repair.box_cracks.has(pane):
		fix(pane)


func _process(delta: float) -> void:
	if box == null or _player == null:
		return
	if not repair.box_broken:
		if box.lift <= 0.0 and not box.gone:
			repair.box_world = box.world                # wherever it was last set down
		if _groan < 0.0 and repair.all_fixed(_pane_ids()) and on_box():
			_start_groan()
	if _groan >= 0.0:
		_groan += delta
		box.sprite.position.x = 1.0 if fmod(_groan, 0.08) < 0.04 else -1.0
		if _groan >= GROAN:
			_give_way()
	elif _shake > 0.0:
		_shake -= delta
		box.sprite.position.x = 0.0 if _shake <= 0.0 else (1.0 if fmod(_shake, 0.06) < 0.03 else 0.0)
	var i := 0
	while i < _parts.size():
		var q: Array = _parts[i]
		q[2] += delta
		if q[2] >= q[3]:
			_parts.remove_at(i)
			continue
		q[1] += Vector2(0, q[6]) * delta
		if q[7]:
			q[1] *= exp(-2.5 * delta)
		q[0] += q[1] * delta
		i += 1
	i = 0
	while i < _rings.size():
		_rings[i][1] += delta
		if _rings[i][1] >= _rings[i][2]:
			_rings.remove_at(i)
			continue
		i += 1
	queue_redraw()
	_glow.queue_redraw()


func _pane_ids() -> Array:
	var ids := []
	for pane in panes:
		ids.append(pane["id"])
	return ids


## The box's top on screen, where it takes your weight.
func _top_px() -> Vector2:
	return box.global_position + Vector2(0, -box.top * _terrain.px_per_unit)


## A crack opening under your boots.
func _crack() -> void:
	box.sprite.frame = mini(repair.damage(), box.sprite.hframes - 2)
	var c := _top_px()
	Audio.play("cargo_crack", c)
	_player.camera.shake(1.2, 0.2)
	_shake = 0.25
	_chips(c, 10, 70.0)
	_dust(c, 5)


func _start_groan() -> void:
	_groan = 0.0
	_controls_were = _player.controls_enabled
	_player.controls_enabled = false
	_tool.cancel_work()
	box.sprite.frame = box.sprite.hframes - 2
	Audio.play("cargo_groan", _top_px())


## The box bursts: you go down with it, and the rations inside spill out.
func _give_way() -> void:
	_groan = -1.0
	var c := box.center_px()
	repair.break_box()
	_wreck()
	_player.controls_enabled = _controls_were
	_player.collapse()
	Audio.play("cargo_burst", c)
	_player.camera.shake(2.6, 0.4)
	_chips(c, 24, 110.0)
	_dust(box.global_position, 10)
	var contents: Dictionary = box.get_meta("contents", {})
	var n := int(contents.get("count", 0))
	for k in n:
		var to := box.world
		for attempt in 9:                              # round to open floor if a wall is in the way
			var a := TAU * (k + randf_range(0.2, 0.8)) / n + attempt * 0.7
			var p := box.world + Vector2(cos(a), sin(a)) * randf_range(SPILL.x, SPILL.y)
			if _terrain.surface(p) == MapTerrain.Surface.WALK:
				to = p
				break
		_tool.spill(contents["kind"], box.world, to, k % 3, "%s/spill/%d" % [box.get_meta("inventory_id", "box"), k],
				3.0, k * 0.07, "ration_land", 1.0, 0.0)


## What is left of the box: lies where it broke, nothing to stand on, nothing for the tool.
func _wreck() -> void:
	box.sprite.position.x = 0.0
	box.sprite.frame = box.sprite.hframes - 1
	box.job = ""
	box.set_top(0.0)


func _chips(at: Vector2, n: int, speed: float) -> void:
	for k in n:
		var v := Vector2(randf_range(-1, 1), randf_range(-1.4, -0.2)).normalized() * randf_range(speed * 0.4, speed)
		_parts.append([at + Vector2(randf_range(-6, 6), randf_range(-2, 2)), v, 0.0, randf_range(0.4, 0.8),
				STEEL[k % 3], 1 + k % 2, 220.0, false])


func _dust(at: Vector2, n: int) -> void:
	for k in n:
		var a := TAU * k / n
		_parts.append([at + Vector2(cos(a) * 6, sin(a) * 2), Vector2(cos(a), sin(a) * 0.45) * randf_range(12, 24),
				0.0, randf_range(0.6, 0.9), DUST, 2, -4.0, true])


func _draw() -> void:
	for q in _parts:
		var k: float = q[2] / q[3]
		if q[7]:                                       # dust: a soft puff, thinning
			_disc((q[0] as Vector2).round(), int(round(q[5] + k * 3.0)), Color(q[4], ceilf((1.0 - k) * 3.0) / 3.0 * 0.6))
		else:                                          # a chip of the box's steel
			draw_rect(Rect2((q[0] as Vector2).round(), Vector2(q[5], q[5])), q[4])


## A mended pane: a ring of the fix colour opening round it.
func _draw_glow() -> void:
	for r in _rings:
		var k: float = r[1] / r[2]
		var rad := 6.0 + 14.0 * k
		var n := int(TAU * rad / 1.5) + 6
		for j in n:
			var a := TAU * j / n
			_glow.draw_rect(Rect2(((r[0] as Vector2) + Vector2(cos(a) * rad, sin(a) * rad * 0.5)).round(), Vector2.ONE),
					Color(FIX, 1.0 - k))


func _disc(center: Vector2, r: int, col: Color) -> void:
	r = maxi(r, 0)
	if not _discs.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				if Vector2(x - r, y - r).length() <= r + 0.35:
					img.set_pixel(x, y, Color.WHITE)
		_discs[r] = ImageTexture.create_from_image(img)
	draw_texture(_discs[r], center - Vector2(r, r), col)
