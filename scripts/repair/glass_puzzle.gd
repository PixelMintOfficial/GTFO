class_name GlassPuzzle
extends RefCounted
## One window's connected glass jigsaw. Generated geometry owns targets; this model owns
## quarter turns, fitted fragments and the resumable sealing scan. The scene adapter alone
## spends inventory and commits the repair after the scan reaches the bottom.

var definition: Dictionary
var rotations: Array[int] = []
var placed: Array[bool] = []
var scan := 0.0
var scan_age := 0.0
var done := false


func _init(data: Dictionary) -> void:
	definition = data
	for piece in data["pieces"]:
		rotations.append(int(piece["rotation"]))
		placed.append(false)


func fitted() -> int:
	return placed.count(true)


func scanning() -> bool:
	return not done and fitted() == placed.size()


func target(index: int) -> Vector2:
	var p: Array = definition["pieces"][index]["target"]
	return Vector2(p[0], p[1])


func rotate(index: int) -> void:
	if index >= 0 and index < placed.size() and not placed[index] and not done:
		rotations[index] = (rotations[index] + 1) % 4


func fits(index: int, point: Vector2) -> bool:
	return index >= 0 and index < placed.size() and not placed[index] and not done and rotations[index] == 0 and point.distance_to(target(index)) <= 7.0


func place(index: int, point: Vector2) -> bool:
	if not fits(index, point):
		return false
	placed[index] = true
	return true


## Called only by the world adapter after checking reach and modal ownership this frame.
func advance(delta: float) -> bool:
	if not scanning():
		return false
	scan_age += delta
	scan = minf(1.0, scan + delta / float(definition["scan_seconds"]))
	return scan >= 1.0
