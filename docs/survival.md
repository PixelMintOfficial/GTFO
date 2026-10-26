# Survival feature review

Branch: `feature/survival-status`. Submitted for review through a pull request; not merged.

The existing Player, GameState, backpack and hotbar remain the owners of movement, session
state and items. There was no health/death/consumable/swimming/disk-save system to extend.
SurvivalState is a RefCounted model held by GameState, not a second player or autoload.
SurvivalHUD attaches in both scenes, ticks only active gameplay and draws in the same
384x216 logical canvas as the inventory. The compact top-left panel uses segmented circular dials and cannot be moved;
preview controls are documented in `survival-hud.md`.
Icons are procedural UI patterns, like the existing
multitool icon; no generated assets were edited or new imported art introduced.

## Default balance

All four values start at 100 and clamp to 0–100. Edit `data/survival.json` to balance them.
Rates below are per active real second, independent of the game-day clock.

| Meter | Drain/recovery | Consequence at zero |
|---|---|---|
| Health | Damage through `Player.take_damage(amount, cause)`; no automatic healing | Death and paused rescue screen |
| Oxygen | Unpressurized air drains 0.1/s; breathable air restores 20/s | 5 health damage every 2 seconds |
| Hunger | Drains 0.08/s, multiplied by 1.75 while actually sprinting | 2 health damage every 5 seconds |
| Thirst | Drains 0.12/s, multiplied by 2 while actually sprinting | 3 health damage every 4 seconds |

Warning indicators pulse below 20%. Health and segmented meters update immediately.
No depletion during map/backpack/repair pauses, camera turns, intro or doors.
Damage timers restart after recovery. Long steps handle depletion boundaries before damage.

Outdoors and unpressurized facilities drain suit oxygen continuously. Full O2 repair
starts 24 game hours of reserve. All three storage panes must seal before either main-base
or nursery air becomes breathable. The nursery tank shares the main generator. Breathable
air replenishes the suit at 20/s. Generator repair plus all three connected solar routes
provide lasting supply; either alone is insufficient. Reserve expires on the game clock,
so paused modals stop it. At 0.1/s the starting suit tank lasts 16m40s of active play.
Reserve powers only the O2 generator: maintenance access does not restore room lighting.
The battery beside the clock appears only after O2 repair, while mains are off, and shows
reserve percent/empty plus leaks. It disappears on restored generator + solar mains. A compact
native RESERVES gauge on an O2-room side wall provides the physical reserve readout. An expired reserve stops O2 production and drains suit oxygen even indoors. The repaired
generator plus all three solar routes light the main base at every hour. The nursery's
repaired console screen controls its local lights and exterior glow independently. Lit
nursery rooms still need the main-base O2 supply and seals before the player can breathe.
Without local power the room stays dim and L/B supplies the suit lamp, including at noon.
Prompts explain reserve, leaks, stable supply and exhausted reserve. FacilityAir lives only
in GameState; balance and seal IDs live in data/survival.json. Player.can_breathe() retains
suit availability and head-submerged overrides. Pools have no swimming volume.

Each fresh session receives six rations and six water units in the existing inventory.
A ration restores 35 hunger; water restores 40 thirst. Items stack to 99. Consumption removes
exactly one unit, clears empty stacks, rejects unknown items and retains supplies when the
associated meter is full or the player is dead. Swap supplies into any hotbar slot as usual.
There is no crafting, harvesting or supply vendor yet; these are starter supplies.

Enter/gamepad A on death returns to the ordinary overworld spawn with full vitals and fresh
supplies. Existing resources, repairs, removed props, time and heading survive. Old supplies
are replaced rather than accumulating. Supplies use available inventory capacity; a completely
full bag can prevent stocking. There is no disk persistence, matching the existing project.

## Launch on this Windows machine

Run in PowerShell:

```powershell
Set-Location F:\PlayMint\GTFO
$godot = 'C:\Users\KT\.codex\visualizations\2026\10\07\01a1149e-a64a-7a51-bf4a-639f3f916204\godot\Godot_v4.7.2-stable_win64_console.exe'
& $godot --path .
# Skip the intro and enable explicit development controls:
& $godot --path . -- --no-intro --survival-debug
# Start directly in unsafe air, without debugging:
& $godot --path . res://scenes/interior.tscn -- --spawn=-236,492
```

Godot is not on PATH and make is unavailable in this environment. Elsewhere the ordinary
commands are `godot --path .`, `make import`, and `make check`. Use Godot 4.7.2 Compatibility.
No art generator run is required. To keep test user data within the sandbox, verification used
`$env:APPDATA = 'F:/PlayMint/GTFO/.godot/test-user'`; normal local launches do not need this.

## Controls and manual verification

- Movement: WASD/arrows/left stick; sprint: Shift/right shoulder while moving.
- Select starter ration with 2, water with 3 (or wheel/left shoulder/click); C/right-stick
  click consumes. E/Start opens backpack; arrows/d-pad select a slot, C/right-stick click
  consumes that slot when no item is picked up. Existing swaps, tool, F/X interactions remain.
- Health: in developer mode press F6 to deal 25 damage. Four presses reach zero. Check the
  paused SUIT OFFLINE screen, then Enter/A to rescue. Health cannot become negative.
- Oxygen: enter the base with F at the airlock; go left to the oxygen room (its bulkhead opens
  once the bot in storage is woken - or start the interior with `--story=awake`). Reserve empties
  in 20 active seconds; remain there for two more to see health damage. Leave the room and
  watch oxygen recover to full in five seconds. F/X opens the O2 wiring panel; solving it
  makes that room breathable. The repair panel itself pauses depletion.
- Hunger/thirst: stand still to see slow depletion, then run to compare the rates. In dev
  mode use F10 for 60x depletion. Select ration/water and consume; the meter increases and
  stack count falls immediately. At full hunger/thirst the stack is retained.
- Consequences: F8 empties both needs. Thirst causes damage after four seconds; hunger after
  five. Use F9 to refill before repeating. To isolate starvation, launch with
  `--survival-debug --vitals=100,100,0,100`; dehydration: `--vitals=100,100,100,0`.
- Pause: open backpack/map/repair panel and verify values stop changing. Close and resume.
- Persistence: consume a ration, pass through an airlock and turn G/H; values and counts persist.
- Resolution: use Godot's `--resolution 384x216`, `768x432`, `1024x768`, or `1920x1080`.

Debug controls require **both** a debug engine/build and the explicit `--survival-debug` flag.
They are inactive in normal gameplay and release exports. F6 damage; F7 toggles suit-air
availability; F8 empties hunger/thirst; F9 restores all vitals; F10 toggles 1x/60x survival time.
F7 off drains oxygen anywhere; F7 on recovers it only if the local environment is safe.
`--survival-speed=60` sets test speed (clamped 1–120); `--vitals=H,O,F,W` sets initial values
once per process, never on scene transitions or rescue. Death uses Enter/A, not F9.

## Tests and files

```powershell
& $godot --headless --path . res://tests/survival_test.tscn
& $godot --headless --path . res://tests/inventory_test.tscn
& $godot --headless --path . res://tests/repair_test.tscn
& $godot --headless --path . res://tests/view_turn_test.tscn
& $godot --headless --path . res://scenes/overworld.tscn -- --no-intro --quit=4
& $godot --headless --path . res://scenes/interior.tscn -- --quit=4
```

Godot 4.7.2 results: survival 48 checks, inventory 98, repair 9677 (1000 shuffled boards),
camera turns 283; all zero failures. Both scenes ran without errors/warnings. Native graphical
captures were inspected at day/night, views 0/1/2, 384x216, 768x432, 1024x768 and 1920x1080.
Screenshots: `shots/survival-day.png`, `survival-night.png`, `survival-small.png`,
`survival-backpack.png`, `survival-death.png` (git ignored). Backpack intentionally covers
the survival row while open; death appears above all UI. No generators or audio mixes changed.

Created: `data/survival.json`, `scripts/survival_state.gd`, `scripts/survival_hud.gd`,
`tests/survival_test.gd`, `tests/survival_test.tscn`, their script `.uid` files, this guide.
Modified: `scripts/game_state.gd`, `player.gd`, `inventory_ui.gd`, `overworld.gd`, `interior.gd`,
`Makefile` (survival in check-tests), `AGENTS.md` (approved mechanics/state/config/controls).
