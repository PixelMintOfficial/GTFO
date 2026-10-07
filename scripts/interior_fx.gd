class_name InteriorFX
extends Node2D
## Life inside the dead base: dust turning in the shafts of sun that fall through the smashed
## windows, sparks spitting from the torn wiring, gas leaking from the oxygen generator's snapped
## pipe, fault lights blinking, the reactor's broken core glowing a dim red, the empty socket on
## the power room's circuit board pulsing, and the room's name fading in as you walk into it.

const DUST := Color("#ffe6b4")
const SPARK_HOT := Color("#fff0a0")
const SPARK_COOL := Color("#ff5a1e")
const VAPOR := Color("#dff8f4")
const SOCKET := Color("#ffb24a")

var _player: Player
var _shafts: Array = []         # [PackedVector2Array hull, Rect2 bounds]
var _motes: Array = []          # [pos, vel, phase, shaft index]
var _leds: Array = []           # [pos, color, kind]
var _core := Vector2.ZERO
var _tanks: Array = []
var _spark_points: Array = []   # [pos, seconds to the next burst]
var _sparks: Array = []         # [pos, vel, age, life]
var _flashes: Array = []        # [pos, age]
var _vents: Array = []          # [pos, dir]
var _puffs: Array = []          # [pos, vel, age, life, phase]
var _socket := Vector2.ZERO
var _rooms: Array = []          # [label, center, radius]
var _room := ""
var _label := ""
var _label_t := 99.0
var _glow: Node2D
var _toast: Node2D
var _halos := {}
var _discs := {}
var _t := 0.0


func setup(meta_path: String, player: Player) -> void:
	_player = player
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	var fx: Dictionary = meta["fx"]
	for s in fx["shafts"]:
		var hull := PackedVector2Array()
		for p in s["hull"]:
			hull.append(Vector2(p[0], p[1]))
		var r := Rect2(hull[0], Vector2.ZERO)
		for p in hull:
			r = r.expand(p)
		_shafts.append([hull, r])
		for i in 34:
			_motes.append([r.position + Vector2(randf() * r.size.x, randf() * r.size.y),
					Vector2(randf_range(2.0, 6.0), randf_range(3.0, 8.0)), randf() * TAU, _shafts.size() - 1])
	for l in fx["leds"]:
		_leds.append([Vector2(l["px"][0], l["px"][1]), Color(l["color"]), l["kind"]])
	_core = _vec(fx["core"])
	for tnk in fx["tanks"]:
		_tanks.append(_vec(tnk))
	for p in fx.get("sparks", []):
		_spark_points.append([_vec(p), randf_range(0.2, 2.5)])
	for v in fx.get("vapor", []):
		_vents.append([_vec(v["px"]), _vec(v["dir"])])
	if fx.has("circuit_board"):
		_socket = _vec(fx["circuit_board"]["socket"])
	for name in meta["rooms"]:
		var rm: Dictionary = meta["rooms"][name]
		_rooms.append([rm["label"], Vector2(rm["center"][0], rm["center"][1]), float(rm["radius"])])
	_glow = Node2D.new()
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_glow.material = add
	_glow.draw.connect(_draw_glow)
	add_child(_glow)
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_toast = Node2D.new()
	_toast.draw.connect(_draw_toast)
	layer.add_child(_toast)


static func _vec(a: Array) -> Vector2:
	return Vector2(a[0], a[1])


func _process(delta: float) -> void:
	if _player == null:
		return
	_t += delta
	for m in _motes:                                     # dust drifting down the light
		var sh: Array = _shafts[m[3]]
		var r: Rect2 = sh[1]
		m[0] += (m[1] as Vector2) * delta + Vector2(sin(_t * 0.7 + m[2]) * 1.5, 0) * delta
		if not r.grow(4).has_point(m[0]):
			m[0] = r.position + Vector2(randf() * r.size.x, randf() * r.size.y * 0.3)
	_update_sparks(delta)
	_update_vapor(delta)
	for i in _vents.size():                              # the snapped pipe, still hissing
		Audio.loop("amb_gas_leak", "gas:%d" % i, _vents[i][0] as Vector2)
	var room := ""                                        # which room you are in
	for rm in _rooms:
		if _player.world_pos.distance_to(rm[1]) < rm[2] - 4.0:
			room = rm[0]
	if room != "" and room != _room:
		_label = room
		_label_t = 0.0
		Audio.play("ui_room")
	if room != "":
		_room = room
	_label_t += delta
	queue_redraw()
	_glow.queue_redraw()
	_toast.queue_redraw()


## Torn wiring spits a few sparks now and then: sometimes one, sometimes a crackling run.
func _update_sparks(delta: float) -> void:
	for sp in _spark_points:
		sp[1] -= delta
		if sp[1] > 0.0:
			continue
		var n := randi_range(9, 18)
		for i in n:
			var a := randf_range(-PI * 0.97, -PI * 0.03)
			_sparks.append([sp[0] as Vector2, Vector2(cos(a), sin(a)) * randf_range(30.0, 95.0), 0.0, randf_range(0.35, 0.85)])
		_flashes.append([sp[0] as Vector2, 0.0])
		Audio.play("spark", sp[0] as Vector2)
		sp[1] = randf_range(0.08, 0.2) if randf() < 0.35 else randf_range(1.2, 4.0)
	var i := 0
	while i < _sparks.size():
		var s: Array = _sparks[i]
		s[2] += delta
		if s[2] >= s[3]:
			_sparks.remove_at(i)
			continue
		s[1] += Vector2(0, 170.0) * delta
		s[0] += (s[1] as Vector2) * delta
		i += 1
	i = 0
	while i < _flashes.size():
		_flashes[i][1] += delta
		if _flashes[i][1] > 0.16:
			_flashes.remove_at(i)
			continue
		i += 1


## The snapped pipe hisses out a steady jet that slows, swells, rises and thins away.
func _update_vapor(delta: float) -> void:
	for v in _vents:
		if randf() < 14.0 * delta:
			var d: Vector2 = (v[1] as Vector2).rotated(randf_range(-0.25, 0.25))
			_puffs.append([v[0] as Vector2, d * randf_range(22.0, 34.0), 0.0, randf_range(1.1, 1.8), randf() * TAU])
	var i := 0
	while i < _puffs.size():
		var p: Array = _puffs[i]
		p[2] += delta
		if p[2] >= p[3]:
			_puffs.remove_at(i)
			continue
		p[1] = (p[1] as Vector2) * pow(0.25, delta) + Vector2(sin(_t * 3.0 + p[4]) * 4.0, -9.0) * delta
		p[0] += (p[1] as Vector2) * delta
		i += 1


func _draw() -> void:
	for p in _puffs:                                     # leaking gas
		var k: float = p[2] / p[3]
		var r := int(round(lerpf(1.0, 4.5, sqrt(k))))
		_disc(self, p[0], r, Color(VAPOR, 0.42 * (1.0 - k) * minf(1.0, k * 8.0)))
	# sparks: solid so they show on the white machines, cooling from yellow to orange
	for s in _sparks:
		var k: float = s[2] / s[3]
		var col := SPARK_HOT.lerp(SPARK_COOL, k)
		var p: Vector2 = (s[0] as Vector2).round()
		var tail: Vector2 = ((s[0] as Vector2) - (s[1] as Vector2) * 0.05).round()   # a streak behind
		if tail != p:
			draw_line(tail + Vector2(0.5, 0.5), p + Vector2(0.5, 0.5), Color(SPARK_COOL, 0.85 * (1.0 - k)), 1.0)
		draw_rect(Rect2(p, Vector2(2, 2) if k < 0.35 else Vector2.ONE), col)
	for f in _flashes:                                   # the short: a white-hot star
		var c: Vector2 = (f[0] as Vector2).round()
		var r := 3 if f[1] < 0.08 else 2
		var col := Color(1.0, 0.98, 0.85, 1.0 - f[1] / 0.16)
		draw_rect(Rect2(c - Vector2(r, 0), Vector2(2 * r + 1, 1)), col)
		draw_rect(Rect2(c - Vector2(0, r), Vector2(1, 2 * r + 1)), col)
		draw_rect(Rect2(c - Vector2(1, 1), Vector2(3, 3)), Color(1, 1, 0.9, col.a))


func _draw_glow() -> void:
	for sh in _shafts:                                   # the light breathing a little
		_glow.draw_colored_polygon(sh[0], Color(1.0, 0.8, 0.5, 0.035 + 0.025 * sin(_t * 0.8)))
	for m in _motes:
		var sh: Array = _shafts[m[3]]
		if Geometry2D.is_point_in_polygon(m[0], sh[0]):
			var a := 0.45 + 0.45 * sin(_t * 2.3 + m[2] * 3.0)
			_glow.draw_rect(Rect2((m[0] as Vector2).round(), Vector2.ONE), Color(DUST, a))
	for l in _leds:
		var on := true
		if l[2] == "fault":
			var c := fmod(_t + l[0].x * 0.003, 1.4)
			on = c < 0.12 or (c > 0.28 and c < 0.4)
		else:
			on = fmod(_t, 2.6) < 1.3
		if on:
			_halo(l[0], 6, Color(l[1], 0.5))
			_glow.draw_rect(Rect2((l[0] as Vector2).round(), Vector2.ONE), Color(1, 0.9, 0.85, 1))
	# the broken core: an ember that flares when the wiring shorts
	var flare := 0.0
	for f in _flashes:
		if (f[0] as Vector2).distance_to(_core) < 40.0:
			flare = maxf(flare, 1.0 - f[1] / 0.16)
	_halo(_core, 14, Color(1.0, 0.25, 0.18, 0.14 + 0.07 * sin(_t * 1.2) + 0.2 * flare))
	for tk in _tanks:
		if fmod(_t + tk.x * 0.01, 3.0) < 0.2:
			_glow.draw_rect(Rect2((tk as Vector2).round(), Vector2.ONE), Color(0.5, 1.0, 0.9, 0.9))
	for f in _flashes:
		_halo(f[0], 9, Color(1.0, 0.7, 0.35, 0.6 * (1.0 - f[1] / 0.16)))
	if _socket != Vector2.ZERO:                          # the empty socket, where a part has to go
		var pulse := 0.5 + 0.5 * sin(_t * 3.2)
		_halo(_socket, 5, Color(SOCKET, 0.18 + 0.22 * pulse))
		var r := Rect2(_socket.round() - Vector2(4, 4), Vector2(9, 9))
		var c := Color(SOCKET, 0.35 + 0.5 * pulse)
		for corner in [r.position, Vector2(r.end.x - 2, r.position.y), Vector2(r.position.x, r.end.y - 2), r.end - Vector2(2, 2)]:
			_glow.draw_rect(Rect2(corner, Vector2(2, 2)), c)


## The room's name, big, fading in at the top of the screen.
func _draw_toast() -> void:
	if _label == "" or _label_t > 2.6:
		return
	var a := clampf(_label_t / 0.4, 0.0, 1.0) * clampf((2.6 - _label_t) / 0.6, 0.0, 1.0)
	var view := get_viewport_rect().size
	var w := PixelFont.width(_label, 2)
	var pos := Vector2(round((view.x - w) / 2.0), 14.0)
	_toast.draw_rect(Rect2(pos - Vector2(8, 5), Vector2(w + 16, 20)), Color(0.07, 0.06, 0.11, 0.7 * a))
	_toast.draw_rect(Rect2(pos + Vector2(-8, 16), Vector2(w + 16, 1)), Color(1.0, 0.45, 0.33, a))
	PixelFont.draw(_toast, pos, _label, Color(0.96, 0.95, 1.0, a), 2, Color(0.1, 0.08, 0.16, a))


func _halo(center: Vector2, r: int, col: Color) -> void:
	if not _halos.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var bayer := [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
		for y in size:
			for x in size:
				var d := Vector2(x - r, y - r).length() / float(r)
				if d > 1.0:
					continue
				var lv := floorf(pow(1.0 - d, 1.6) * 3.0 + (bayer[(y % 4) * 4 + x % 4] + 0.5) / 16.0)
				if lv > 0.0:
					img.set_pixel(x, y, Color(1, 1, 1, minf(lv, 3.0) / 3.0))
		_halos[r] = ImageTexture.create_from_image(img)
	_glow.draw_texture(_halos[r], (center - Vector2(r, r)).round(), col)


## A solid pixel disc.
func _disc(canvas: CanvasItem, center: Vector2, r: int, col: Color) -> void:
	if not _discs.has(r):
		var size := 2 * r + 1
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		for y in size:
			for x in size:
				if Vector2(x - r, y - r).length() <= r + 0.3:
					img.set_pixel(x, y, Color.WHITE)
		_discs[r] = ImageTexture.create_from_image(img)
	canvas.draw_texture(_discs[r], (center - Vector2(r, r)).round(), col)
