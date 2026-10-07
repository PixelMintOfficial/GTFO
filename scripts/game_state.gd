extends Node
## What carries over between the overworld and the inside of the base (autoload: GameState).

## The crash scene has been seen (or skipped): it only plays once.
var intro_done := false
## Where the astronaut should appear in the next scene: "" (its default spawn), "interior"
## (coming in through the airlock), "door" (stepping back out of the airlock door_id).
var arrive := ""
var door_id := -1
## Whether the multitool was out, so it stays out across the airlock.
var tool_out := false
## Which way the camera faces: quarter turns round the world (0..3), the same indoors and out.
var heading := 0
## The time: game hours since the game began (on day 1, at 08:00). DayNight moves it on and
## works out the day, the hour and the part of the day from it.
var clock := 8.0

## Backpack: first six slots are the hotbar. Only the multitool can be equipped;
## ore is stored; three scraps are consumed atomically on successful machine crack repair.
signal inventory_changed
const HOTBAR_SIZE := 6
const INVENTORY_SIZE := 24
const STACK_LIMIT := 99
const ITEMS := {
	"multitool": {"name": "MULTITOOL", "detail": "T TO EQUIP - F TO WORK", "stack": 1},
	"ore_chunk": {"name": "ORE", "detail": "COLLECTED FROM ORE ROCKS", "stack": STACK_LIMIT},
	"scrap": {"name": "SCRAP", "detail": "SALVAGED MATERIAL", "stack": STACK_LIMIT},
}
var inventory: Array[Dictionary] = []
var selected_slot := 0
## Session world ledger prevents collected props from reappearing through an airlock.
var removed_props := {}
var spawned_props := {}
## Machine repairs share the same session lifetime as the backpack.
var machine_repairs: Dictionary = {}


func repair_for(machine_id: String) -> MachineRepair:
	if not machine_repairs.has(machine_id):
		machine_repairs[machine_id] = MachineRepair.new(machine_id, randi())
	return machine_repairs[machine_id]


func _ready() -> void:
	reset_inventory()


func reset_inventory() -> void:
	inventory.clear()
	for i in INVENTORY_SIZE:
		inventory.append({})
	inventory[0] = {"kind": "multitool", "count": 1}
	selected_slot = 0
	removed_props.clear()
	spawned_props.clear()
	inventory_changed.emit()


func can_store(kind: String) -> bool:
	if not ITEMS.has(kind) or kind == "multitool":
		return false
	for slot in inventory:
		if slot.is_empty() or (slot["kind"] == kind and slot["count"] < ITEMS[kind]["stack"]):
			return true
	return false


## Adds exactly one gathered prop, atomically. Full bags leave the prop in the world.
func store_item(kind: String) -> bool:
	if not can_store(kind):
		return false
	for slot in inventory:
		if slot.get("kind", "") == kind and slot["count"] < ITEMS[kind]["stack"]:
			slot["count"] += 1
			inventory_changed.emit()
			return true
	for i in inventory.size():
		if inventory[i].is_empty():
			inventory[i] = {"kind": kind, "count": 1}
			inventory_changed.emit()
			return true
	return false


func select_slot(index: int) -> void:
	if index < 0 or index >= HOTBAR_SIZE:
		return
	selected_slot = index
	inventory_changed.emit()


func item_count(kind: String) -> int:
	var total := 0
	for slot in inventory:
		if slot.get("kind", "") == kind:
			total += int(slot["count"])
	return total


## All-or-nothing consumption, across stacks. Failed/unfinished repairs never call this.
func consume_item(kind: String, count: int) -> bool:
	if count <= 0 or item_count(kind) < count:
		return false
	var left := count
	for i in inventory.size():
		if inventory[i].get("kind", "") != kind:
			continue
		var used := mini(left, int(inventory[i]["count"]))
		inventory[i]["count"] -= used
		left -= used
		if inventory[i]["count"] == 0:
			inventory[i] = {}
		if left == 0:
			break
	inventory_changed.emit()
	return true


func swap_slots(a: int, b: int) -> void:
	if a < 0 or b < 0 or a >= INVENTORY_SIZE or b >= INVENTORY_SIZE or a == b:
		return
	var slot := inventory[a]
	inventory[a] = inventory[b]
	inventory[b] = slot
	inventory_changed.emit()
