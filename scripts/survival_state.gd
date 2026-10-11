class_name SurvivalState
extends RefCounted
## Session vitals owned by GameState. No scene nodes or real-time timers: advance() takes
## active gameplay seconds. All balancing lives in data/survival.json; tests drive this API.
signal changed
signal died(cause: String)

const KINDS := ["health", "oxygen", "hunger", "thirst"]
var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/survival.json"))
var values: Dictionary = {}
var dead := false
var cause := ""
## Needs held where they are (development: DevPanel): kind -> true. No drain, no recovery, no
## damage from them. Kept through rescue, like the rest of the session.
var frozen := {}
var _damage_time := {"oxygen": 0.0, "hunger": 0.0, "thirst": 0.0}


func _init() -> void:
	reset()


func maximum(kind: String) -> float:
	return float(config[kind]["maximum"])


func set_value(kind: String, value: float) -> void:
	if not KINDS.has(kind) or not is_finite(value) or dead:
		return
	values[kind] = clampf(value, 0.0, maximum(kind))
	if _damage_time.has(kind) and values[kind] > float(config[kind]["damage_threshold"]):
		_damage_time[kind] = 0.0
	changed.emit()
	if kind == "health" and values[kind] <= 0.0:
		dead = true
		if cause.is_empty():
			cause = "INJURY"
		died.emit(cause)


func damage(amount: float, reason := "INJURY") -> void:
	if amount <= 0.0 or not is_finite(amount) or dead:
		return
	cause = reason
	set_value("health", values["health"] - amount)
	if not dead:
		cause = ""


func reset() -> void:
	dead = false
	cause = ""
	for kind in KINDS:
		values[kind] = maximum(kind)
	for kind in _damage_time:
		_damage_time[kind] = 0.0
	changed.emit()


func advance(seconds: float, breathable: bool, sprinting: bool) -> void:
	if dead or seconds <= 0.0 or not is_finite(seconds):
		return
	# Split at depletion/interval boundaries so a long frame cannot deal damage for
	# time spent above a threshold, or produce different results from short frames.
	var remaining := seconds
	while remaining > 0.00001 and not dead:
		var step := minf(remaining, 0.25)
		for kind in ["oxygen", "hunger", "thirst"]:
			if frozen.has(kind):
				_damage_time[kind] = 0.0
				continue
			var rules: Dictionary = config[kind]
			var rate: float = rules["depletion"]
			if kind == "oxygen" and breathable:
				rate = -float(rules["recovery"])
			elif kind != "oxygen" and sprinting:
				rate *= float(rules["sprint_multiplier"])
			var before: float = values[kind]
			set_value(kind, before - rate * step)
			var threshold: float = rules["damage_threshold"]
			if values[kind] <= threshold and not (kind == "oxygen" and breathable):
				var active := step
				if before > threshold and rate > 0.0:
					active = maxf(0.0, step - (before - threshold) / rate)
				_damage_time[kind] += active
				while _damage_time[kind] + 0.00001 >= float(rules["damage_interval"]) and not dead:
					_damage_time[kind] -= float(rules["damage_interval"])
					damage(float(rules["damage"]), str(rules["cause"]))
			else:
				_damage_time[kind] = 0.0
		remaining -= step


func restore(kind: String, amount: float) -> bool:
	if dead or not KINDS.has(kind) or not is_finite(amount) or amount <= 0.0 or values[kind] >= maximum(kind):
		return false
	set_value(kind, values[kind] + amount)
	if _damage_time.has(kind):
		_damage_time[kind] = 0.0
	return true
