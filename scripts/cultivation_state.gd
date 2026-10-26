class_name CultivationState
extends RefCounted
## Session cultivation: simple nursery repairs, reseeded crop beds and wild seed cooldowns.
## Balance/IDs live in data/cultivation.json. GameState alone owns this instance; changing
## scenes/views or being rescued cannot reset it. Growth uses the existing game clock, so
## inventory/dialogue pauses stop growth and time outside the nursery still counts.
## Inventory transactions are all-or-nothing: full bags never consume a harvest/cooldown.
## repair_progress keeps unfinished multitool scans across releases, turns and airlocks.
## harvested remembers each successful crop-kind harvest for the nursery checklist.
## F1 debug_complete toggles one repair without changing crops, seeds or inventory.

signal changed

const CONFIG := "res://data/cultivation.json"
var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CONFIG))
var repairs := 0
var repair_progress: Dictionary = {}
var beds: Dictionary = {}
var wild_ready_at: Dictionary = {}
## Successful first harvests, by crop kind, for the nursery checklist.
var harvested: Dictionary = {}


static func is_night(clock: float) -> bool:
	var hour := fposmod(clock, 24.0)
	return hour >= 20.0 or hour < 5.0


func repaired(id: String) -> bool:
	for entry in config["repairs"]:
		if entry["id"] == id:
			return (repairs & int(entry["bit"])) != 0
	return false


func repair(id: String) -> bool:
	if not GameState.story.nursery_awake:
		return false
	for entry in config["repairs"]:
		if entry["id"] == id and not repaired(id):
			repairs |= int(entry["bit"])
			repair_progress[id] = 1.0
			changed.emit()
			return true
	return false


func debug_complete(id: String, completed: bool) -> void:
	if not OS.is_debug_build():
		return
	for entry in config["repairs"]:
		if entry["id"] != id:
			continue
		var bit := int(entry["bit"])
		repairs = repairs | bit if completed else repairs & ~bit
		if completed:
			repair_progress[id] = 1.0
		else:
			repair_progress.erase(id)
		changed.emit()
		return


## 0 dead/unplanted, 1 growing, 2 ripe. No clock or inventory mutation during queries.
func stage(id: String, clock: float) -> int:
	if not beds.has(id):
		return 0
	return 2 if clock >= float(beds[id]["ready_at"]) else 1


func plant(id: String, clock: float) -> bool:
	if not GameState.story.nursery_awake or repairs != 7 or beds.has(id) or not config["beds"].has(id):
		return false
	var kind: String = config["beds"][id]
	var crop: Dictionary = config["crops"][kind]
	if not GameState.consume_item(crop["seed"], 1):
		return false
	beds[id] = {"kind": kind, "ready_at": clock + float(config["growth_hours"])}
	changed.emit()
	return true


func harvest(id: String, clock: float) -> bool:
	if stage(id, clock) != 2 or not config["beds"].has(id):
		return false
	var crop: Dictionary = config["crops"][config["beds"][id]]
	if not GameState.store_items(crop["fruit"], int(crop["yield"])):
		return false
	beds[id]["ready_at"] = clock + float(config["regrow_hours"])
	harvested[config["beds"][id]] = true
	changed.emit()
	return true


func wild_ready(id: String, species: String, clock: float) -> bool:
	if not config["wild"].has(species) or clock < float(wild_ready_at.get(id, -1.0)):
		return false
	return species != "moonwell" or is_night(clock)


func gather(id: String, species: String, clock: float) -> bool:
	if not wild_ready(id, species, clock):
		return false
	var kind: String = config["wild"][species]["crop"]
	var crop: Dictionary = config["crops"][kind]
	if not GameState.store_items(crop["seed"], int(config["seed_handful"])):
		return false
	wild_ready_at[id] = clock + float(config["wild_regrow_hours"])
	changed.emit()
	return true
