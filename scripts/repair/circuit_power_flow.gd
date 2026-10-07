class_name CircuitPowerFlow
extends RefCounted
## One completion pulse. Arc-length sampling keeps it on the actual wire through corners.
## This view-only timeline never changes puzzle state or machine repair credit.

const START_DELAY := 0.15
const TRAVEL_SECONDS := 1.6
const ARRIVAL_SECONDS := 0.45
const DURATION := START_DELAY + TRAVEL_SECONDS + ARRIVAL_SECONDS

var points := PackedVector2Array()
var distances := PackedFloat32Array()
var length := 0.0
var elapsed := 0.0


func _init(route: PackedVector2Array) -> void:
	assert(route.size() >= 2, "A power pulse needs both terminals")
	points = route.duplicate()
	distances.append(0.0)
	for index in range(1, points.size()):
		length += points[index - 1].distance_to(points[index])
		distances.append(length)
	assert(length > 0.0)


func advance(delta: float) -> void:
	elapsed = clampf(elapsed + maxf(delta, 0.0), 0.0, DURATION)


func progress() -> float:
	return clampf((elapsed - START_DELAY) / TRAVEL_SECONDS, 0.0, 1.0)


func arrived() -> bool:
	return elapsed >= START_DELAY + TRAVEL_SECONDS


func arrival_phase() -> float:
	return clampf((elapsed - START_DELAY - TRAVEL_SECONDS) / ARRIVAL_SECONDS, 0.0, 1.0)


func finished() -> bool:
	return elapsed >= DURATION


func sample(distance: float) -> Vector2:
	distance = clampf(distance, 0.0, length)
	for index in range(1, points.size()):
		if distances[index] >= distance:
			var span := distances[index] - distances[index - 1]
			if span > 0.0:
				return points[index - 1].lerp(points[index], (distance - distances[index - 1]) / span)
	return points[-1]


func section(from: float, to: float) -> PackedVector2Array:
	from = clampf(from, 0.0, length)
	to = clampf(to, 0.0, length)
	if from >= to:
		return PackedVector2Array()
	var result := PackedVector2Array([sample(from)])
	for index in range(1, points.size() - 1):
		if distances[index] > from and distances[index] < to:
			result.append(points[index])
	result.append(sample(to))
	return result
