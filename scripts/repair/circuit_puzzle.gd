class_name CircuitPuzzle
extends RefCounted
## Pure quarter-turn puzzle model. Both ports must match to conduct; bolts never move.
## Rendering, timing and machine repair progress are deliberately outside this model.

const NORTH := 1
const EAST := 2
const SOUTH := 4
const WEST := 8
const STEPS: Array[Vector2i] = [Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT]

var definition: Dictionary
var cols: int
var rows: int
var masks := PackedInt32Array()
var solution := PackedInt32Array()
var fixed := PackedByteArray()
var powered := PackedByteArray()
## Actual connected route, in supply-to-receiver order. Empty until solved.
var connected_path := PackedInt32Array()
var solved := false


func _init(layout: Dictionary, seed_value: int) -> void:
	definition = layout
	cols = int(layout["cols"])
	rows = int(layout["rows"])
	masks.resize(cols * rows)
	solution.resize(cols * rows)
	fixed.resize(cols * rows)
	powered.resize(cols * rows)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for i in masks.size():
		masks[i] = 3 if rng.randf() > 0.45 else 5
		for turn in rng.randi_range(0, 3):
			masks[i] = rotated(masks[i])
	for p in layout["blanks"]:
		masks[int(p[1]) * cols + int(p[0])] = 0
	for p in layout["locked"]:
		fixed[int(p[1]) * cols + int(p[0])] = 1
	var path := CircuitCatalog.route(layout)
	for j in path.size():
		var p := path[j]
		var index := p.y * cols + p.x
		assert(index >= 0 and index < masks.size() and masks[index] != 0)
		var previous := Vector2i(-1, int(layout["startRow"])) if j == 0 else path[j - 1]
		var next := Vector2i(cols, int(layout["endRow"])) if j == path.size() - 1 else path[j + 1]
		solution[index] = _port(previous - p) | _port(next - p)
		masks[index] = solution[index]
		if not fixed[index] and j >= 2:
			for turn in rng.randi_range(1, 3):
				masks[index] = rotated(masks[index])
	trace()
	if solved:
		var first := int(layout["startRow"]) * cols
		assert(not fixed[first], "The supply wire must be movable")
		while masks[first] & WEST:
			masks[first] = rotated(masks[first])
		trace()


static func rotated(mask: int, clockwise := true) -> int:
	return ((mask << 1) & 15) | (mask >> 3) if clockwise else (mask >> 1) | ((mask & 1) << 3)


static func _port(step: Vector2i) -> int:
	var index := STEPS.find(step)
	assert(index >= 0, "Route cells must be neighbours")
	return 1 << index


func movable(index: int) -> bool:
	return index >= 0 and index < masks.size() and masks[index] != 0 and not fixed[index]


func rotate(index: int, clockwise := true) -> bool:
	if solved or not movable(index):
		return false
	masks[index] = rotated(masks[index], clockwise)
	trace()
	return true


func trace() -> void:
	powered.fill(0)
	connected_path.clear()
	var parents := PackedInt32Array()
	parents.resize(masks.size())
	parents.fill(-1)
	var queue: Array[int] = []
	var first := int(definition["startRow"]) * cols
	if masks[first] & WEST:
		queue.append(first)
		powered[first] = 1
	var cursor := 0
	while cursor < queue.size():
		var index := queue[cursor]
		cursor += 1
		var cell := Vector2i(index % cols, index / cols)
		for direction in 4:
			if not masks[index] & (1 << direction):
				continue
			var neighbour := cell + STEPS[direction]
			if neighbour.x < 0 or neighbour.x >= cols or neighbour.y < 0 or neighbour.y >= rows:
				continue
			var other := neighbour.y * cols + neighbour.x
			if not powered[other] and masks[other] & (1 << ((direction + 2) % 4)):
				parents[other] = index
				powered[other] = 1
				queue.append(other)
	var last := int(definition["endRow"]) * cols + cols - 1
	solved = powered[last] != 0 and (masks[last] & EAST) != 0
	if solved:
		var at := last
		while at >= 0:
			connected_path.append(at)
			at = parents[at]
		connected_path.reverse()
