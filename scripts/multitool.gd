class_name Multitool
extends Node2D
## The astronaut's multitool: a folded device on the backpack that, taken out, bursts open into
## armour plates that fly onto the right forearm and lock into a gauntlet (red and gold, with a
## glowing emitter on the back of the hand). T (gamepad Y) takes it out or puts it away. With it out, F
## (gamepad X) works on whatever is in reach, and the tool picks the job from the target:
##   mine    orange  ore rocks: a pulsing cutting beam, sparks and chips flying, cracks
##                   spreading through the rock until it bursts into ore chunks
##   gather  teal    ore chunks and scrap: a spiral stream pulls the thing into the lens
##   lift    violet  crates: a wavy tether floats it up and it follows you until E sets it down
##   fix     cyan    dead lamps: scan lines sweep it, sparks gather, and it flickers back on
## Hold F to mine, gather and fix; tap F to pick a crate up and again to set it down.
## A small icon over the nearest thing in reach shows which job the tool will do.
## Gather commits to GameState before the zip animation. A full bag leaves the prop intact.

signal inventory_full

const COLORS := {"mine": Color("#ff8a3a"), "gather": Color("#4fe0c8"), "lift": Color("#b583ff"), "fix": Color("#7fd8ff")}
const CORES := {"mine": Color("#fff0c4"), "gather": Color("#e6fff9"), "lift": Color("#f3eaff"), "fix": Color("#f4fdff")}
## Seconds of work each job takes.
const TIMES := {"mine": 1.6, "gather": 0.55, "fix": 2.4}
## How far from the astronaut's feet a target may be (world units, to its edge).
const REACH := 40.0
## How far ahead a lifted crate floats (world units, beyond its own size), and how high (px).
const CARRY := 24.0
const LIFT_PX := 10.0
const IDLE_LENS := Color("#bff3ff")
const FORGE := [Color("#7fe8ff"), Color("#ffd27a"), Color("#ffffff")]   # transformation sparks
const LAMP_WARM := Color("#ffcf87")
const CHIP := Color("#5a3c40")
const DUST := Color("#c08868")
const ICONS := {
	"mine": ["..###..", ".#...#.", "#..#..#", "...#...", "...#...", "...#...", "...#..."],
	"gather": ["...#...", "...#...", ".#.#.#.", "..###..", "#..#..#", "#.....#", ".#####."],
	"lift": ["...#...", "..###..", ".#.#.#.", "...#...", "#######", "#.....#", "#######"],
	"fix": [".#...#.", ".#...#.", ".##.##.", "..###..", "...#...", "...#...", "...#..."],
}

## Test runs: keep the use button held down.
var forced_use := false
## Something else (an airlock door prompt) owns the use button right now.
var suppressed := false
## Modal inventory owns input independently of the door's proximity suppression.
var inventory_suppressed := false
## Machine proximity and the repair modal own F independently of door/inventory input.
var repair_suppressed := false

var _player: Player
var _terrain: MapTerrain
var _actors: Node2D
var _depth_map: Texture2D
var _sheets := {}
var _props: Array = []
var _lamps: Array = []
var _fx: Node2D
var _glow: Node2D
var _under: Node2D                   # beams to things behind the astronaut: sorted just behind them
var _tglow: Node2D                   # light on the thing being worked on, sorted just in front of it
var _lamp_glows: Array = []          # one light per lamp, sorted with the lamp's foot
var _target: Variant = null          # the WorldProp or lamp in reach
var _working := false
var _lifted: WorldProp = null
var _lift_t := 0.0
var _forced_pressed := false
var _dropping: Array = []            # [prop, start height, t]
var _zips: Array = []                # [prop, start position, t]
var _hops: Array = []                # [prop, from world, to world, t, duration]
var _parts: Array = []               # [pos, vel, age, life, color, size, gravity, kind]
var _stream: Array = []              # [s, phase, speed, from px] gather stream dots
var _homing: Array = []              # [from, to, age, life, color] sparkles converging
var _rings: Array = []               # [pos, age, life, color, radius]
var _hit := Vector2.ZERO
var _lens_flash := 0.0
var _was_lit := false
var _last_equip_frame := -1
var _t := 0.0
var _discs := {}
var _halos := {}


func setup(props_json: String, player: Player, terrain: MapTerrain, actors: Node2D, depth_map: Texture2D) -> void:
	_player = player
	_terrain = terrain
	_actors = actors
	_depth_map = depth_map
	_ensure_actions()
	_fx = Node2D.new()
	_fx.z_index = 30
	_fx.draw.connect(_draw_fx)
	add_child(_fx)
	_glow = Node2D.new()
	_glow.z_index = 31
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = add
	_glow.draw.connect(_draw_glow)
	add_child(_glow)
	_under = Node2D.new()
	_under.draw.connect(_draw_under)
	actors.add_child(_under)
	_tglow = Node2D.new()
	_tglow.material = add
	_tglow.draw.connect(_draw_target_glow)
	actors.add_child(_tglow)
	if not FileAccess.file_exists(props_json):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(props_json))
	var dir := props_json.get_base_dir()
	for name in data["sprites"]:
		var s: Dictionary = data["sprites"][name]
		_sheets[name] = {"tex": load(dir.path_join(s["file"])), "frames": int(s["frames"]),
				"anchor": Vector2(s["anchor"][0], s["anchor"][1])}
	for i in data["objects"].size():
		var o: Dictionary = data["objects"][i]
		var id := props_json + ":" + str(i)
		if GameState.removed_props.has(id):
			continue
		var prop := _spawn_prop(o["kind"], Vector2(o["world"][0], o["world"][1]), int(o["frame"]), o["job"],
				float(o["radius"]), bool(o["solid"]))
		prop.set_meta("inventory_id", id)
	for id in GameState.spawned_props:
		if not GameState.removed_props.has(id):
			var o: Dictionary = GameState.spawned_props[id]
			var prop := _spawn_prop("ore_chunk", o["world"], o["frame"], "gather", 2.5, false)
			prop.set_meta("inventory_id", id)
	for l in data["lamps"]:
		var w := Vector2(l["world"][0], l["world"][1])
		_lamps.append({"world": w, "head": Vector2(l["head_px"][0], l["head_px"][1]),
				"base": terrain.to_screen(w, terrain.height_at(w)).round(),
				"lit": false, "progress": 0.0, "t": 0.0, "radius": 4.0, "job": "fix"})
		var lg := Node2D.new()
		lg.material = add
		lg.position = Vector2(0, _lamps[-1]["base"].y + 1.0)
		lg.draw.connect(_draw_lamp.bind(lg, _lamps[-1]))
		actors.add_child(lg)
		_lamp_glows.append(lg)


func _spawn_prop(kind: String, world: Vector2, frame: int, job: String, radius: float, solid: bool) -> WorldProp:
	var p := WorldProp.new()
	p.kind = kind
	p.job = job
	p.radius = radius
	p.solid = solid
	p.setup(_sheets[kind], frame, _terrain, _depth_map)
	_actors.add_child(p)
	p.place(world)
	_props.append(p)
	return p


# ---------------------------------------------------------------- every frame
func _process(delta: float) -> void:
	if _player == null:
		return
	_t += delta
	var lit := _player.tool_lit()
	if lit and not _was_lit and _player.tool_state == Player.Tool.EQUIPPING and _player.tool_tip().z > 0.5:
		var tp := _tip()                                 # the lens comes alive
		Audio.play("tool_lens", tp)
		_lens_flash = 1.0
		_rings.append([tp, 0.0, 0.35, IDLE_LENS, 9.0])
		for i in 8:
			var a := TAU * i / 8.0
			_parts.append([tp, Vector2(cos(a), sin(a) * 0.6) * randf_range(25, 45), 0.0, 0.3, IDLE_LENS, 1, 0.0, 3])
	_was_lit = lit
	_transform_fx()
	var ready := _player.tool_state == Player.Tool.READY
	var can := ready and _player.controls_enabled and not suppressed and not inventory_suppressed and not repair_suppressed
	if Input.is_action_just_pressed("tool_toggle") and _player.controls_enabled and not _player.puppet and not inventory_suppressed:
		if _lifted != null:
			_drop()
		_stop_work()
		_player.toggle_tool()
	var press := can and (Input.is_action_just_pressed("tool_use") or (forced_use and not _forced_pressed))
	if press and forced_use:
		_forced_pressed = true
	var hold := can and (Input.is_action_pressed("tool_use") or forced_use)

	if _lifted != null:
		if not ready or press:
			_drop()
		else:
			_carry(delta)
	else:
		if not _working:
			var was: Variant = _target
			_target = _find_target() if can else null
			if _target != null and not is_same(_target, was):
				Audio.play("tool_target")                # the job icon appearing
		if hold and _target != null and _target["job"] != "lift":
			_work(delta)
		else:
			_stop_work()
			if press and _target != null and _target["job"] == "lift":
				_pick_up(_target)
	_step_effects(delta)
	# y-sort keys in whole pixels: 2D transforms snap to pixels, so half-pixel offsets would tie
	_under.position = Vector2(0, _player.position.y - 1.0)
	var focus := _focus_prop()
	if focus != null:
		_tglow.position = Vector2(0, focus.position.y + 1.0)
	_fx.queue_redraw()
	_glow.queue_redraw()
	_under.queue_redraw()
	_tglow.queue_redraw()
	for lg in _lamp_glows:
		lg.queue_redraw()


## The device bursting open and the plates flying onto the arm: sparks of energy streaming
## in, a pop when it opens, a ring of light when the armour locks.
func _transform_fx() -> void:
	var st := _player.tool_state
	if st != Player.Tool.EQUIPPING and st != Player.Tool.HOLSTERING:
		_last_equip_frame = -1
		return
	var f := _player.sprite.frame
	var of := _player.open_frames
	if of.x < 0:
		return
	var tp := _tip()
	var hand := tp + Vector2(-2, 3)
	var opening := st == Player.Tool.EQUIPPING
	if f != _last_equip_frame:
		if opening and f == of.x:
			_rings.append([hand, 0.0, 0.3, FORGE[0], 10.0])
			for i in 10:
				var a := TAU * i / 10.0
				_parts.append([hand, Vector2(cos(a), sin(a) * 0.8) * randf_range(35, 60), 0.0, 0.3, FORGE[i % 3], 1, 0.0, 3])
		if opening and f == of.y:
			_rings.append([hand, 0.0, 0.35, FORGE[1], 13.0])
			_lens_flash = 0.7
		_last_equip_frame = f
	if f >= of.x and f <= of.y:
		for i in 3:
			var a := randf() * TAU
			var from := hand + Vector2(cos(a), sin(a) * 0.8) * randf_range(9.0, 15.0)
			if opening:
				_homing.append([from, hand + Vector2(randf_range(-3, 3), randf_range(-2, 2)), 0.0, randf_range(0.18, 0.3), FORGE[randi() % 3]])
			else:
				_homing.append([hand, from, 0.0, randf_range(0.18, 0.3), FORGE[randi() % 3]])


func _find_target() -> Variant:
	var fd := _player.facing_dir()
	var best: Variant = null
	var best_score := INF
	var cands: Array = []
	for p in _props:
		if not p.gone and p.lift < 0.5 and not _busy(p):
			cands.append(p)
	for l in _lamps:
		if not l["lit"]:
			cands.append(l)
	for c in cands:
		var d: Vector2 = c["world"] - _player.world_pos
		var gap: float = d.length() - c["radius"]
		if gap > REACH:
			continue
		var score := gap - 14.0 * fd.dot(d.normalized())
		if score < best_score:
			best_score = score
			best = c
	return best


func _busy(p: WorldProp) -> bool:
	for z in _zips:
		if z[0] == p:
			return true
	for h in _hops:
		if h[0] == p:
			return true
	return false


# ---------------------------------------------------------------- jobs
func _work(delta: float) -> void:
	_working = true
	var job: String = _target["job"]
	_player.work_target = _target["world"]
	var tp := _tip()
	Audio.loop("beam_" + job, "beam:" + job, tp)
	match job:
		"mine":
			var rock: WorldProp = _target
			rock.progress = minf(1.0, rock.progress + delta / TIMES["mine"])
			var stage := mini(3, int(rock.progress * 4.0))
			if stage != rock.sprite.frame:                # a new crack opening in the rock
				Audio.play("rock_crack", rock.center_px(), 1.0, -3.0 + 2.0 * stage)
			rock.sprite.frame = stage
			rock.sprite.modulate = Color.WHITE.lerp(Color(1.3, 0.92, 0.78), rock.progress * 0.7)
			_hit = rock.center_px() + Vector2(randf_range(-2.5, 2.5), randf_range(-2.0, 2.0)).round()
			var away := (_hit - tp).normalized()
			for i in 2:
				var v := (away + Vector2(randf_range(-0.9, 0.9), randf_range(-1.4, -0.2))).normalized() * randf_range(40, 95)
				_parts.append([_hit, v, 0.0, randf_range(0.2, 0.45), COLORS["mine"] if randf() < 0.5 else CORES["mine"], 1, 160.0, 0])
			if randf() < 6.0 * delta:
				_parts.append([_hit, (away * 0.4 + Vector2(randf_range(-0.6, 0.6), -1)).normalized() * randf_range(30, 60),
						0.0, 0.6, CHIP, 2, 220.0, 1])
			if fmod(_t, 0.14) < delta:
				_player.camera.shake(0.8, 0.1)
			if rock.progress >= 1.0:
				_burst_rock(rock)
		"gather":
			var g: WorldProp = _target
			if not GameState.can_store(g.kind):
				inventory_full.emit()
				_stop_work()
				return
			g.progress = minf(1.0, g.progress + delta / TIMES["gather"])
			g.set_lift(g.progress * 7.0 + sin(_t * 22.0) * 0.6 * g.progress)
			g.scale = Vector2.ONE * (1.0 - 0.3 * g.progress)
			for i in 2:
				_stream.append([0.0, randf() * TAU, randf_range(2.4, 3.4), g.center_px() + Vector2(randf_range(-3, 3), randf_range(-2, 2))])
			if g.progress >= 1.0:
				if not GameState.store_item(g.kind):
					_stop_work()
					return
				GameState.removed_props[g.get_meta("inventory_id")] = true
				_zips.append([g, g.position, 0.0])
				g.shadow.visible = false
				_stop_work()
				_target = null
		"fix":
			var l: Dictionary = _target
			l["progress"] = minf(1.0, l["progress"] + delta / TIMES["fix"])
			if randf() < 14.0 * delta:
				var a := randf() * TAU
				_homing.append([l["head"] + Vector2(cos(a), sin(a)) * randf_range(10, 18), l["head"], 0.0, randf_range(0.35, 0.55), CORES["fix"]])
			if l["progress"] >= 1.0:
				l["lit"] = true
				l["t"] = 0.0
				Audio.play("lamp_on", l["head"])
				Audio.loop("amb_lamp", "lamp:%d" % _lamps.find(l), l["head"])
				_rings.append([l["head"], 0.0, 0.45, LAMP_WARM, 16.0])
				for i in 10:
					var a2 := TAU * i / 10.0
					_parts.append([l["head"], Vector2(cos(a2), sin(a2) * 0.7) * randf_range(20, 45), 0.0, 0.4, LAMP_WARM, 1, 40.0, 3])
				_stop_work()
				_target = null


func _stop_work() -> void:
	_working = false
	_player.work_target = null
	for job in ["mine", "gather", "fix"]:
		Audio.release("beam:" + job)


## UI cancels an active job; selecting away from the tool also sets down a lifted crate.
func cancel_work() -> void:
	_stop_work()
	_target = null
	if _lifted != null and not get_tree().paused:
		_drop()


func _burst_rock(rock: WorldProp) -> void:
	var c := rock.center_px()
	Audio.play("rock_burst", c)
	_player.camera.shake(2.6, 0.4)
	_rings.append([c, 0.0, 0.45, COLORS["mine"], 24.0])
	_lens_flash = 0.6
	for i in 18:
		var v := Vector2(randf_range(-1, 1), randf_range(-1.6, -0.3)).normalized() * randf_range(40, 110)
		_parts.append([c + Vector2(randf_range(-4, 4), randf_range(-3, 3)), v, 0.0, randf_range(0.5, 0.9),
				CHIP if i % 3 else COLORS["mine"], 2, 230.0, 1])
	for i in 14:
		var v2 := Vector2(randf_range(-1, 1), randf_range(-1.2, 0.2)).normalized() * randf_range(60, 130)
		_parts.append([c, v2, 0.0, randf_range(0.25, 0.5), CORES["mine"], 1, 120.0, 0])
	for i in 9:
		var a := TAU * i / 9.0
		_parts.append([c + Vector2(cos(a) * 4, sin(a) * 2), Vector2(cos(a), sin(a) * 0.5) * randf_range(10, 22),
				0.0, randf_range(0.9, 1.4), DUST, 3, -6.0, 2])
	for i in 3:                                          # ore chunks fly out and land around it
		var a3 := randf() * TAU
		var to := rock.world + Vector2(cos(a3), sin(a3)) * (rock.radius + randf_range(5, 11))
		if _terrain.surface(to) != MapTerrain.Surface.WALK:
			to = rock.world + Vector2(cos(a3), sin(a3)) * (rock.radius * 0.5)
		var chunk := _spawn_prop("ore_chunk", rock.world, i, "gather", 2.5, false)
		var id: String = rock.get_meta("inventory_id", "rock") + "/chunk/" + str(i)
		chunk.set_meta("inventory_id", id)
		GameState.spawned_props[id] = {"world": to, "frame": i}
		_hops.append([chunk, rock.world, to, 0.0, 0.5 + i * 0.08])
	GameState.removed_props[rock.get_meta("inventory_id")] = true
	_props.erase(rock)
	rock.remove()
	_stop_work()
	_target = null


func _pick_up(crate: WorldProp) -> void:
	_lifted = crate
	_lift_t = 0.0
	_target = null
	Audio.play("lift_grab", crate.center_px())
	Audio.loop("lift_loop", "lift", crate.center_px())
	_rings.append([crate.center_px(), 0.0, 0.4, COLORS["lift"], 12.0])


func _carry(delta: float) -> void:
	_lift_t += delta
	var k := clampf(_lift_t / 0.35, 0.0, 1.0)
	k = 1.0 - (1.0 - k) * (1.0 - k)
	var want := _player.world_pos + _player.facing_dir() * (CARRY + _lifted.radius)
	var w := _lifted.world.lerp(want, 1.0 - exp(-7.0 * delta))
	if _terrain.surface(w) != MapTerrain.Surface.SOLID:
		_lifted.place(w)
	_lifted.set_lift(LIFT_PX * k + sin(_t * 3.2) * 1.4 * k)
	Audio.loop("lift_loop", "lift", _lifted.center_px())
	if randf() < 10.0 * delta:
		var c := _lifted.global_position + Vector2(randf_range(-6, 6), -_lifted.lift + randf_range(-1, 2))
		_parts.append([c, Vector2(randf_range(-3, 3), randf_range(8, 16)), 0.0, 0.7, COLORS["lift"], 1, 0.0, 3])


func _drop() -> void:
	var c := _lifted
	_lifted = null
	Audio.release("lift")
	var to := c.world - _player.world_pos
	if to.length() < c.radius + 4.0:                     # never on top of the astronaut
		c.place(_player.world_pos + to.normalized() * (c.radius + 4.0) if to.length() > 0.01
				else _player.world_pos + _player.facing_dir() * (c.radius + 4.0))
	_dropping.append([c, c.lift, 0.0])


# ---------------------------------------------------------------- effects over time
func _step_effects(delta: float) -> void:
	_lens_flash = maxf(0.0, _lens_flash - delta * 3.0)
	var tp := _tip()
	for p in _props:                                     # half-pulled things sink back
		if p.job == "gather" and not is_same(p, _target) and not p.gone and not _busy(p) and p.progress > 0.0:
			p.progress = maxf(0.0, p.progress - delta * 3.0)
			p.set_lift(p.progress * 7.0)
			p.scale = Vector2.ONE * (1.0 - 0.3 * p.progress)
	var i := 0
	while i < _zips.size():                              # into the lens
		var z: Array = _zips[i]
		z[2] += delta / 0.18
		var e: float = minf(z[2], 1.0)
		e = e * e
		var p: WorldProp = z[0]
		p.position = (z[1] as Vector2).lerp(Vector2(tp.x, tp.y) + Vector2(0, p.lift), e)
		p.scale = Vector2.ONE * lerpf(0.7, 0.08, e)
		if z[2] >= 1.0:
			Audio.play("gather_pop", Vector2(tp.x, tp.y))
			_rings.append([Vector2(tp.x, tp.y), 0.0, 0.3, COLORS["gather"], 7.0])
			for k in 6:
				var a := TAU * k / 6.0
				_parts.append([Vector2(tp.x, tp.y), Vector2(cos(a), sin(a)) * 30.0, 0.0, 0.25, CORES["gather"], 1, 0.0, 3])
			_lens_flash = 0.8
			_props.erase(p)
			p.remove()
			_zips.remove_at(i)
			continue
		i += 1
	i = 0
	while i < _hops.size():                              # ore chunks landing
		var h: Array = _hops[i]
		h[3] += delta / h[4]
		var t: float = minf(h[3], 1.0)
		var p: WorldProp = h[0]
		p.place((h[1] as Vector2).lerp(h[2], t))
		p.set_lift(sin(PI * t) * 16.0 * (1.0 - 0.3 * t))
		if h[3] >= 1.0:
			p.set_lift(0.0)
			Audio.play("debris", p.global_position, 1.15, -9.0)
			_puff(p.global_position, 4)
			_hops.remove_at(i)
			continue
		i += 1
	i = 0
	while i < _dropping.size():                          # crates settling
		var dr: Array = _dropping[i]
		dr[2] += delta / 0.28
		var t2: float = minf(dr[2], 1.0)
		var c: WorldProp = dr[0]
		c.set_lift(dr[1] * (1.0 - t2 * t2))
		if dr[2] >= 1.0:
			c.set_lift(0.0)
			Audio.play("lift_drop", c.global_position)
			_puff(c.global_position, 8)
			_player.camera.shake(1.0, 0.15)
			_dropping.remove_at(i)
			continue
		i += 1
	for l in _lamps:
		if l["lit"]:
			l["t"] += delta
	i = 0
	while i < _parts.size():
		var q: Array = _parts[i]
		q[2] += delta
		if q[2] >= q[3]:
			_parts.remove_at(i)
			continue
		q[1] += Vector2(0, q[6]) * delta
		if q[7] == 2:
			q[1] *= exp(-2.5 * delta)
		q[0] += q[1] * delta
		i += 1
	i = 0
	while i < _stream.size():
		_stream[i][0] += delta * _stream[i][2]
		if _stream[i][0] >= 1.0:
			_stream.remove_at(i)
			continue
		i += 1
	i = 0
	while i < _homing.size():
		_homing[i][2] += delta
		if _homing[i][2] >= _homing[i][3]:
			_homing.remove_at(i)
			continue
		i += 1
	i = 0
	while i < _rings.size():
		_rings[i][1] += delta
		if _rings[i][1] >= _rings[i][2]:
			_rings.remove_at(i)
			continue
		i += 1


func _puff(at: Vector2, n: int) -> void:
	for k in n:
		var a := TAU * k / n
		_parts.append([at + Vector2(cos(a) * 3, sin(a) * 1.5), Vector2(cos(a), sin(a) * 0.45) * randf_range(10, 20),
				0.0, randf_range(0.5, 0.8), DUST, 2, -4.0, 2])


func _tip() -> Vector2:
	var t := _player.tool_tip()
	return Vector2(t.x, t.y)


# ---------------------------------------------------------------- drawing: beams, particles, rings, icons
func _draw_fx() -> void:
	if _player == null:
		return
	if not _behind():
		_draw_beams(_fx)
	if _working and _target != null:
		_progress_ring(_target, COLORS[_target["job"]])
	for h in _homing:                                    # fix: sparks gathering on the lamp
		var k: float = h[2] / h[3]
		var p2: Vector2 = (h[0] as Vector2).lerp(h[1], k * k)
		_fx.draw_rect(Rect2(p2.round(), Vector2.ONE), h[4])
	for q in _parts:
		var k2: float = q[2] / q[3]
		var c: Color = q[4]
		match q[7]:
			0:                                           # spark: a hot pixel with a short trail
				_fx.draw_rect(Rect2((q[0] as Vector2).round(), Vector2.ONE), c)
				_fx.draw_rect(Rect2(((q[0] as Vector2) - (q[1] as Vector2).normalized() * 1.5).round(), Vector2.ONE), Color(c, 0.6))
			1:                                           # chip of rock
				_fx.draw_rect(Rect2((q[0] as Vector2).round(), Vector2(q[5], q[5])), c)
			2:                                           # dust puff
				var r := int(round(q[5] + k2 * 3.0))
				_disc(_fx, (q[0] as Vector2).round(), r, Color(c, ceilf((1.0 - k2) * 3.0) / 3.0 * 0.6))
			3:                                           # mote
				_fx.draw_rect(Rect2((q[0] as Vector2).round(), Vector2.ONE), Color(c, 1.0 - k2))
	for r in _rings:                                     # flattened rings of light
		var k3: float = r[1] / r[2]
		_ring_px(_fx, r[0], r[4] * (0.4 + 0.6 * k3), Color(r[3], 1.0 - k3))
	if _target != null and not _working and _lifted == null:
		_icon(_target)


func _draw_glow() -> void:
	if _player == null:
		return
	var tp3 := _player.tool_tip()
	var tp := Vector2(tp3.x, tp3.y)
	if _player.tool_lit() and tp3.z > 0.5:
		var col := IDLE_LENS
		var r := 3
		var a := 0.3 + 0.08 * sin(_t * 3.0)
		if _working and _target != null:
			col = COLORS[_target["job"]]
			r = 5 + int(sin(_t * 30.0) > 0.0)
			a = 0.75
		elif _lifted != null:
			col = COLORS["lift"]
			r = 4
			a = 0.55
		_halo(_glow, tp, r + int(_lens_flash * 6.0), Color(col, minf(1.0, a + _lens_flash * 0.5)))
		_glow.draw_rect(Rect2(tp.round(), Vector2.ONE), Color(col, 0.9 * tp3.z + 0.3))
	if _working and _target != null and _target["job"] == "mine" and tp3.z > 0.5 and not _behind():
		_pline(_glow, tp, _hit, Color(COLORS["mine"], 0.25), 3)


## Beams to something behind the astronaut pass behind them.
func _draw_under() -> void:
	if _player == null or not _behind():
		return
	_under.draw_set_transform(Vector2(0, -_under.position.y))
	_draw_beams(_under)


## The prop being worked on or carried (lamps are not props).
func _focus_prop() -> WorldProp:
	if _lifted != null:
		return _lifted
	if _working and _target is WorldProp:
		return _target
	return null


func _behind() -> bool:
	var y := 0.0
	if _lifted != null:
		y = _lifted.position.y
	elif _target is WorldProp:
		y = (_target as WorldProp).position.y
	elif _target != null:
		y = (_target["base"] as Vector2).y
	else:
		return false
	return y < _player.position.y


## Light on the thing being worked on: the hot spot of the cutting beam, the lift aura.
func _draw_target_glow() -> void:
	if _player == null:
		return
	_tglow.draw_set_transform(Vector2(0, -_tglow.position.y))
	if _working and _target is WorldProp and _target["job"] == "mine":
		_halo(_tglow, _hit, 7, Color(COLORS["mine"], 0.6))
		_halo(_tglow, _hit, 3, Color(CORES["mine"], 0.9))
	if _lifted != null:
		_halo(_tglow, _lifted.center_px(), int(_lifted.radius * 1.4) + 4, Color(COLORS["lift"], 0.28))


## A repaired lamp: a flicker, then steady warm light and a pool of it on the ground.
func _draw_lamp(node: Node2D, l: Dictionary) -> void:
	if not l["lit"]:
		return
	var t: float = l["t"]
	if not (t > 0.6 or fmod(t, 0.17) < 0.09):
		return
	node.draw_set_transform(Vector2(0, -node.position.y))
	var head: Vector2 = l["head"]
	_halo(node, head, 22, Color(LAMP_WARM, 0.16))
	_halo(node, head, 10, Color(LAMP_WARM, 0.45))
	_disc(node, head.round(), 2, Color("#fff4d8"))
	var base: Vector2 = l["base"]
	node.draw_set_transform(Vector2(base.x, base.y - node.position.y), 0.0, Vector2(1.0, 0.5))
	_halo(node, Vector2.ZERO, 30, Color(LAMP_WARM, 0.14))


func _draw_beams(layer: CanvasItem) -> void:
	var tp3 := _player.tool_tip()
	var tp := Vector2(tp3.x, tp3.y)
	if _working and _target != null:
		var job: String = _target["job"]
		var col: Color = COLORS[job]
		var core: Color = CORES[job]
		match job:
			"mine":
				var pulse := sin(_t * 46.0) > 0.0
				_pline(layer, tp, _hit, Color(col, 0.55), 3 if pulse else 2)
				_pline(layer, tp, _hit, core, 1)
			"gather":
				var g: WorldProp = _target
				_dots(layer, tp, g.center_px(), Color(col, 0.55), 3)
			"fix":
				var l: Dictionary = _target
				var sy: float = lerpf(l["head"].y, l["base"].y - 2.0, 0.5 + 0.5 * sin(_t * 5.0))
				var a: Vector2 = Vector2(l["head"].x - 5.0, sy)
				var b: Vector2 = Vector2(l["head"].x + 5.0, sy)
				_pline(layer, tp, a, Color(col, 0.45), 1)
				_pline(layer, tp, b, Color(col, 0.45), 1)
				_pline(layer, a, b, core, 1)
	if _lifted != null:
		_tether(layer, tp, _lifted.center_px())
	for s in _stream:                                    # gather: a spiral of dots into the lens
		var from: Vector2 = s[3]
		var e: float = s[0] * s[0]
		var p := from.lerp(tp, e)
		var perp := (tp - from).orthogonal().normalized()
		p += perp * sin(s[0] * 12.0 + s[1]) * 5.0 * (1.0 - s[0])
		layer.draw_rect(Rect2(p.round(), Vector2.ONE), CORES["gather"] if s[0] > 0.6 else COLORS["gather"])


## Lift: a wavy line of violet light, with brighter beads running along it.
func _tether(layer: CanvasItem, a: Vector2, b: Vector2) -> void:
	var n := int(maxf(absf(b.x - a.x), absf(b.y - a.y))) + 1
	var perp := (b - a).orthogonal().normalized()
	for i in n + 1:
		var s := float(i) / n
		var p := a.lerp(b, s) + perp * sin(_t * 9.0 - s * 14.0) * 2.2 * sin(PI * s)
		var bead := fmod(s * 6.0 - _t * 2.5, 1.0)
		bead = bead + 1.0 if bead < 0.0 else bead
		layer.draw_rect(Rect2(p.round(), Vector2.ONE), CORES["lift"] if bead < 0.18 else Color(COLORS["lift"], 0.8))


func _progress_ring(t: Variant, col: Color) -> void:
	var base: Vector2
	var rx: float
	if t is WorldProp:
		base = (t as WorldProp).global_position
		rx = (t as WorldProp).radius / 0.866 + 5.0
	else:
		base = t["base"]
		rx = 9.0
	var done := 0.0
	if t is WorldProp:
		done = (t as WorldProp).progress
	else:
		done = t["progress"]
	var n := 16
	for i in n:
		var a := -PI / 2.0 + TAU * i / n
		var p := base + Vector2(cos(a) * rx, sin(a) * rx * 0.5)
		var lit := float(i) / n < done
		_fx.draw_rect(Rect2(p.round(), Vector2.ONE), col if lit else Color(col, 0.25))


func _icon(t: Variant) -> void:
	var job: String = t["job"]
	var top: Vector2
	if t is WorldProp:
		var w := t as WorldProp
		top = w.global_position + w.sprite.position + Vector2(0, -w.sprite.texture.get_height() * 0.62 - 6.0)
	else:
		top = (t["head"] as Vector2) + Vector2(0, -12)
	top = (top + Vector2(0, round(sin(_t * 4.0)))).round()
	var box := Rect2(top - Vector2(5, 5), Vector2(11, 11))
	_fx.draw_rect(box, Color("#1b1626", 0.85))
	_fx.draw_rect(Rect2(box.position + Vector2(1, 0), Vector2(9, 1)), COLORS[job])
	_fx.draw_rect(Rect2(box.position + Vector2(1, 10), Vector2(9, 1)), COLORS[job])
	_fx.draw_rect(Rect2(box.position + Vector2(0, 1), Vector2(1, 9)), COLORS[job])
	_fx.draw_rect(Rect2(box.position + Vector2(10, 1), Vector2(1, 9)), COLORS[job])
	var rows: Array = ICONS[job]
	for y in rows.size():
		for x in rows[y].length():
			if rows[y][x] == "#":
				_fx.draw_rect(Rect2(box.position + Vector2(2 + x, 2 + y), Vector2.ONE), CORES[job])
	_fx.draw_rect(Rect2(top + Vector2(-1, 6), Vector2(3, 1)), Color(COLORS[job], 0.7))   # a little pointer
	_fx.draw_rect(Rect2(top + Vector2(0, 7), Vector2(1, 1)), Color(COLORS[job], 0.7))


# ---------------------------------------------------------------- pixel drawing helpers
func _pline(layer: CanvasItem, a: Vector2, b: Vector2, col: Color, w: int) -> void:
	var n := int(maxf(absf(b.x - a.x), absf(b.y - a.y))) + 1
	var off := Vector2(floor(w / 2.0), floor(w / 2.0))
	for i in n + 1:
		var p := a.lerp(b, float(i) / n).round()
		layer.draw_rect(Rect2(p - off, Vector2(w, w)), col)


func _dots(layer: CanvasItem, a: Vector2, b: Vector2, col: Color, every: int) -> void:
	var n := int(maxf(absf(b.x - a.x), absf(b.y - a.y))) + 1
	var shift := int(_t * 20.0) % every
	for i in n + 1:
		if (i + shift) % every == 0:
			layer.draw_rect(Rect2(a.lerp(b, float(i) / n).round(), Vector2.ONE), col)


func _ring_px(layer: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var n := int(TAU * r / 1.5) + 6
	for i in n:
		var a := TAU * i / n
		layer.draw_rect(Rect2((c + Vector2(cos(a) * r, sin(a) * r * 0.5)).round(), Vector2.ONE), col)


func _disc(layer: CanvasItem, center: Vector2, r: int, col: Color) -> void:
	r = maxi(r, 0)
	if not _discs.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				if Vector2(x - r, y - r).length() <= r + 0.35:
					img.set_pixel(x, y, Color.WHITE)
		_discs[r] = ImageTexture.create_from_image(img)
	layer.draw_texture(_discs[r], center - Vector2(r, r), col)


## A soft round glow in three dithered steps (pixel art, for the additive layer).
func _halo(layer: CanvasItem, center: Vector2, r: int, col: Color) -> void:
	r = maxi(r, 1)
	if not _halos.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var bayer := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
		for y in size:
			for x in size:
				var d := Vector2(x - r, y - r).length() / float(r)
				if d > 1.0:
					continue
				var a := pow(1.0 - d, 1.6)
				var lv := floorf(a * 3.0 + (bayer[(y % 4) * 4 + x % 4] + 0.5) / 16.0)
				if lv > 0.0:
					img.set_pixel(x, y, Color(1, 1, 1, minf(lv, 3.0) / 3.0))
		_halos[r] = ImageTexture.create_from_image(img)
	layer.draw_texture(_halos[r], (center - Vector2(r, r)).round(), col)


static func _ensure_actions() -> void:
	var setup := {"tool_toggle": [KEY_T, JOY_BUTTON_Y], "tool_use": [KEY_F, JOY_BUTTON_X]}
	for action in setup:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var key := InputEventKey.new()
		key.physical_keycode = setup[action][0]
		InputMap.action_add_event(action, key)
		var pad := InputEventJoypadButton.new()
		pad.button_index = setup[action][1]
		InputMap.action_add_event(action, pad)
