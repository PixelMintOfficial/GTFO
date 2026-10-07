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

## Backpack: first six slots are the hotbar. Only the multitool can be equipped;
## ore and scrap are stored resources, with no invented consumption/crafting jobs.
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


func swap_slots(a: int, b: int) -> void:
	if a < 0 or b < 0 or a >= INVENTORY_SIZE or b >= INVENTORY_SIZE or a == b:
		return
	var slot := inventory[a]
	inventory[a] = inventory[b]
	inventory[b] = slot
	inventory_changed.emit()
