class_name WindowRepair
extends RefCounted
## Session state of the storage room's smashed panes and the cargo box you stand on to reach them
## (GameState.window_repair; the scene side is WindowCracks). Survives the airlock.
##
## The box takes one crack per pane: standing on it under a pane cracks it once, and it will not
## crack again until that pane is mended. Once every pane is mended with you standing on it, it
## gives way (broken).
## Each window also retains its own glass placements, quarter turns and unfinished scan.
## debug_complete toggles all authored panes without glass or changing the cargo-box ledger.

signal changed

## Panes mended: id -> true.
var fixed := {}
## Panes the box has cracked for: id -> true.
var box_cracks := {}
## Where the box was last set down (world), or null while it stands where it starts.
var box_world: Variant = null
var box_broken := false
var puzzles: Dictionary = {}
## "base" once every storage pane is mended: storage's exterior holes have whole glass.
## Empty while broken; a room ID remains supported for single-room developer previews.
var dome_mended := ""


func puzzle_for(id: String, definition: Dictionary) -> GlassPuzzle:
	if not puzzles.has(id):
		puzzles[id] = GlassPuzzle.new(definition)
	return puzzles[id]


## How many cracks the box has taken (its sprite frame until it breaks).
func damage() -> int:
	return box_cracks.size()


## The box takes your weight under pane `id`: true if that cracked it.
func crack_box(id: String) -> bool:
	if box_broken or fixed.has(id) or box_cracks.has(id) or pending() != "":
		return false
	box_cracks[id] = true
	changed.emit()
	return true


## The pane the box has cracked for that is not mended yet, or "".
func pending() -> String:
	for id in box_cracks:
		if not fixed.has(id):
			return id
	return ""


## Mend pane `id`: true the first time.
func fix(id: String) -> bool:
	if fixed.has(id):
		return false
	fixed[id] = true
	changed.emit()
	return true


func all_fixed(ids: Array) -> bool:
	for id in ids:
		if not fixed.has(id):
			return false
	return not ids.is_empty()


## F1 task toggle; metadata owns the pane IDs. Completion restores the whole main base.
func debug_complete(completed: bool, meta: Dictionary) -> void:
	if not OS.is_debug_build():
		return
	fixed.clear()
	puzzles.clear()
	if completed:
		for pane in meta["window_cracks"]:
			fixed[pane["id"]] = true
	dome_mended = "base" if completed else ""
	changed.emit()


func break_box() -> void:
	box_broken = true
	changed.emit()
