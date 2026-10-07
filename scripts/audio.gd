extends Node
## Every sound in the game goes through here (autoload: Audio).
##
## What it plays comes from assets/audio/audio.json, written by tools/sfx_gen.py: the file
## names, which bus each sound is on, how loud it is, how far away it can be heard, how much
## to wander its pitch, and whether it loops. Nothing about a sound is decided in GDScript, so
## retuning the mix is a generator change, not a code change.
##
## Three kinds of sound:
##   one-shots   play(name, at)      a footstep, a clank, a burst. Positional if given a map
##                                   pixel, flat if not. Picks one of the variants at random
##                                   and nudges its pitch, so a hundred footsteps never tick.
##   loops       loop(name, key, at) a beam, a vent, a skid. Fades in, follows its position,
##                                   and keeps playing until release(key).
##   beds        bed(name, weight)   the ambience of a land. Weight 0..1 crossfades it, which
##                                   is how the three lands blend (see WorldAmbience).
##
## Buses (amb, sfx, ui) are created here at runtime, the same way input actions are registered
## in code rather than in project.godot. Positions are map pixels: the 2D listener is the
## active Camera2D, so a sound placed on the map is heard from where the camera is.
##
## Test hook: --audio-debug makes every event print as "[audio] name ...", which is how an
## automated run proves a trigger fired - there is no screenshot for sound.

const MANIFEST := "res://assets/audio/audio.json"
## Positional sounds pan gently: the viewport is only 384 px wide, so hard panning is wrong.
const PANNING := 0.55
## How many sounds can overlap. Footsteps, sparks and debris are the ones that stack.
const VOICES := 20
const FLAT_VOICES := 6
## A loop with no fade in the manifest.
const FADE := 0.15

## Printed by every call while on (the --audio-debug test hook).
var debug := false

var _sounds := {}                       # name -> the entry from audio.json
var _streams := {}                      # file name -> AudioStream
var _free: Array[AudioStreamPlayer2D] = []
var _free_flat: Array[AudioStreamPlayer] = []
var _loops := {}                        # key -> Loop
var _rng := RandomNumberGenerator.new()
var _shut := false                      # after quiet(): stay silent, whoever asks


## One held sound: a loop or an ambience bed, fading towards a target level.
class Loop extends RefCounted:
	var player: Node                    # AudioStreamPlayer2D, or AudioStreamPlayer for a bed
	var base_db := 0.0                  # the sound's own gain from the manifest
	var db := -80.0                     # where the fade is now
	var target := 0.0                   # where it is going, relative to base_db
	var fade := 0.15
	var dying := false

	func at(p: Vector2) -> void:
		if player is AudioStreamPlayer2D:
			(player as AudioStreamPlayer2D).global_position = p.round()

	func step(delta: float) -> bool:
		var want := -80.0 if dying else target
		db = lerpf(db, want, 1.0 - exp(-delta / maxf(fade, 0.01)))
		player.volume_db = base_db + db
		if dying and db < -58.0:
			player.stop()
			player.queue_free()
			return false
		return true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # the map screen pauses the game; sound carries on
	_rng.randomize()
	_ensure_buses()
	var text := FileAccess.get_file_as_string(MANIFEST)
	if text.is_empty():
		push_warning("Audio: %s is missing - run: make sfx" % MANIFEST)
		return
	var meta: Dictionary = JSON.parse_string(text)
	_sounds = meta.get("sounds", {})
	for name in meta.get("buses", {}):
		var bus := AudioServer.get_bus_index(name)
		if bus > 0:
			AudioServer.set_bus_volume_db(bus, float(meta["buses"][name]))
	for i in VOICES:
		var p := _make_2d()
		add_child(p)
		_free.append(p)
	for i in FLAT_VOICES:
		var f := _make_flat()
		add_child(f)
		_free_flat.append(f)


## amb under everything, sfx for things that happen, ui flat and never positional.
static func _ensure_buses() -> void:
	for name in ["amb", "sfx", "ui"]:
		if AudioServer.get_bus_index(name) >= 0:
			continue
		var i := AudioServer.bus_count
		AudioServer.add_bus(i)
		AudioServer.set_bus_name(i, name)
		AudioServer.set_bus_send(i, "Master")


# ---------------------------------------------------------------- playing
## A one-shot. `at` is a map pixel, or null for a flat sound (UI). Returns the player, so a
## caller that wants to can keep tweaking it.
func play(name: String, at: Variant = null, pitch_mul := 1.0, db := 0.0) -> Node:
	var e: Dictionary = _sounds.get(name, {})
	if e.is_empty() or _shut:
		return null
	var stream := _stream(e, _rng.randi_range(0, e["files"].size() - 1), false)
	var pitch := pitch_mul
	if e.has("pitch"):
		pitch *= _rng.randf_range(e["pitch"][0], e["pitch"][1])
	var flat: bool = at == null or e.get("bus", "sfx") == "ui"
	if not flat and not _in_earshot(at as Vector2, float(e.get("dist", 400.0))):
		return null
	var p: Node = _take_flat() if flat else _take_2d()
	if p == null:
		return null
	p.stream = stream
	p.bus = e.get("bus", "sfx")
	p.volume_db = float(e.get("gain_db", -6.0)) + db
	p.pitch_scale = clampf(pitch, 0.05, 4.0)
	if not flat:
		var s := p as AudioStreamPlayer2D
		s.global_position = (at as Vector2).round()
		s.max_distance = float(e.get("dist", 400.0))
		s.panning_strength = PANNING
	p.play()
	if debug:
		print("[audio] %s%s pitch=%.2f" % [name, "" if flat else " at %v" % at, pitch])
	return p


## Start a held sound, or keep one going. `key` lets the same sound run more than once (one
## per crystal spire, say); it defaults to the sound's name. Call every frame if it moves.
func loop(name: String, key := "", at: Variant = null, weight := 1.0) -> void:
	if _shut:
		return
	if key.is_empty():
		key = name
	var l: Loop = _loops.get(key)
	if l == null:
		var e: Dictionary = _sounds.get(name, {})
		if e.is_empty():
			return
		l = Loop.new()
		l.base_db = float(e.get("gain_db", -6.0))
		l.fade = float(e.get("fade", FADE))
		var flat: bool = at == null
		l.player = _make_flat() if flat else _make_2d()
		add_child(l.player)
		l.player.stream = _stream(e, _rng.randi_range(0, e["files"].size() - 1), true)
		l.player.bus = e.get("bus", "sfx")
		l.player.volume_db = l.base_db - 80.0
		if not flat:
			var s := l.player as AudioStreamPlayer2D
			s.max_distance = float(e.get("dist", 400.0))
			s.panning_strength = PANNING
			s.global_position = (at as Vector2).round()
		l.player.play()
		_loops[key] = l
		if debug:
			print("[audio] loop %s (%s)" % [name, key])
	l.dying = false
	l.target = linear_to_db(clampf(weight, 0.0001, 1.0))
	if at != null:
		l.at(at as Vector2)


## Fade a held sound out and let it go.
func release(key: String) -> void:
	var l: Loop = _loops.get(key)
	if l != null and not l.dying:
		l.dying = true
		if debug:
			print("[audio] release %s" % key)


func is_looping(key: String) -> bool:
	var l: Loop = _loops.get(key)
	return l != null and not l.dying


## How far away a sound can still be heard, in map pixels (from audio.json). Callers use it to
## decide whether a distant thing is worth a voice at all.
func hearing(name: String) -> float:
	return float((_sounds.get(name, {}) as Dictionary).get("dist", 400.0))


## An ambience bed, mixed by weight. Weight 0 lets it go; anything above keeps it alive.
func bed(name: String, weight: float) -> void:
	if weight <= 0.004:
		release("bed:" + name)
		return
	loop(name, "bed:" + name, null, weight)


func _process(delta: float) -> void:
	for key in _loops.keys():
		if not (_loops[key] as Loop).step(delta):
			_loops.erase(key)


## Nothing is played for something nobody could hear. The map is 7751 px across and the comms
## dome's warning lights blink whether or not anyone is standing under them; without this,
## every one of them would take a voice and be mixed down to silence. The 2D listener is the
## active camera, so that is what "here" means.
func _in_earshot(at: Vector2, dist: float) -> bool:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return true
	return cam.get_screen_center_position().distance_squared_to(at) < dist * dist


## Stop everything and wait until the mixer has really let go of it.
##
## A sound still playing when the engine tears down is reported as a leaked playback: the
## mixer drops a stopped playback the next time it mixes, and during shutdown there is no next
## mix. Stopping it by hand at that point does not help either, because the removal is queued
## the same way. What works is to stop it while the game is still running - the path a
## released beam already takes - and then give the mixer real time, on the clock rather than
## in frames: a headless frame can be under a millisecond, so counting frames here would be a
## race. This is why the scenes' --quit=S hook awaits it instead of quitting outright.
func quiet() -> void:
	_shut = true                     # the ambience asks for its beds back every frame
	for key in _loops:
		_silence((_loops[key] as Loop).player)
	_loops.clear()
	for p in _free:
		_silence(p)
	for p in _free_flat:
		_silence(p)
	_free.clear()
	_free_flat.clear()
	await get_tree().create_timer(2.5).timeout
	_streams.clear()


static func _silence(p: Node) -> void:
	if not is_instance_valid(p):
		return
	p.stop()
	p.stream = null
	p.free()


## Quit the game with the sound stopped first. Anything that ends the process - a scene's
## --quit hook, a test suite reporting its result - should go through here rather than
## get_tree().quit(), so no caller has to know that audio needs winding down.
func quit(code := 0) -> void:
	await quiet()
	get_tree().quit(code)


## Closing the window gets the same treatment as far as it can: there is no chance to wait, but
## stopping first still hands the mixer the whole of the engine's teardown to let go in.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_shut = true
		for key in _loops:
			_silence((_loops[key] as Loop).player)
		_loops.clear()


## Stop everything at once, without waiting. Used when a scene is left: the next scene starts
## its own ambience, and a frame later the players are gone the ordinary way.
func enter_scene() -> void:
	for key in _loops:
		var l: Loop = _loops[key]
		l.player.stop()
		l.player.queue_free()
	_loops.clear()
	if debug:
		print("[audio] scene reset")


# ---------------------------------------------------------------- resources and voices
## Streams are cached and shared. Looping ones get their loop points set here as well as in
## the file: tools/sfx_gen.py writes a `smpl` chunk, which Godot's importer reads, but setting
## it in code too means a sound still loops if someone re-imports it with other settings.
func _stream(e: Dictionary, i: int, want_loop: bool) -> AudioStream:
	var file: String = e["files"][i]
	if not _streams.has(file):
		var s: AudioStream = load("res://assets/audio/".path_join(file))
		if s is AudioStreamWAV and (want_loop or e.get("loop", false)):
			var w := s as AudioStreamWAV
			if w.loop_mode == AudioStreamWAV.LOOP_DISABLED:
				w.loop_mode = AudioStreamWAV.LOOP_FORWARD
				w.loop_begin = 0
				w.loop_end = w.data.size() / 2 - 1     # 16-bit mono
		_streams[file] = s
	return _streams[file]


func _make_2d() -> AudioStreamPlayer2D:
	var p := AudioStreamPlayer2D.new()
	p.attenuation = 1.4            # quiet quickly: the map is 7751 px across
	p.panning_strength = PANNING
	return p


func _make_flat() -> AudioStreamPlayer:
	return AudioStreamPlayer.new()


func _take_2d() -> AudioStreamPlayer2D:
	for p in _free:
		if not p.playing:
			return p
	return null                    # all twenty busy: drop it rather than cut one off


func _take_flat() -> AudioStreamPlayer:
	for p in _free_flat:
		if not p.playing:
			return p
	return null
