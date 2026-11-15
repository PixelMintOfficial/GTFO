class_name IntroCutscene
extends CanvasLayer
## The opening of the game, played once per run (GameState.intro_done). Any key or button skips it.
##
##   COCKPIT   Inside the ship, stars streaming past the windscreen, Araxys rising behind it.
##             Mission Control: you are closing in on the planet.
##   ORBIT     The planet turning in space, the ship gliding in. Mission Control: the crew
##             before you went silent; pick up where they left off and make Araxys livable.
##   DESCENT   Back inside: the fire of re-entry, the cabin shaking, the master alarm. A solar
##             storm - and the warning about the radiation breaks up into static. SIGNAL LOST.
##   OUTSIDE   White-out, then the planet: the ship streaks in out of control and ploughs
##             into the dust by the base (CrashSite plays the fall, the trench and the impact).
##             When the dust settles something thumps on the hatch, it blows off, and the
##             astronaut steps out into the doorway and hops down. A last broken call on the
##             radio, then DAY 1 and the controls.
##
## The cockpit, the planet and the small ship are generated art (tools/intro_gen.py ->
## assets/intro/, positions in intro.json); the wreck, its hatch and the way out are the map
## generator's (fx.crash). Every line and name is in data/bot_story.json ("intro", {PLANET}).
## The stage is drawn in screen pixels on this layer (above the world and its turn overlay,
## below the UI's own modal layers); it is UI, so DayNight never grades it.
##
## With the earlier satellite design (no hatch in fx.crash) the cockpit and orbit still play;
## the astronaut is simply standing at the base when it is over.

signal finished

const DATA := "res://assets/intro/intro.json"
const ART := "res://assets/intro/"
const FRAMES := preload("res://assets/characters/astronaut/astronaut_frames.tres")
const VOID := Color("#0b0915")
const BAR := 18                                   # letterbox bars, top and bottom
const RADIO := Rect2(40, 154, 304, 38)
const CPS := 34.0                                  # letters a second on the radio
const TEXT := Color("#f2f0f8")
const ACCENT := Color("#7fe6cf")
const FAULT := Color("#ff5a4a")
const DIM := Color("#6a6385")
const STAR_COLS: Array[Color] = [Color("#fbfbff"), Color("#fbfbff"), Color("#7fe6cf"), Color("#efb950"), Color("#b8a9e8")]
const FIRE: Array[Color] = [Color("#2a0f1e"), Color("#5a1a2e"), Color("#b8322e"), Color("#ff7a3a"), Color("#ffd27a"),
		Color("#fff4d0")]
const GARBLE := "%/<>?!-:"                         # PixelFont's own symbols
const BAYER := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

## When each shot starts (seconds from the top). OUTSIDE's beats follow CrashSite's landing.
const T_ORBIT := 5.6
const T_DESCENT := 13.4
const T_OUTSIDE := 19.4

enum Shot { COCKPIT, ORBIT, DESCENT, OUTSIDE }

var _player: Player
var _crash: CrashSite
var _ambience: WorldAmbience
var _data: Dictionary
var _lines: Dictionary
var _shot := Shot.COCKPIT
var _t := 0.0
var _st := 0.0                                     # time in this shot
var _beats: Array = []                            # [time, Callable], soonest first
var _over := false
var _ending := -1.0                               # seconds into the closing (bars sliding out)

var _stage: Node2D                                 # everything that shakes
var _back: Node2D
var _planet: Sprite2D
var _ship: Sprite2D
var _plate: Sprite2D
var _pilot: AnimatedSprite2D
var _fx: Node2D
var _glow: Node2D                                  # additive: lamps, engines, the alarm's wash
var _top: Node2D                                   # radio, bars, fades: never shake
var _stars: Array = []                            # [pos, layer, colour, phase]
var _streaks: Array = []                          # [pos, length, speed]
var _sparks: Array = []                           # [pos, vel, age, life]
var _halos := {}

var _shake := 0.0
var _fade := 1.0                                   # black over everything (the start)
var _flash := 0.0                                  # white (the cut to the planet)
var _alarm := false
var _ship_from := Vector2(-70, 112)                # in from off the left, clear of the radio's plate
var _ship_to := Vector2(150, 84)
var _checker: ImageTexture                         # a 50% dither, for the edges between the fire's bands

var _say := ""                                     # the radio line on the plate
var _break := -1                                   # where it breaks up (index), -1 never
var _shown := 0.0
var _broke := false
var _lost := false
var _faint := false
var _talking := false

var _emerge := 0                                   # 0 waiting, 1 in the doorway, 2 stepping out, 3 hopping, 4 down


func setup(player: Player, crash: CrashSite, ambience: WorldAmbience) -> void:
	_player = player
	_crash = crash
	_ambience = ambience
	_data = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	_lines = GameState.story.data["intro"]
	layer = 11
	_build()


func play() -> void:
	_crash.hold = true
	_crash.prepare_intro()
	_ambience.quiet = true
	_player.controls_enabled = false
	_player.sprite.visible = false
	_player.shadow.visible = false
	_shot = Shot.COCKPIT
	_at(0.0, func() -> void: Audio.loop("intro_cockpit_hum", "intro:hum"))
	_at(1.0, func() -> void: _radio(_text("approach", 0)))
	_at(T_ORBIT, func() -> void: _cut(Shot.ORBIT))
	_at(T_ORBIT + 0.6, func() -> void: _radio(_text("orbit", 0)))
	_at(T_ORBIT + 4.0, func() -> void: _radio(_text("orbit", 1)))
	_at(T_DESCENT, func() -> void: _cut(Shot.DESCENT))
	_at(T_DESCENT + 0.5, func() -> void: _radio(_text("descent", 0)))
	_at(T_DESCENT + 0.9, func() -> void:
		_alarm = true
		Audio.loop("intro_alarm", "intro:alarm"))
	_at(T_DESCENT + 3.4, func() -> void: _radio(_text("descent", 1)))
	_at(T_OUTSIDE, func() -> void: _cut(Shot.OUTSIDE))


func _build() -> void:
	_stage = Node2D.new()
	add_child(_stage)
	_back = Node2D.new()
	_back.draw.connect(_draw_back)
	_stage.add_child(_back)
	var p: Dictionary = _data["planet"]
	_planet = Sprite2D.new()
	_planet.texture = load(ART + p["file"])
	_planet.hframes = int(p["frames"])
	_planet.centered = false
	_stage.add_child(_planet)
	_ship = Sprite2D.new()
	_ship.texture = load(ART + _data["ship"]["file"])
	_ship.centered = false
	_stage.add_child(_ship)
	_plate = Sprite2D.new()
	_plate.texture = load(ART + _data["cockpit"]["file"])
	_plate.centered = false
	_stage.add_child(_plate)
	_pilot = AnimatedSprite2D.new()
	_pilot.sprite_frames = FRAMES
	_pilot.centered = false
	_pilot.position = _v(_data["cockpit"]["pilot"]["feet"]) - Vector2(32, 56)
	_pilot.play("idle_N")
	_stage.add_child(_pilot)
	_fx = Node2D.new()
	_fx.draw.connect(_draw_fx)
	_stage.add_child(_fx)
	_glow = Node2D.new()
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = add
	_glow.draw.connect(_draw_glow)
	_stage.add_child(_glow)
	_top = Node2D.new()
	_top.draw.connect(_draw_top)
	add_child(_top)
	var check := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	check.set_pixel(0, 0, Color.WHITE)
	check.set_pixel(1, 1, Color.WHITE)
	_checker = ImageTexture.create_from_image(check)
	var rs := RandomNumberGenerator.new()
	rs.seed = 7101
	for i in 120:
		_stars.append([Vector2(rs.randf_range(0, 384), rs.randf_range(0, 216)), rs.randi_range(1, 3),
				STAR_COLS[rs.randi() % STAR_COLS.size()], rs.randf() * TAU])
	for i in 46:
		_streaks.append([Vector2(rs.randf_range(-40, 424), rs.randf_range(0, 260)), rs.randf_range(6, 22),
				rs.randf_range(160, 320)])
	_show_shot()


# ---------------------------------------------------------------- the timeline
func _at(t: float, what: Callable) -> void:
	_beats.append([t, what])
	_beats.sort_custom(func(a, b): return a[0] < b[0])


func _cut(s: Shot) -> void:
	_shot = s
	_st = 0.0
	_fade = 1.0                                        # cut to black, and the new shot fades up
	_show_shot()
	match s:
		Shot.ORBIT:
			_planet.frame = 0
		Shot.DESCENT:
			Audio.loop("crash_roar", "intro:roar", null, 0.5)
			_pilot.play("idle_N")
			_pilot.speed_scale = 1.8
		Shot.OUTSIDE:
			_fade = 0.0
			_flash = 1.0                                   # white-out: the storm, the fall
			_say = ""
			_lost = false
			_alarm = false
			for key in ["intro:hum", "intro:alarm", "intro:roar", "intro:static"]:
				Audio.release(key)
			_ambience.quiet = false
			_crash.landed.connect(_on_landed, CONNECT_ONE_SHOT)
			_crash.finished.connect(_on_crash_over, CONNECT_ONE_SHOT)
			_crash.start_fall()


func _show_shot() -> void:
	var inside := _shot == Shot.COCKPIT or _shot == Shot.DESCENT
	_plate.visible = inside
	_pilot.visible = inside
	_planet.visible = _shot == Shot.COCKPIT or _shot == Shot.ORBIT
	_ship.visible = _shot == Shot.ORBIT
	_back.visible = _shot != Shot.OUTSIDE


## The wreck is down. Once the dust has thinned, the hatch.
func _on_landed() -> void:
	if not _crash.has_hatch():
		return
	var t := _t
	_at(t + 1.0, func() -> void: _player.camera.focus_override = _crash.door_point())
	_at(t + 1.4, func() -> void: _player.camera.set_level(0))
	_at(t + 2.4, func() -> void: _crash.thump(0.45))
	_at(t + 3.3, func() -> void: _crash.thump(1.0))
	_at(t + 4.1, func() -> void: _crash.pop_hatch())
	_at(t + 4.1 + CrashSite.LID_FLIGHT + 0.35, _step_into_doorway)


func _on_crash_over() -> void:
	if not _crash.has_hatch():
		_close()


func _step_into_doorway() -> void:
	var exit := _crash.exit_world()
	var door := _crash.doorway_world()
	var feet := _player.terrain.height_at(exit) + _crash.sill_height()
	_player.ignore_occlusion = true
	_player.sprite.visible = true
	_player.shadow.visible = true
	_player.puppet_raise(door, feet, exit - door)
	_player.sprite.modulate = Color(0.18, 0.16, 0.24)        # still in the dark of the cabin
	var tw := create_tween()
	tw.tween_property(_player.sprite, "modulate", Color.WHITE, 0.55)
	_emerge = 1
	_at(_t + 0.9, func() -> void: _emerge = 2)


func _emerge_step(delta: float) -> void:
	match _emerge:
		2:
			if _player.puppet_walk(_crash.exit_world(), 0.45, delta):
				_player.puppet_hop(70.0)
				_emerge = 3
		3:
			if _player.is_settled():
				_emerge = 4
				var t := _t
				_player.puppet = true
				_player.puppet_face(Vector2(-1, -1))              # looking round: the base, the trench
				_at(t + 0.4, func() -> void:
					_faint = true
					_radio(_text("after", 0)))
				_at(t + 1.1, func() -> void: _player.puppet_face(Vector2(1, -1)))
				_at(t + 2.2, func() -> void: _player.puppet_face(Vector2(0, -1)))
				_at(t + 3.6, _close)


## Hand the game over: bars out, the camera back on the astronaut, the controls on.
func _close() -> void:
	if _over:
		return
	_over = true
	_ending = 0.0
	_emerge = 0
	_say = ""
	Audio.release("intro:static")
	_crash.hold = false
	_ambience.quiet = false
	_player.ignore_occlusion = false
	_player.puppet = false
	_player.sprite.modulate = Color.WHITE
	_player.sprite.visible = true
	_player.shadow.visible = true
	# a beat later: the key that skipped (Space, F...) must not also jump or use the tool
	var player := _player
	get_tree().create_timer(0.2).timeout.connect(func() -> void: player.controls_enabled = true)
	_player.camera.release_focus()
	_player.camera.set_level(0)
	finished.emit()


## Any key or button: straight to the end - the wreck down and open, the astronaut beside it.
func _skip() -> void:
	if _over:
		return
	for key in ["intro:hum", "intro:alarm", "intro:roar", "intro:static"]:
		Audio.release(key)
	_beats.clear()
	_shot = Shot.OUTSIDE
	_show_shot()
	_crash.skip_to_end()
	if _crash.has_hatch():
		_player.teleport(_crash.exit_world())
		_player.puppet_face(Vector2(0, -1))
	_player.camera.focus_override = null
	_player.camera.snap()
	_fade = 0.0
	_flash = 0.0
	_close()
	_ending = 0.5                                       # the bars just go


func _input(event: InputEvent) -> void:
	if _over or _t < 0.4 or event.is_echo():
		return
	if (event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton) and event.is_pressed():
		get_viewport().set_input_as_handled()
		_skip()


func _process(delta: float) -> void:
	_t += delta
	_st += delta
	while not _beats.is_empty() and _beats[0][0] <= _t:
		var b: Array = _beats.pop_front()
		(b[1] as Callable).call()
	if _t > 0.2:
		_fade = maxf(0.0, _fade - delta / 0.7)
	_flash = maxf(0.0, _flash - delta / 0.9)
	_emerge_step(delta)
	_type(delta)
	match _shot:
		Shot.COCKPIT:
			_shake = 0.3
			_plate.modulate = Color.WHITE
			_pilot.modulate = Color.WHITE
			_planet.position = (Vector2(312, 150).lerp(Vector2(296, 124), _st / T_ORBIT) - _planet_centre()).round()
			_planet.frame = int(_t * 2.2) % _planet.hframes
		Shot.ORBIT:
			_shake = 0.0
			_planet.position = (Vector2(268, 108) - _planet_centre()).round()
			_planet.frame = int(_t * 2.2) % _planet.hframes
			var k := clampf(_st / (T_DESCENT - T_ORBIT), 0.0, 1.0)
			var e := 1.0 - pow(1.0 - k, 2.0)
			_ship.position = (_ship_from.lerp(_ship_to, e) + Vector2(0, sin(_t * 2.2) * 1.5)).round()
		Shot.DESCENT:
			_shake = 0.8 + 2.4 * clampf(_st / (T_OUTSIDE - T_DESCENT), 0.0, 1.0)
			var heat := 0.5 + 0.5 * sin(_t * 9.0)                 # the fire outside lights the cabin
			var tint := Color(1.0, 0.84 - 0.06 * heat, 0.74 - 0.08 * heat)
			_plate.modulate = tint
			_pilot.modulate = tint
		Shot.OUTSIDE:
			_shake = 0.0
	_stage.position = Vector2(randf_range(-_shake, _shake), randf_range(-_shake, _shake)).round() if _shake > 0.4 else Vector2.ZERO
	_update_sparks(delta)
	if _ending >= 0.0:
		_ending += delta
		if _ending > 1.2:
			queue_free()
	_back.queue_redraw()
	_fx.queue_redraw()
	_glow.queue_redraw()
	_top.queue_redraw()


func _planet_centre() -> Vector2:
	return _v(_data["planet"]["centre"])


# ---------------------------------------------------------------- the radio
func _text(group: String, i: int) -> String:
	return GameState.story.text(str((_lines[group] as Array)[i]))


func _radio(line: String) -> void:
	_break = line.find("|")
	_say = line.replace("|", "")
	_shown = 0.0
	_broke = false
	_talking = true
	Audio.play("intro_radio_blip")
	Audio.loop("intro_radio_static", "intro:static")
	if _shot == Shot.COCKPIT:
		_pilot.play("idle_NE")                            # a glance at the radio
		_at(_t + 1.6, func() -> void:
			if _shot == Shot.COCKPIT:
				_pilot.play("idle_N"))


func _type(delta: float) -> void:
	if _say == "":
		return
	var speed := CPS * (3.0 if _broke else 1.0) * (0.7 if _faint else 1.0)
	_shown = minf(_shown + speed * delta, float(_say.length()))
	if _break >= 0 and not _broke and _shown >= _break:
		_broke = true                                   # the storm takes the signal
		_lost = true
		Audio.play("intro_radio_glitch")
		Audio.release("intro:static")
		_pilot.play("idle_E")
		for p in _data["cockpit"]["sparks"]:
			for i in 9:
				var a := randf_range(-PI, 0.0)
				_sparks.append([_v(p), Vector2(cos(a), sin(a)) * randf_range(30.0, 90.0), 0.0, randf_range(0.3, 0.7)])
	if _talking and _shown >= _say.length():
		_talking = false
		if not _broke:
			Audio.release("intro:static")


func _update_sparks(delta: float) -> void:
	var i := 0
	while i < _sparks.size():
		var s: Array = _sparks[i]
		s[2] += delta
		if s[2] >= s[3]:
			_sparks.remove_at(i)
			continue
		s[1] += Vector2(0, 160.0) * delta
		s[0] += s[1] * delta
		i += 1


# ---------------------------------------------------------------- drawing
## Space, with the stars streaming past (the cockpit) or nearly still (the orbit); or the fire
## of re-entry, banded and streaking up past the windscreen.
func _draw_back() -> void:
	_back.draw_rect(Rect2(0, 0, 384, 216), VOID)
	if _shot == Shot.DESCENT:
		var bands := 9
		var cols: Array[Color] = []
		for b in bands:
			var k := float(b) / (bands - 1)
			var flick := 0.5 + 0.5 * sin(_t * 9.0 + b * 1.7)
			cols.append(FIRE[clampi(int(k * 4.0 + flick * 0.8), 0, FIRE.size() - 2)])
		var bh := ceilf(216.0 / bands)
		for b in bands:
			_back.draw_rect(Rect2(0, b * bh, 384, bh), cols[b])
			if b + 1 < bands:                                 # dithered seams, as the game's light steps
				_back.draw_texture_rect(_checker, Rect2(0, (b + 1) * bh - 3, 384, 3), true, cols[b + 1])
		for s in _streaks:
			var p: Vector2 = s[0] + Vector2(-0.35, -1.0) * s[2] * _st
			p = Vector2(fposmod(p.x, 424.0) - 20.0, fposmod(p.y, 260.0) - 20.0)
			var l: float = s[1]
			_back.draw_line(p.round(), (p + Vector2(0.35, 1.0) * l).round(), FIRE[4], 1.0)
			_back.draw_rect(Rect2(p.round(), Vector2.ONE), FIRE[5])
		return
	var drift := Vector2(-7.0, 2.5) if _shot == Shot.COCKPIT else Vector2(-1.2, 0.0)
	for s in _stars:
		var layer: int = s[1]
		var p: Vector2 = s[0] + drift * layer * _t
		p = Vector2(fposmod(p.x, 384.0), fposmod(p.y, 216.0)).round()
		var c: Color = s[2]
		var tw := 0.55 + 0.45 * sin(_t * 1.7 + s[3])
		c.a = (0.35 + 0.2 * layer) * tw
		_back.draw_rect(Rect2(p, Vector2.ONE * (2 if layer == 3 and s[3] > 4.5 else 1)), c)
		if _shot == Shot.COCKPIT and layer == 3:          # streaking a little
			_back.draw_rect(Rect2(p + Vector2(1, 0), Vector2.ONE), Color(c, c.a * 0.4))


## The cockpit's small lights: screens ticking over, the radio's LED while it talks, sparks.
func _draw_fx() -> void:
	if _plate.visible:
		var c: Dictionary = _data["cockpit"]
		var i := 0
		for p in c["screens"]:
			var on := sin(_t * (3.0 + i) + i * 2.1) > 0.2
			var col := ACCENT if not _alarm else (FAULT if int(_t * 6.0 + i) % 2 == 0 else TEXT)
			if on or _alarm:
				_fx.draw_rect(Rect2(_v(p) + Vector2(i % 2, 0), Vector2(2, 1)), col)
			i += 1
		if _talking or (_lost and int(_t * 8.0) % 2 == 0):
			_fx.draw_rect(Rect2(_v(c["radio"]) - Vector2(1, 1), Vector2(2, 2)), FAULT if _lost else Color("#8fff9a"))
	for s in _sparks:
		var k: float = s[2] / s[3]
		var col: Color = FIRE[5] if k < 0.3 else (FIRE[4] if k < 0.65 else FIRE[3])
		_fx.draw_rect(Rect2((s[0] as Vector2).round(), Vector2.ONE), col)


## Light: the alarm lamps and their red wash over the cabin, the ship's engines, the planet's air.
func _draw_glow() -> void:
	if _plate.visible and _alarm:
		var pulse := 0.5 + 0.5 * sin(_t * TAU * 2.0)
		_glow.draw_rect(Rect2(0, 0, 384, 216), Color(0.55, 0.06, 0.04, 0.16 * pulse))
		for p in _data["cockpit"]["alarms"]:
			_glow.draw_texture(_halo(12), _v(p) - Vector2(12, 12), Color(1.0, 0.3, 0.2, 0.9 * pulse))
	if _planet.visible:
		var c := _planet.position + _planet_centre()
		var r := int(float(_data["planet"]["radius"])) + 6
		_glow.draw_texture(_halo(r), c - Vector2(r, r), Color(0.95, 0.5, 0.35, 0.22))
	if _ship.visible:
		for e in _data["ship"]["engines"]:
			var p: Vector2 = _ship.position + _v(e)
			var fl := 0.75 + 0.25 * sin(_t * 31.0)
			_glow.draw_texture(_halo(5), p - Vector2(5, 5), Color(1.0, 0.75, 0.35, fl))


## Over everything, never shaking: the radio plate, the letterbox bars, the fades.
func _draw_top() -> void:
	if _say != "":
		_draw_radio()
	var k := 1.0 if _ending < 0.0 else clampf(1.0 - _ending / 0.6, 0.0, 1.0)
	var h := roundf(BAR * k)
	if h > 0.0:
		_top.draw_rect(Rect2(0, 0, 384, h), VOID)
		_top.draw_rect(Rect2(0, 216 - h, 384, h), VOID)
		if _ending < 0.0 and _t > 0.6:
			var hint := str(_lines.get("skip", "ANY KEY: SKIP"))
			PixelFont.draw(_top, Vector2(384 - 8 - PixelFont.width(hint), 216 - 11), hint, DIM)
	if _fade > 0.0:
		_top.draw_rect(Rect2(0, 0, 384, 216), Color(VOID, clampf(_fade, 0.0, 1.0)))
	if _flash > 0.0:
		_top.draw_rect(Rect2(0, 0, 384, 216), Color(1.0, 0.95, 0.85, _flash * _flash))


## The radio in the time panel's plate style (§7.5), as the bot's dialogue draws it: the speaker
## on a tab, the line typing out; where the storm breaks the signal the letters turn to static.
func _draw_radio() -> void:
	var r := RADIO
	var jolt := Vector2(randi_range(-1, 1), 0) if _broke and _shown < _say.length() else Vector2.ZERO
	r.position += jolt
	var alpha := (0.55 + 0.45 * float(int(_t * 9.0) % 3 != 0)) if _faint else 1.0
	_plate_rect(r, alpha)
	var speaker := str(_lines["lost"]) if _lost else str(_lines["speaker"])
	var tab := Rect2(r.position + Vector2(6, -6), Vector2(PixelFont.width(speaker) + 8, 9))
	_top.draw_rect(tab, Color(DayClock.EDGE, alpha))
	_top.draw_rect(tab.grow(-1), Color(Color("#2a1418") if _lost else Color("#1b2a33"), alpha))
	PixelFont.draw(_top, tab.position + Vector2(4, 2), speaker, Color(FAULT if _lost else ACCENT, alpha))
	var rows := BotDialogue.wrap_text(_say, int(r.size.x) - 16)
	var left := int(_shown)
	var at := 0
	var rs := RandomNumberGenerator.new()
	rs.seed = int(_t * 12.0)
	for i in rows.size():
		var row: String = rows[i]
		var x := r.position.x + 8
		var y := r.position.y + 9 + i * 8
		for ch in row:
			if at >= left:
				break
			var broken := _break >= 0 and at >= _break
			var glyph := ch
			var col := TEXT
			var dy := 0
			if broken:
				col = FAULT if rs.randf() < 0.5 else TEXT
				dy = rs.randi_range(-1, 1)
				if ch != " " and ch != "." and rs.randf() < 0.45:
					glyph = GARBLE[rs.randi() % GARBLE.length()]
			PixelFont.draw(_top, Vector2(x, y + dy), glyph, Color(col, alpha), 1, Color(DayClock.EDGE, alpha))
			x += PixelFont.width(glyph) + 1
			at += 1
		at += 1                                           # the space the wrap ate


func _plate_rect(r: Rect2, alpha: float) -> void:
	var x := r.position.x
	var y := r.position.y
	var w := r.size.x
	var h := r.size.y
	_top.draw_rect(Rect2(x + 1, y + 1, w - 2, h - 2), Color(DayClock.PLATE, DayClock.PLATE.a * alpha))
	_top.draw_rect(Rect2(x + 2, y, w - 4, 1), Color(DayClock.EDGE, alpha))
	_top.draw_rect(Rect2(x + 2, y + h - 1, w - 4, 1), Color(DayClock.EDGE, alpha))
	_top.draw_rect(Rect2(x, y + 2, 1, h - 4), Color(DayClock.EDGE, alpha))
	_top.draw_rect(Rect2(x + w - 1, y + 2, 1, h - 4), Color(DayClock.EDGE, alpha))
	for c in [Vector2(x + 1, y + 1), Vector2(x + w - 2, y + 1), Vector2(x + 1, y + h - 2), Vector2(x + w - 2, y + h - 2)]:
		_top.draw_rect(Rect2(c, Vector2.ONE), Color(DayClock.EDGE, alpha))
	_top.draw_rect(Rect2(x + 2, y + 1, w - 4, 1), Color(1, 1, 1, 0.07 * alpha))
	_top.draw_rect(Rect2(x + 2, y + h - 2, w - 4, 1), Color(FAULT if _lost else ACCENT, 0.5 * alpha))


## A soft round light, dithered in steps like the rest of the game's light (cached per radius).
func _halo(r: int) -> ImageTexture:
	if not _halos.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				var d := Vector2(x - r, y - r).length() / float(r)
				var a := clampf(1.0 - d, 0.0, 1.0)
				a = a * a
				var step := floorf(a * 4.0) / 4.0
				var frac := a * 4.0 - floorf(a * 4.0)
				if frac * 16.0 > BAYER[(y % 4) * 4 + (x % 4)]:
					step += 0.25
				img.set_pixel(x, y, Color(1, 1, 1, clampf(step, 0.0, 1.0)))
		_halos[r] = ImageTexture.create_from_image(img)
	return _halos[r]


static func _v(a: Array) -> Vector2:
	return Vector2(a[0], a[1])
