class_name FacilityAir
extends RefCounted
## Shared base/nursery oxygen supply, owned only by GameState. A complete O2 repair starts
## one data-authored reserve period on the game clock. The repaired generator plus every
## solar route provide lasting power. All three storage panes must seal before either
## facility retains breathable air. Outdoors always uses the suit. Queries never drain vitals.
var reserve_started_at := -1.0

func reset() -> void:
	reserve_started_at = -1.

func sync() -> void:
	if reserve_started_at < 0. and GameState.repair_for("oxygen").progress() >= 1.:
		reserve_started_at = GameState.clock

func status() -> String:
	sync()
	if GameState.repair_for("oxygen").progress() < 1.: return "offline"
	if GameState.base_powered(): return "online"
	var hours: float = GameState.survival.config["facility_air"]["reserve_hours"]
	return "reserve" if GameState.clock - reserve_started_at < hours else "empty"

func sealed() -> bool:
	return GameState.window_repair.all_fixed(GameState.survival.config["facility_air"]["seal_panes"])

func reserve_fraction() -> float:
	sync()
	if reserve_started_at < 0.: return 0.
	var hours: float = GameState.survival.config["facility_air"]["reserve_hours"]
	return clampf(1. - (GameState.clock - reserve_started_at) / maxf(hours, .001), 0., 1.)

func breathable() -> bool:
	var supply := status()
	return sealed() and supply in ["reserve", "online"]

func message() -> Array:
	match status():
		"reserve": return ["O2 ON RESERVE - FIX GENERATOR + SOLAR", "SEAL STORAGE GLASS TO KEEP AIR INSIDE" if not sealed() else "BASE + NURSERY O2 SUPPLY TEMPORARY"]
		"online": return ["O2 SUPPLY STABLE" if sealed() else "O2 LEAK - SEAL ALL STORAGE WINDOWS"]
		"empty": return ["O2 RESERVE EMPTY - FIX GENERATOR + SOLAR"]
	return []
