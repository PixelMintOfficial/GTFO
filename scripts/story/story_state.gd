class_name StoryState
extends RefCounted
## The opening chapter, for the session (GameState.story): the bot asleep in its cradle in storage,
## woken with the multitool; the name it calls you by; reserve power, which opens the bulkheads to
## the power and oxygen rooms; the two objectives it hands out; the lore lines you have heard;
## where the bot was last, following you round the base.
## Survives the airlock, camera turns and rescue. Every name and line comes from
## data/bot_story.json (names, tokens {BOT} {OWNER} {NAME}); nothing is written here.
## The player's name is remembered between launches as a preference (PlayerProfile).

signal changed

const DATA := "res://data/bot_story.json"

var data: Dictionary = {}
## The bot has been woken (it stays awake).
var bot_awake := false
## You have told it your name this session.
var named := false
## Reserve power is on: the emergency lines lit, the bulkheads open.
var reserve_power := false
## The bot has handed out the objectives (the objective line shows them).
var objectives_given := false
## Your name, as the bot says it.
var player_name := ""
## Lore lines heard: id -> true.
var heard := {}
## Where the bot was last, following you round the base (world), or null: still in its cradle.
var bot_world: Variant = null


func _init() -> void:
	data = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	player_name = PlayerProfile.load_name()


## A line from the data with its names filled in.
func text(line: String) -> String:
	var names: Dictionary = data["names"]
	return line.replace("{BOT}", names["bot"]).replace("{OWNER}", names["previous_owner"]).replace("{NAME}", player_name)


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


func power_reserve() -> void:
	reserve_power = true
	changed.emit()


func give_objectives() -> void:
	objectives_given = true
	changed.emit()


## The objectives, once handed out: [{id, label, done}].
func objectives() -> Array:
	if not objectives_given:
		return []
	return (data["objectives"] as Array).map(func(o: Dictionary) -> Dictionary:
		return {"id": o["id"], "label": text(o["label"]), "done": objective_done(o["id"])})


func objective_done(id: String) -> bool:
	for o in data["objectives"]:
		if o["id"] == id:
			return GameState.repair_for(o["machine"]).progress() >= 1.0
	return false


func all_done() -> bool:
	for o in data["objectives"]:
		if not objective_done(o["id"]):
			return false
	return true


## What the bot says when you talk to it again: lore whose moment has come first, then where you
## are with the objectives, then one piece of trivia you have not heard. Marks lore heard.
func next_talk() -> Array:
	for l in data["lore"]:
		if l["trigger"] != "talk" and not heard.has(l["id"]) and _triggered(l["trigger"]):
			heard[l["id"]] = true
			return (l["lines"] as Array).map(func(s: String) -> String: return text(s))
	var out := [text(data["remind"][_remind_key()])]
	for l in data["lore"]:
		if l["trigger"] == "talk" and not heard.has(l["id"]):
			heard[l["id"]] = true
			out.append_array((l["lines"] as Array).map(func(s: String) -> String: return text(s)))
			break
	return out


func _remind_key() -> String:
	var power := objective_done("power")
	var oxygen := objective_done("oxygen")
	if power and oxygen:
		return "done"
	if power:
		return "oxygen"
	if oxygen:
		return "power"
	return "both"


func _triggered(trigger: String) -> bool:
	match trigger:
		"power_done":
			return objective_done("power")
		"oxygen_done":
			return objective_done("oxygen")
		"both_done":
			return all_done()
		"panes_done":
			return GameState.window_repair.box_broken or GameState.window_repair.fixed.size() >= 3
	return false


## Tests and screenshots: the bot already awake, named, reserve power on, objectives handed out.
func skip_intro(name := "TESTER") -> void:
	bot_awake = true
	player_name = name
	named = true
	reserve_power = true
	objectives_given = true
	changed.emit()
