extends Node
## Optional renderer QA: --script res://tests/repair_gallery.gd is not used; run the
## repair_gallery.tscn scene with -- --out=ABSOLUTE_DIRECTORY. Writes all ten panels.
## Also captures the completion flight as frames for a native animation preview.


func _ready() -> void:
	var out := "res://.godot/repair-gallery"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(out)
	var room := load("res://scenes/interior.tscn").instantiate() as Node2D
	get_tree().root.add_child.call_deferred(room)
	await get_tree().process_frame
	await get_tree().process_frame
	for machine_id in ["power", "oxygen"]:
		var repair := GameState.repair_for(machine_id)
		room.repairs.open_machine(machine_id)
		room.repairs.panel.set_process_input(false)
		for index in 5:
			if index > 0:
				repair.advance(30.0)
			await get_tree().create_timer(0.18).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out.path_join("%s-%d.png" % [machine_id, index + 1]))
		for cell in CircuitCatalog.route(repair.puzzle.definition):
			var tile := cell.y * repair.puzzle.cols + cell.x
			for turn in 4:
				if repair.puzzle.solved or repair.puzzle.masks[tile] == repair.puzzle.solution[tile]:
					break
				repair.rotate(tile)
		var timing := []
		for frame in 40:
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(out.path_join("%s-flow-%02d.png" % [machine_id, frame]))
			timing.append(room.repairs.panel._flow.elapsed if room.repairs.panel._flow != null else 0.0)
			await get_tree().create_timer(0.06).timeout
		var timeline := FileAccess.open(out.path_join(machine_id + "-timing.json"), FileAccess.WRITE)
		timeline.store_string(JSON.stringify(timing))
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out.path_join(machine_id + "-connected.png"))
		room.repairs.panel.close()
	room.queue_free()
	await Audio.quit()
