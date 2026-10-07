extends Node
## Native visual QA for the whole repair sequence. Runs real pointer welding, captures
## the flat machine casing, hot seam/sparks, transient seal glow, then fixed world art
## by day/night from all four headings. Run crack_gallery.tscn -- --out=ABSOLUTE_DIRECTORY.

var _out := "res://shots/crack-repair"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	GameState.machine_repairs.clear()
	GameState.reset_inventory()
	GameState.heading = 0
	GameState.clock = 12
	for i in 6:
		GameState.store_item("scrap")
	var room := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await get_tree().process_frame
	await get_tree().process_frame
	for machine in ["power", "oxygen"]:
		room.repairs.open_machine(machine)
		var panel: CrackRepairUI = room.repairs.crack_panel
		var model := panel.model
		await _pointer(panel, Vector2(341, 199), false)
		await _shot(machine + "-cracks")
		for i in 3:
			await _pointer(panel, CrackRepairUI._slot(i).get_center(), true)
			await _pointer(panel, CrackRepairUI._slot(i).get_center(), false)
			await _pointer(panel, model.sites[i], true)
			await _pointer(panel, model.sites[i], false)
		await _shot(machine + "-placed")
		for i in 3:
			var seam := model.seams[i]
			await _pointer(panel, seam[0], true)
			var traveled := 0.0
			var captured := false
			# Unfocused GUI windows run at a lower frame rate. Move at a measured pixel/sec
			# speed rather than advancing one recorded pixel per frame.
			while traveled < seam.size() + 5:
				await get_tree().process_frame
				traveled += 65 * get_process_delta_time()
				var j := int(traveled) % seam.size()
				var point := seam[j].lerp(seam[(j + 1) % seam.size()], fmod(traveled, 1))
				var motion := InputEventMouseMotion.new()
				motion.position = panel._canvas.get_global_transform() * point
				get_viewport().push_input(motion, true)
				if i == 0 and traveled > 30 and not captured:
					captured = true
					await _shot(machine + "-welding")
			await _pointer(panel, seam[0], false)
			if model.sealed[i] != 1:
				push_error("Native pointer failed to seal %s hole %d: coverage %.3f heat %.3f" % [machine, i, model.coverage(i), model.heat])
				await Audio.quit(1)
				return
			await _shot(machine + "-glow-%d" % i)
		await get_tree().create_timer(1.05).timeout
		await _shot(machine + "-cooled")
		await _pointer(panel, CrackRepairUI.NEXT.get_center(), true)
		await _pointer(panel, CrackRepairUI.NEXT.get_center(), false)
		var repair := GameState.repair_for(machine)
		for cell in CircuitCatalog.route(repair.puzzle.definition):
			var tile := cell.y * repair.puzzle.cols + cell.x
			for turn in 4:
				if repair.puzzle.solved or repair.puzzle.masks[tile] == repair.puzzle.solution[tile]:
					break
				repair.rotate(tile)
		await get_tree().create_timer(CircuitPowerFlow.DURATION + .1).timeout
		room.repairs.panel.close()
		await get_tree().process_frame
		await get_tree().process_frame
		for info in room.repairs.machines:
			if info["id"] == machine:
				room.player.teleport(Vector2(info["stand_world"][0], info["stand_world"][1]))
		for hour in [12, 22]:
			GameState.clock = hour
			for heading in 4:
				room._apply_view(heading, room.player.facing_dir())
				await get_tree().create_timer(.15).timeout
				await _shot("%s-fixed-%d-view-%d" % [machine, hour, heading])
	print("Crack gallery: both native pointer repairs completed; day/night and all views captured.")
	room.queue_free()
	await Audio.quit()


func _pointer(panel: CrackRepairUI, point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = panel._canvas.get_global_transform() * point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	# GUI builds have window stretch; these recorded points are already viewport-local.
	get_viewport().push_input(event, true)
	await get_tree().process_frame


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_out.path_join(name + ".png"))
