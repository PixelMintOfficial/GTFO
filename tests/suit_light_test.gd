extends Node
## Checks for the lamp on the astronaut's suit (SuitLight), against the real overworld, the real
## interior and real key presses: it starts off, L switches it on and off, it is worth nothing at
## noon and everything at night, it is a beam on the astronaut's chest pointing the way they
## face, it keeps pointing that way through the camera's turns, an open backpack swallows the key
## instead of switching it, and it comes through the airlock as you left it.
## Real jumps must carry the beam with the raised sprite through takeoff, apex and landing;
## on a cargo box and during camera reliefs its origin stays on the same suit position.
## Run: godot --headless --path . res://tests/suit_light_test.tscn  (failures exit nonzero)
## Add -- --audio-debug to hear (in print) the switch fire as the key is pressed.
## Native evidence: -- --gallery=shots/suit-jump (omit --headless).

var _checks := 0
var _failures := 0
var _gallery := ""


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("SUIT LIGHT TEST: " + label)


func _tap(code: int) -> void:
	for pressed in [true, false]:
		await _key(code, pressed)


func _key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	await get_tree().process_frame
	await get_tree().process_frame


func _settle(scene: Node) -> void:
	var turn: ViewTurn = scene.view_turn
	for i in 400:
		if not turn.busy:
			break
		await get_tree().process_frame
	await get_tree().process_frame


func _scene(path: String) -> Node:
	var scene: Node = load(path).instantiate()
	get_tree().root.add_child.call_deferred(scene)
	await get_tree().process_frame
	await get_tree().process_frame
	return scene


func _lamp_of(scene: Node) -> SuitLight:
	for n in scene.get_children():
		if n is SuitLight:
			return n
	return null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--gallery="):
			_gallery = arg.trim_prefix("--gallery=")
	if not _gallery.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_gallery))
	Audio.debug = OS.get_cmdline_user_args().has("--audio-debug")   # there is no screenshot for sound
	await _overworld()
	await _interior()
	print("SUIT LIGHT TESTS: %d checks, %d failures" % [_checks, _failures])
	await Audio.quit(1 if _failures else 0)


func _overworld() -> void:
	GameState.reset_inventory()
	GameState.survival.reset()
	GameState.intro_done = true
	GameState.arrive = ""
	GameState.heading = 0
	GameState.suit_light = false
	GameState.clock = 22.0                                # day 1, deep night
	var world := await _scene("res://scenes/overworld.tscn")
	var player: Player = world.get_node("Actors/Player")
	var lamp := _lamp_of(world)
	_check(lamp != null and not lamp.on() and not GameState.suit_light, "the game starts with the lamp off")
	_check(lamp.lamp_vector().w == 0.0, "an unlit lamp throws nothing")

	await _tap(KEY_L)
	_check(lamp.on() and GameState.suit_light, "L switches it on")
	_check(lamp.lamp_vector().w > 0.3, "at night it lights the ground (%.2f)" % lamp.lamp_vector().w)
	_check(is_equal_approx(lamp.lamp_vector().w, lamp.strength * DayNight.night), "as far as the dark goes")
	await _tap(KEY_L)
	_check(not lamp.on() and lamp.lamp_vector().w == 0.0, "L again switches it off")
	await _tap(KEY_L)

	# Noon: the beam is worth nothing, so it can never wash the daylight out.
	var night := GameState.clock
	GameState.clock = 12.0
	await get_tree().process_frame
	await get_tree().process_frame
	_check(lamp.on() and lamp.lamp_vector().w == 0.0, "lit, it still does nothing at noon")
	GameState.clock = night
	await get_tree().process_frame
	await get_tree().process_frame

	# A beam on the chest, not a bulb at the feet.
	var at := lamp.lamp_vector()
	_check(is_equal_approx(at.x, player.global_position.x)
			and is_equal_approx(at.y, player.global_position.y - SuitLight.CHEST), "it sits on the chest")
	_check(at.z < 200.0, "and only throws a few strides (%.0f map px)" % at.z)
	player.facing = "E"
	await get_tree().process_frame
	var east := lamp.beam_vector()
	_check(east.x > 0.9 and absf(east.y) < 0.2, "facing east the beam points east (%.2f, %.2f)" % [east.x, east.y])
	player.facing = "N"
	await get_tree().process_frame
	var north := lamp.beam_vector()
	_check(north.y < -0.9, "facing away from the camera it points up the screen (%.2f)" % north.y)
	_check(north.z > 0.3 and north.z < 0.99, "it is a cone, not a circle (cos %.2f)" % north.z)
	_check(north.w > 0.0 and north.w < 0.6, "with a small pool spilling round the feet (%.2f)" % north.w)
	await _jump(world, "outside")

	# The astronaut keeps facing the same way in the world through a turn, so the beam swings a
	# quarter turn with the camera and comes back to where it started after four.
	var start := SuitLight.beam_dir(player.terrain, player)
	var last := start
	for k in 4:
		await _tap(KEY_H)
		await _settle(world)
		var now := SuitLight.beam_dir(player.terrain, player)
		_check(is_equal_approx(now.length(), 1.0), "view %d: the beam still has a direction" % player.terrain.heading)
		_check(absf(now.dot(last)) < 0.1, "view %d: it turned the quarter turn with the camera" % player.terrain.heading)
		last = now
	_check(player.terrain.heading == 0 and start.distance_to(last) < 0.01, "four turns bring it back")
	if not _gallery.is_empty():
		for heading in [1, 2]:
			world._apply_view(heading, player.facing_dir())
			await _jump(world, "outside-view-%d" % heading)
		world._apply_view(0, player.facing_dir())
		GameState.clock = 12.0
		await _jump(world, "outside-day")
		GameState.clock = night

	# An open backpack pauses the world and swallows the key.
	var bag: InventoryUI
	for n in world.get_children():
		if n is InventoryUI:
			bag = n
	bag.toggle()
	await get_tree().process_frame
	_check(bag.opened, "the backpack is open")
	await _tap(KEY_L)
	_check(lamp.on(), "it does not switch the lamp")
	bag.toggle()
	await get_tree().process_frame
	await _tap(KEY_L)
	_check(not lamp.on(), "and the key works again once the backpack is shut")

	GameState.suit_light = true                           # carry it through the airlock
	world.queue_free()
	await get_tree().process_frame


func _interior() -> void:
	GameState.arrive = ""
	GameState.heading = 0
	var base := await _scene("res://scenes/interior.tscn")
	var lamp := _lamp_of(base)
	_check(lamp != null and lamp.on(), "the lamp comes through the airlock still lit")
	_check(lamp.lamp_vector().w > 0.0, "and it lights the dead base at night")
	await _jump(base, "inside")
	# A stationary raised platform uses the same sprite offset as jumping.
	var player: Player = base.get_node("Actors/Player")
	var box: WorldProp = base.cracks.box
	player.teleport(box.world)
	await get_tree().physics_frame
	await get_tree().process_frame
	_check(player.height_above_floor() >= box.top - .1, "standing on cargo box raises the astronaut")
	_check(is_equal_approx(lamp.lamp_vector().y, player.sprite.global_position.y - SuitLight.CHEST), "box-top beam stays on the suit")
	var view := TurnOverlay.view_info(base.terrain, player.camera, player)
	_check((view.get("lamp_px", Vector2.INF) as Vector2).distance_to(Vector2(lamp.lamp_vector().x, lamp.lamp_vector().y)) < .01,
			"camera relief carries the same raised lamp origin")
	base.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(SuitLight.published.w == 0.0, "leaving a scene takes the lamp with it")
	GameState.suit_light = false


func _shot(scene: Node, label: String) -> void:
	if _gallery.is_empty():
		return
	var hidden: Array[CanvasLayer] = []
	for child in scene.get_children():
		if child is InventoryUI or child is SurvivalHUD:
			hidden.append(child)
			child.visible = false
	await RenderingServer.frame_post_draw
	_check(get_viewport().get_texture().get_image().save_png(_gallery.path_join(label + ".png")) == OK, "capture " + label)
	for child in hidden:
		child.visible = true


func _jump(scene: Node, label: String) -> void:
	var player: Player = scene.get_node("Actors/Player")
	var lamp := _lamp_of(scene)
	player.facing = "E"
	await get_tree().physics_frame
	await get_tree().process_frame
	await get_tree().process_frame                     # let DayNight publish any capture-time clock change
	var ground := lamp.lamp_vector()
	var floor_position := player.global_position
	await _shot(scene, label + "-ground")
	await _key(KEY_SPACE, true)
	var rising := false
	var apex := false
	var landed := false
	for i in 240:
		await get_tree().physics_frame
		await get_tree().process_frame
		var above := player.height_above_floor()
		if player.is_airborne() and above > 6.0 and not rising:
			rising = true
			var at := lamp.lamp_vector()
			_check(player.global_position.distance_to(floor_position) < .01, label + ": ground sort position stays put")
			_check(at.y < ground.y - 8.0, label + ": beam rises off the ground with the astronaut")
			_check(is_equal_approx(at.y, player.sprite.global_position.y - SuitLight.CHEST), label + ": rising origin stays on suit")
			_check(is_equal_approx(at.w, ground.w) and at.z == ground.z, label + ": jumping preserves light strength and reach")
			await _shot(scene, label + "-rising")
		if rising and player._vz <= 0 and not apex:
			apex = true
			_check(is_equal_approx(lamp.lamp_vector().y, player.sprite.global_position.y - SuitLight.CHEST), label + ": apex origin stays on suit")
			await _shot(scene, label + "-apex")
			await _key(KEY_SPACE, false)
		if apex and not player.is_airborne() and above < .1:
			landed = true
			_check(is_equal_approx(lamp.lamp_vector().y, ground.y), label + ": landing restores the original ground light")
			await _shot(scene, label + "-landed")
			break
	await _key(KEY_SPACE, false)
	_check(rising and apex and landed, label + ": real jump reaches takeoff, apex and landing")
	# Let the landing pose finish before another input or camera turn.
	await get_tree().create_timer(.25).timeout
