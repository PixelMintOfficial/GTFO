class_name CrashSite
extends Node2D
## The satellite that came down near the base.
##
## At the start of the game it plays the crash: the camera turns to the site, the satellite
## streaks in glowing from re-entry under a trail of fire and smoke, touches down, ploughs its
## trench (the untouched ground is uncovered behind it) and slams to a stop in a flash, a
## shockwave and a cloud of dust and debris. Any button skips it.
##
## Afterwards the wreck smoulders: smoke curls up from the hull, the engine and the torn-off
## wing, the engine burns, the broken wing spits sparks and the distress beacon blinks.
##
## Sit this node right after the map: the old ground draws under everything, the air (smoke,
## fire, sparks, the falling satellite) on its own layer above the astronaut.

signal finished

const REVEAL := preload("res://shaders/crash_reveal.gdshader")

enum State { WAIT, FALL, SKID, SETTLE, DONE }

const SMOKE: Array[Color] = [Color("#1d1824"), Color("#383040"), Color("#5c5064")]   # shadow, body, lit top
const SMOKE_OLD: Array[Color] = [Color("#3a3240"), Color("#5a4f62"), Color("#857a8c")]   # thinning out as it rises
const DUST: Array[Color] = [Color("#4f2a30"), Color("#8a4a42"), Color("#c27a5c")]
const FIRE: Array[Color] = [Color("#b8322e"), Color("#ff7a3a"), Color("#ffd27a"), Color("#fff4d0")]
const DEBRIS := Color("#2a2230")
const BEACON := Color("#ff5a4a")

@export var wait_time := 0.8
@export var fall_time := 1.9
@export var skid_time := 1.5
@export var settle_time := 2.6
## Wind pushing the smoke (map px/s).
@export var wind := Vector2(7.0, -1.0)

var _camera: GameCamera
var _player: Player
var _biome: BiomeFX
var _before: Sprite2D
var _reveal: ShaderMaterial
var _sat: Sprite2D
var _air: Node2D
var _lit: Node2D              # fire, sparks, the beacon and the flash: lights, bright by night too
var _focus := Vector2.ZERO
var _sky := Vector2.ZERO
var _bend := Vector2.ZERO
var _touch := Vector2.ZERO
var _rest := Vector2.ZERO
var _smoke_at: Array[Vector2] = []
var _sparks_at: Array[Vector2] = []
var _fire_at: Array[Vector2] = []
var _beacon := Vector2.ZERO

var _state := State.DONE
var _st := 0.0
var _t := 0.0
var _sat_pos := Vector2.ZERO
var _sat_last := Vector2.ZERO
var _flash := 0.0
var _ring := -1.0
var _smoulder := 1.0          # 0..1: how much the wreck smokes and burns
var _spawn_acc: Array[float] = []
var _spark_timer := 1.5
var _puffs: Array = []        # [pos, vel, radius, growth, age, life, palette, drag]
var _sparks: Array = []       # [pos, vel, age, life]
var _chunks: Array = []       # [ground pos, ground vel, height, vertical speed]
var _discs: Dictionary = {}


func setup(meta_path: String, camera: GameCamera, player: Player, biome: BiomeFX) -> void:
	_camera = camera
	_player = player
	_biome = biome
	_before = Sprite2D.new()
	_before.centered = false
	_reveal = ShaderMaterial.new()
	_reveal.shader = REVEAL
	_before.material = _reveal
	_before.visible = false
	add_child(_before)
	_air = Node2D.new()
	_air.z_index = 40
	_air.draw.connect(_draw_air)
	add_child(_air)
	_lit = Node2D.new()
	_lit.z_index = 41
	_lit.set_meta("dn_unlit", true)
	_lit.draw.connect(_draw_lit)
	add_child(_lit)
	_sat = Sprite2D.new()
	_sat.centered = false
	_sat.visible = false
	_air.add_child(_sat)
	load_view(meta_path)


## The camera turned: where the wreck, its smoke, fire and beacon are in this view (smoke and
## sparks already in the air are let go).
func load_view(meta_path: String) -> void:
	var dir := meta_path.get_base_dir()
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	if not meta.has("fx"):
		return
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join(meta["fx"])))
	var c: Dictionary = fx["crash"]
	_focus = _v(c["focus"])
	_sky = _v(c["sky"])
	_touch = _v(c["touchdown"])
	_rest = _v(c["rest"])
	_bend = _sky.lerp(_touch, 0.55) + Vector2(-26, -18)
	_smoke_at.clear()
	_spawn_acc.clear()
	_sparks_at.clear()
	_fire_at.clear()
	for p in c["smoke"]:
		_smoke_at.append(_v(p))
		_spawn_acc.append(0.0)
	for p in c["sparks"]:
		_sparks_at.append(_v(p))
	for p in c["fire"]:
		_fire_at.append(_v(p))
	_beacon = _v(c["beacon"])
	_puffs.clear()
	_sparks.clear()
	_chunks.clear()
	_before.texture = load(dir.path_join(c["before"]["file"]))
	_before.position = _v(c["before"]["position"])
	_sat.texture = load(dir.path_join(c["satellite"]["file"]))
	_sat.hframes = int(c["satellite"]["frames"])
	_sat.offset = -_v(c["satellite"]["origin"]).round()


## The crash, from the top. The astronaut waits; the camera watches the site.
func play_intro() -> void:
	if _before == null:
		return
	_state = State.WAIT
	_st = 0.0
	_smoulder = 0.0
	_biome.embers = 0.0
	_reveal.set_shader_parameter("front", 1.0)
	_before.visible = true
	_player.controls_enabled = false
	_camera.focus_override = _focus
	_camera.set_level(1)
	_camera.snap_to(_focus)


func is_playing() -> bool:
	return _state != State.DONE


func _unhandled_input(event: InputEvent) -> void:
	if _state == State.DONE or event.is_echo():
		return
	if (event is InputEventKey or event is InputEventJoypadButton) and event.is_pressed():
		get_viewport().set_input_as_handled()
		if _state != State.SETTLE:
			_land(false)
		_finish()


func _process(delta: float) -> void:
	_t += delta
	_st += delta
	match _state:
		State.WAIT:
			if _st >= wait_time:
				_enter(State.FALL)
				_sat.visible = true
				_sat_pos = _sky
				_sat_last = _sky
		State.FALL:
			Audio.loop("crash_roar", "crash", _sat_pos)
			var k := clampf(_st / fall_time, 0.0, 1.0)
			var e := k * k * (0.4 + 0.6 * k)                       # gathering speed
			_sat_pos = _sky.lerp(_bend, e).lerp(_bend.lerp(_touch, e), e)
			_sat.frame = int(_st * 9.0) % _sat.hframes
			_trail()
			if k >= 1.0:
				_enter(State.SKID)
				Audio.release("crash")
				Audio.play("debris", _touch, 0.9, -2.0)
				_camera.shake(2.5, 0.4)
				_dust_burst(_touch, 10, 14.0, 50.0)
		State.SKID:
			Audio.loop("crash_skid", "skid", _sat_pos)
			var k := clampf(_st / skid_time, 0.0, 1.0)
			var e := 1.0 - pow(1.0 - k, 2.2)                       # ploughing to a stop
			_sat_pos = _touch.lerp(_rest, e)
			if k < 0.7:
				_sat.frame = int(_st * (6.0 - 6.0 * k)) % _sat.hframes
			_reveal.set_shader_parameter("front", 1.0 - e)
			_skid_fx(1.0 - k)
			if _t - floorf(_t / 0.1) * 0.1 < delta:
				_camera.shake(1.2 * (1.0 - k) + 0.4, 0.12)
			if k >= 1.0:
				_land(true)
		State.SETTLE:
			if _st < delta * 2.0:
				Audio.play("debris", _rest, 1.0, -4.0)
			_smoulder = clampf(_st / 1.6, 0.0, 1.0)
			_biome.embers = _smoulder
			if _st >= settle_time:
				_finish()
	_sat_last = _sat_pos
	_sat.position = _sat_pos.round()
	_update_particles(delta)
	if _state == State.DONE or _state == State.SETTLE:
		_smoulder_fx(delta)
	_flash = maxf(0.0, _flash - delta / 0.4)
	if _ring >= 0.0:
		_ring += delta
		if _ring > 0.8:
			_ring = -1.0
	_air.queue_redraw()
	_lit.queue_redraw()


func _enter(s: State) -> void:
	_state = s
	_st = 0.0


## The satellite stops dead: flash, shockwave, dust and debris (or, when skipped, just the aftermath).
func _land(dramatic: bool) -> void:
	_sat.visible = false
	_before.visible = false
	_reveal.set_shader_parameter("front", -1.0)
	Audio.release("crash")
	Audio.release("skid")
	if dramatic:
		_flash = 1.0
		_ring = 0.0
		Audio.play("crash_impact", _rest)
		_camera.shake(5.0, 0.8)
		_dust_burst(_rest, 34, 30.0, 95.0)
		for i in 22:
			var a := randf() * TAU
			var v := Vector2(cos(a), sin(a) * 0.5) * randf_range(30.0, 120.0)
			_chunks.append([_rest + Vector2(randf_range(-6, 6), randf_range(-3, 3)), v, randf_range(2.0, 8.0),
					randf_range(70.0, 150.0)])
		_enter(State.SETTLE)
	else:
		_smoulder = 1.0
		_biome.embers = 1.0


func _finish() -> void:
	_state = State.DONE
	_smoulder = 1.0
	_biome.embers = 1.0
	_player.controls_enabled = true
	_camera.release_focus()
	_camera.set_level(0)
	finished.emit()


# ---------------------------------------------------------------- effects
func _trail() -> void:
	var step := _sat_pos - _sat_last
	var n := maxi(1, int(step.length() / 3.0))
	for i in n:
		var p := _sat_last + step * (float(i) / n)
		_puff(p + _jitter(1.5), Vector2.ZERO, randf_range(1.5, 3.0), 2.0, randf_range(0.25, 0.4), 3, 0.0)
		if i % 2 == 0:
			_puff(p + _jitter(2.0), Vector2(0, -6) + _jitter(4.0), randf_range(2.5, 4.0), 5.0,
					randf_range(1.2, 1.9), 0, 0.5)


func _skid_fx(power: float) -> void:
	var motion := (_rest - _touch).normalized()
	var side := Vector2(-motion.y, motion.x)
	for i in 2:
		var s := 1.0 if randf() < 0.5 else -1.0
		_puff(_sat_pos + Vector2(0, 6) + _jitter(4.0), side * s * randf_range(18.0, 46.0) * power - motion * 10.0
				+ Vector2(0, -8), randf_range(3.0, 6.0), 7.0, randf_range(1.0, 1.8), 1, 1.6)
	for i in 3:
		var dirv := (-motion).rotated(randf_range(-0.7, 0.7))
		_sparks.append([_sat_pos + Vector2(0, 4), dirv * randf_range(60.0, 150.0) + Vector2(0, -40), 0.0,
				randf_range(0.25, 0.55)])
	if randf() < 0.5:
		_puff(_sat_pos + _jitter(3.0), Vector2(0, -12), randf_range(2.0, 3.5), 6.0, randf_range(1.0, 1.6), 0, 0.4)


func _dust_burst(at: Vector2, count: int, r_max: float, speed: float) -> void:
	for i in count:
		var a := randf() * TAU
		var v := Vector2(cos(a), sin(a) * 0.5) * randf_range(0.25, 1.0) * speed + Vector2(0, -10)
		_puff(at + Vector2(cos(a), sin(a) * 0.5) * randf_range(0.0, r_max * 0.3), v,
				randf_range(r_max * 0.25, r_max * 0.5), r_max * 0.35, randf_range(1.6, 3.4), 1, 1.4)
	for i in int(count / 3.0):
		_puff(at + _jitter(6.0), Vector2(0, -randf_range(14.0, 26.0)) + _jitter(8.0), randf_range(4.0, 7.0), 9.0,
				randf_range(2.0, 3.2), 0, 0.6)


func _smoulder_fx(delta: float) -> void:
	if _smoulder <= 0.0 or not _view().grow(220.0).has_point(_rest):
		return
	for i in _smoke_at.size():
		var rate := (9.0 if i == 0 else 5.0) * _smoulder
		_spawn_acc[i] += rate * delta
		while _spawn_acc[i] >= 1.0:
			_spawn_acc[i] -= 1.0
			var big := 1.0 if i == 0 else 0.65
			_puff(_smoke_at[i] + _jitter(2.0), Vector2(randf_range(-2.0, 2.0), randf_range(-20.0, -13.0)),
					randf_range(2.0, 3.5) * big, randf_range(5.5, 8.0) * big, randf_range(3.6, 5.2), 0, 0.12)
	for f in _fire_at:
		if randf() < 10.0 * delta * _smoulder:
			_puff(f + _jitter(2.0), Vector2(randf_range(-4.0, 4.0), randf_range(-26.0, -16.0)), 1.0, 0.0,
					randf_range(0.4, 0.8), 3, 0.0)
	_spark_timer -= delta
	if _spark_timer <= 0.0 and _sparks_at.size() > 0:
		_spark_timer = randf_range(1.0, 3.4)
		var at: Vector2 = _sparks_at[randi() % _sparks_at.size()]
		for i in randi_range(7, 15):
			var a := randf_range(-PI, 0.0)
			_sparks.append([at, Vector2(cos(a), sin(a)) * randf_range(30.0, 95.0), 0.0, randf_range(0.35, 0.8)])


func _puff(p: Vector2, v: Vector2, r: float, growth: float, life: float, palette: int, drag: float) -> void:
	_puffs.append([p, v, r, growth, 0.0, life, palette, drag])


func _update_particles(delta: float) -> void:
	var i := 0
	while i < _puffs.size():
		var q: Array = _puffs[i]
		q[4] += delta
		if q[4] >= q[5]:
			_puffs.remove_at(i)
			continue
		var v: Vector2 = q[1]
		v = v * exp(-q[7] * delta) + wind * delta * 0.6
		q[1] = v
		q[0] += v * delta
		i += 1
	i = 0
	while i < _sparks.size():
		var s: Array = _sparks[i]
		s[2] += delta
		if s[2] >= s[3]:
			_sparks.remove_at(i)
			continue
		s[1] += Vector2(0, 150.0) * delta
		s[0] += s[1] * delta
		i += 1
	i = 0
	while i < _chunks.size():
		var c: Array = _chunks[i]
		c[3] -= 210.0 * delta
		c[2] += c[3] * delta
		c[0] += c[1] * delta
		if c[2] <= 0.0:
			_puff(c[0], Vector2(0, -6), 2.0, 3.0, randf_range(0.6, 1.0), 1, 1.0)
			_chunks.remove_at(i)
			continue
		i += 1


# ---------------------------------------------------------------- drawing (the air layer)
## Smoke, dust and debris: lit by the sun, so they take the time of day.
func _draw_air() -> void:
	var view := _view().grow(40.0)
	for q in _puffs:
		var p: Vector2 = q[0]
		var pal: int = q[6]
		if pal == 3 or not view.has_point(p):
			continue
		var k: float = q[4] / q[5]
		var r := int(round(q[2] + q[3] * sqrt(k)))
		var fade := ceilf((1.0 - k) * 4.0) / 4.0
		var c := p.round()
		var cols: Array[Color] = DUST if pal == 1 else (SMOKE if k < 0.4 else SMOKE_OLD)
		var a := fade * (0.85 if pal == 0 else 0.9)
		_disc(c + Vector2(1, 1), r, Color(cols[0], a))
		_disc(c, r, Color(cols[1], a))
		if r >= 2:
			_disc(c - Vector2(r, r) * 0.35, int(r * 0.55), Color(cols[2], a))
	for c in _chunks:
		var p: Vector2 = (c[0] - Vector2(0, c[2])).round()
		_air.draw_rect(Rect2(p, Vector2(2, 2)), DEBRIS)
		_air.draw_rect(Rect2(p, Vector2.ONE), SMOKE[2])


## Fire, sparks, the re-entry glow, the beacon, the shockwave and the flash: their own light.
func _draw_lit() -> void:
	var view := _view().grow(40.0)
	for q in _puffs:
		var p: Vector2 = q[0]
		if int(q[6]) != 3 or not view.has_point(p):
			continue
		var k: float = q[4] / q[5]
		var r := int(round(q[2] + q[3] * sqrt(k)))
		var fade := ceilf((1.0 - k) * 4.0) / 4.0
		var col: Color = FIRE[clampi(3 - int(k * 4.0), 0, 3)]   # hot core cooling to red
		_disc(p.round(), r, Color(col, fade), _lit)
	for s in _sparks:
		var k: float = s[2] / s[3]
		var col: Color = FIRE[3] if k < 0.3 else (FIRE[2] if k < 0.65 else FIRE[1])
		var p: Vector2 = s[0].round()
		_lit.draw_rect(Rect2(p, Vector2.ONE), col)
		_lit.draw_rect(Rect2((s[0] - (s[1] as Vector2).normalized() * 1.5).round(), Vector2.ONE), Color(FIRE[1], 0.7))
	if _sat.visible:                                 # re-entry glow around the falling satellite
		_disc(_sat_pos.round(), 9, Color(FIRE[1], 0.25), _lit)
		_disc(_sat_pos.round(), 5, Color(FIRE[2], 0.35), _lit)
	if _smoulder > 0.0:
		for f in _fire_at:
			var fl := sin(_t * 23.0) * 0.5 + sin(_t * 37.0 + 1.3) * 0.5
			var c := f.round()
			_disc(c + Vector2(0, -1), int(4 + fl), Color(FIRE[0], 0.8 * _smoulder), _lit)
			_disc(c + Vector2(0, -2 - int(fl > 0.3)), 3, Color(FIRE[1], _smoulder), _lit)
			_disc(c + Vector2(0, -3), int(1.5 + fl * 0.5), Color(FIRE[2], _smoulder), _lit)
		var b := fmod(_t, 1.6)
		if b < 0.1 or (b > 0.25 and b < 0.35):
			_disc(_beacon.round(), 5, Color(BEACON, 0.35 * _smoulder), _lit)
			_disc(_beacon.round(), 2, Color(Color.WHITE, _smoulder), _lit)
		else:
			_disc(_beacon.round(), 1, Color(BEACON, 0.8 * _smoulder), _lit)
	if _ring >= 0.0:                                 # shockwave racing out over the ground
		var r := 24.0 + 340.0 * _ring
		var a := 1.0 - _ring / 0.8
		var n := int(TAU * r / 2.0)
		for i in n:
			var ang := TAU * i / n
			var p := (_rest + Vector2(cos(ang) * r, sin(ang) * r * 0.5)).round()
			_lit.draw_rect(Rect2(p, Vector2(2, 1)), Color(FIRE[3], a * 0.8))
			_lit.draw_rect(Rect2(p + Vector2(0, 1), Vector2(2, 1)), Color(DUST[2], a * 0.6))
	if _flash > 0.0:
		_lit.draw_rect(_view(), Color(1.0, 0.93, 0.8, _flash * _flash * 0.6))
		_disc(_rest.round(), int(18 + 30 * (1.0 - _flash)), Color(FIRE[3], _flash), _lit)


## A crisp pixel disc (drawn from a texture so it stays pixel art at any window size).
func _disc(center: Vector2, r: int, col: Color, canvas: CanvasItem = null) -> void:
	r = maxi(r, 0)
	if not _discs.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				var d := Vector2(x - r, y - r).length()
				if d <= r + 0.35:
					img.set_pixel(x, y, Color.WHITE)
		_discs[r] = ImageTexture.create_from_image(img)
	(canvas if canvas != null else _air).draw_texture(_discs[r], center - Vector2(r, r), col)


func _view() -> Rect2:
	var size := get_viewport_rect().size / _camera.zoom
	return Rect2(_camera.get_screen_center_position() - size * 0.5, size)


func _jitter(r: float) -> Vector2:
	return Vector2(randf_range(-r, r), randf_range(-r, r))


static func _v(a: Array) -> Vector2:
	return Vector2(a[0], a[1])
