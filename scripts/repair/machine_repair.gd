class_name MachineRepair
extends RefCounted
## Session state for one machine: untimed cracks first, then the 30s circuit attempt.
## Both puzzles survive closing and changing scenes; inventory is spent only on crack success.

signal changed
signal circuit_switched

const ATTEMPT_SECONDS := 30.0
const TASK_WEIGHTS := {"wiring": 0.5, "cracks": 0.5}

var machine_id: String
var layouts: Array[Dictionary]
var puzzle: CircuitPuzzle
var cracks: CrackPuzzle
var layout_index := 0
var remaining := ATTEMPT_SECONDS
var completed_tasks: Dictionary = {}
var _attempt := 0
var _seed: int


func _init(id: String, seed_value := 17) -> void:
	machine_id = id
	layouts = CircuitCatalog.for_machine(id)
	assert(layouts.size() == 5, "Every repair machine needs five circuits")
	_seed = seed_value
	_new_puzzle()


func progress() -> float:
	var amount := 0.0
	for task in TASK_WEIGHTS:
		if task_completed(task):
			amount += TASK_WEIGHTS[task]
	return amount


func task_completed(task: String) -> bool:
	return completed_tasks.get(task, false)


func complete_task(task: String) -> bool:
	if not TASK_WEIGHTS.has(task) or task_completed(task):
		return false
	if task == "wiring" and not task_completed("cracks"):
		return false
	completed_tasks[task] = true
	changed.emit()
	return true


func rotate(index: int, clockwise := true) -> bool:
	if not task_completed("cracks") or task_completed("wiring") or not puzzle.rotate(index, clockwise):
		return false
	if puzzle.solved:
		complete_task("wiring")
	else:
		changed.emit()
	return true


## Called only by the open repair panel. Walking away pauses this attempt.
func advance(delta: float) -> void:
	if not task_completed("cracks") or task_completed("wiring") or delta <= 0.0:
		return
	remaining = maxf(0.0, remaining - delta)
	if remaining <= 0.0:
		layout_index = (layout_index + 1) % layouts.size()
		_attempt += 1
		_new_puzzle()
		circuit_switched.emit()
		changed.emit()


func finish_cracks() -> bool:
	if task_completed("cracks") or cracks == null or not cracks.solved():
		return false
	if not GameState.consume_item("scrap", CrackPuzzle.SCRAP_COST):
		return false
	return complete_task("cracks")


func _new_puzzle() -> void:
	puzzle = CircuitPuzzle.new(layouts[layout_index], _seed + _attempt * 7919)
	remaining = ATTEMPT_SECONDS
