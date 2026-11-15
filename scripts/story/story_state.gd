class_name StoryState
extends RefCounted
## The opening chapter, for the session (GameState.story): the bot asleep in its cradle in storage,
## woken with the multitool; the name it calls you by; maintenance access, which opens the bulkheads to
## the power and oxygen rooms; ordered oxygen/glass/generator/solar guidance and seven
## checklist tasks; nursery player tasks/cleanup fractions; independent body session positions.
## Survives the airlock, camera turns and rescue. Every name and line comes from
## data/bot_story.json (names, tokens {BOT} {OWNER} {NAME} {PLANET}); nothing is written here.
## The opening cutscene's radio lines live there too ("intro"), read by IntroCutscene through text().
## The player's name is remembered between launches as a preference (PlayerProfile).
## F1 can complete/reset the nursery body independently of the main introduction and crops.
## Comms objectives reflect the current screen, power and signal state in GameState.

signal changed

const DATA := "res://data/bot_story.json"

var data: Dictionary = {}
## The bot has been woken (it stays awake).
var bot_awake := false
## You have told it your name this session.
var named := false
## Maintenance access unlocked: bulkheads open, but main power remains off.
var access_opened := false
## The bot has handed out the objectives (the objective line shows them).
var objectives_given := false
## Your name, as the bot says it.
var player_name := ""
## Lore lines heard: id -> true.
var heard := {}
## Stages explicitly explained by UNIT; a newly reached stage raises the news marker.
var guidance_seen := {}
## Main maintenance body world position, or null while it is in its cradle.
var bot_world: Variant = null
## UNIT shares its mind with a second, initially broken nursery maintenance body.
var body_repair_progress := {}
var nursery_awake := false
var nursery_introduced := false
var nursery_bot_world: Variant = null
## Per-pile vacuum fractions; actual nursery litter disappears only on completed cleaning.
var cleanup_progress := {}
## Active-play roaming delay before each body's next random real cleanup job.
var maintenance_waits := {}


func body_awake(body: String) -> bool:
	return nursery_awake if body == "nursery" else bot_awake


func wake_body(body: String) -> void:
	if body == "nursery":
		nursery_awake = true
		changed.emit()
	else:
		wake()


func debug_complete_nursery(completed: bool) -> void:
	if not OS.is_debug_build():
		return
	nursery_awake = completed
	nursery_introduced = completed
	if completed:
		body_repair_progress["nursery"] = 1.0
	else:
		body_repair_progress.erase("nursery")
		nursery_bot_world = null
		maintenance_waits.erase("nursery")
	changed.emit()


func has_news(body := "base") -> bool:
	if body == "nursery" and not nursery_introduced:
		return nursery_awake
	return objectives_given and not guidance_seen.has(active_stage())


func _init() -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	player_name = PlayerProfile.load_name()


## A line from the data with its names filled in.
func text(line: String) -> String:
	var names: Dictionary = data["names"]
	return line.replace("{BOT}", names["bot"]).replace("{OWNER}", names["previous_owner"]).replace("{NAME}", player_name) \
			.replace("{PLANET}", names.get("planet", "ARAXYS")) \
			.replace("{TURN_LEFT}", _key_label("turn_left", "G")).replace("{TURN_RIGHT}", _key_label("turn_right", "H"))


func _key_label(action: String, fallback: String) -> String:
	if InputMap.has_action(action):
		for event in InputMap.action_get_events(action):
			if event is InputEventKey:
				return OS.get_keycode_string(event.physical_keycode if event.physical_keycode else event.keycode)
	return fallback


func lines(key: String) -> Array:
	return (data[key] as Array).map(func(l: String) -> String: return text(l))


func set_name(value: String, remember := true) -> void:
	player_name = value.strip_edges().to_upper()
	named = true
	if remember:
		PlayerProfile.save_name(player_name)
	changed.emit()


func wake() -> void:
	bot_awake = true
	changed.emit()


func unlock_access() -> void:
	access_opened = true
	changed.emit()


func give_objectives() -> void:
	objectives_given = true
	guidance_seen[active_stage()] = true
	changed.emit()


## The objectives, once handed out: [{id, label, done}].
func objectives(context := "base") -> Array:
	if context == "nursery":
		return nursery_objectives()
	if not objectives_given:
		return []
	return (data["objectives"] as Array).map(func(o: Dictionary) -> Dictionary:
		return {"id": o["id"], "label": text(o["label"]), "done": objective_done(o["id"])})


func objective_done(id: String) -> bool:
	if id == "glass":
		return GameState.window_repair.all_fixed(["burst", "crescent", "gash"])
	if id == "feeds":
		return GameState.solar_field.feeds.all(func(open: bool) -> bool: return open)
	for objective in data["objectives"]:
		if objective["id"] != id: continue
		if objective.has("machine"):
			return GameState.repair_for(objective["machine"]).progress() >= 1.
		if objective.has("route"):
			return GameState.solar_field.routes[int(objective["route"])]["connected"]
	return false


func comms_objectives(context: String) -> Array:
	var mission := GameState.comms_mission
	if context != "comms" and not mission.has_transmitted() and not GameState.base_powered():
		return []
	var labels: Dictionary = data["comms"]
	var label: String = labels["send"]
	var stage := mission.stage(GameState.clock)
	match stage:
		CommsMission.Stage.READY:
			if GameState.comms_repair_progress < 1.0:
				label = labels["repair"] if context == "comms" else labels["travel"]
			elif not GameState.base_powered():
				label = labels["power"]
		CommsMission.Stage.OUTBOUND:
			label = labels["outbound"] % mission.minutes_left(GameState.clock, stage)
		CommsMission.Stage.INBOUND:
			label = labels["inbound"] % mission.minutes_left(GameState.clock, stage)
		CommsMission.Stage.RECEIVER_OFFLINE:
			label = labels["offline"]
		CommsMission.Stage.RECEIVED:
			label = labels["received"] if mission.reply_shown else labels["unread"]
	return [{"id": "comms_sos", "label": label, "done": mission.reply_received}]


func active_stage() -> String:
	for stage in ["oxygen", "glass", "power"]:
		if not objective_done(stage): return stage
	return "done" if GameState.base_powered() else "solar"


func guidance() -> Array:
	return (data["guidance"][active_stage()] as Array).map(func(line: String) -> String: return text(line))


func all_done(context := "base") -> bool:
	if context == "nursery":
		return nursery_objectives().all(func(o: Dictionary) -> bool: return o["done"])
	for o in data["objectives"]:
		if not objective_done(o["id"]):
			return false
	return true


## Nursery tasks stay visible independently of the base's opening conversation.
func nursery_objectives() -> Array:
	var cultivation := GameState.cultivation
	var counts := {"food": 0, "water": 0}
	for bed in cultivation.beds.values(): counts[bed["kind"]] += 1
	var out := []
	for item in data["nursery_objectives"]:
		var id: String = item["id"]
		var done := false
		var label: String = item["label"]
		match id:
			"unit": done = nursery_awake
			"console", "light", "rack": done = cultivation.repaired(id)
			"food", "water":
				var total := 0
				for kind in cultivation.config["beds"].values():
					if kind == id: total += 1
				done = counts[id] == total
				label += " %d/%d" % [counts[id], total]
			"food_harvest": done = cultivation.harvested.has("food")
			"water_harvest": done = cultivation.harvested.has("water")
		out.append({"id": id, "label": text(label), "done": done})
	return out


## What the bot says when you talk to it again: lore whose moment has come first, then where you
## are with the objectives, then one piece of trivia you have not heard. Marks lore heard.
func next_talk() -> Array:
	var stage := active_stage()
	if not guidance_seen.has(stage):
		guidance_seen[stage] = true
		changed.emit()
		return guidance()
	var out := guidance()
	for lore in data["lore"]:
		if lore["trigger"] == "talk" and not heard.has(lore["id"]):
			heard[lore["id"]] = true
			out.append_array((lore["lines"] as Array).map(func(line: String) -> String: return text(line)))
			break
	return out


## Tests/screenshots: the bot awake/named, maintenance access open, objectives handed out.
func skip_intro(name := "TESTER") -> void:
	bot_awake = true
	player_name = name
	named = true
	access_opened = true
	objectives_given = true
	changed.emit()
