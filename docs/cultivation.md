# Nursery restoration and crops

Repair the dormant nursery UNIT body before its console, light or rack. It introduces
itself as the same UNIT in another body and explains both crops and night-only seeds.

The nursery begins with a chipped/cracked monitor, dropped grow light, one sagging
centre growing-rack shelf, a dry grey channel and dead crops. Floor feed conduits
are intact and no wire bundles hang from the console or grower. Equip the multitool with T /
gamepad Y, then hold F / gamepad X to repair each system in any order. The existing
2.4-second fix job plays the astronaut's use pose, cyan scanner sweep and repair
sound. Releasing, unequipping, leaving reach, turning or changing scenes pauses
the scan and retains its progress. Repairs currently have no minigames or material cost. Each
repair replaces its actual colour, depth, walk and light data.

After all three repairs, F / X plants the three food racks and two water silos.
Each bed consumes one seed on successful planting. One wild seed handful gives
three seeds, enough for all food racks or both water silos. F / X harvests ripe
fruit; planted beds regrow without further reseeding.

- **Cindercoil**: tough curled wilderness scrub with dry woody seed cases. Ripe
  cases supply Emberpod seeds at any hour; the wild plant carries no edible fruit.
- **Moonwell**: its closed daytime husk opens during NIGHT (20:00–05:00). Inner
  petals and exposed seeds glow. Collection is allowed only while fully open;
  collecting removes the seed cluster. It supplies Dewpod seeds.
- **Emberpods**: orange fruit grown on rear racks, restoring 20 hunger when eaten.
- **Dewpods**: liquid-bearing fruit grown on the silos, restoring 25 thirst.

C / right-stick click consumes selected fruit through the existing inventory and
survival APIs. No seeds or fruit are granted at game start. Whole handfuls and
harvests must fit: a full backpack changes neither inventory nor source.

## Ownership and balance

`GameState.cultivation` (`CultivationState`) owns the repair bits, `repair_progress`, planted-bed ready
times and wild cooldowns. It survives camera turns, airlocks and rescue. Explicit
inventory/world-ledger reset resets cultivation. Disk saves remain unimplemented.

`data/cultivation.json` owns IDs, interaction reach, seed/yield counts, growth
delays, wild scales and clearing settings. Both first growth and regrowth take one
full game day (24 game hours, 12 real minutes at normal speed). Wild seeds recover
after four game hours. The existing game clock means
growth continues outside the nursery and stops in paused modals. Fruit restoration
is in `data/survival.json`; indoor harvest is available at any time.

`CultivationWorld` adapts state to each scene. Independent
`multitool.cultivation_suppressed` proximity/release ownership prevents duplicate
F / X actions. Doors take priority even before their current-frame prompt update;
pauses, cutscenes, jumps, camera turns and other modal owners block cultivation.
Local PixelFont prompts name needed wild seed sources and move above plants when
the fixed survival HUD would otherwise push them behind the hotbar. No additional HUD or buttons.
Reachable repair targets register through `Multitool.add_fixable` while the tool is
equipped; cultivation yields F ownership to that job and guards release after completion.
Generated `scan_height` values keep the scanner on each actual console/light/rack in every view.
The third repair is `rack` (bit 4), replacing the old floor-feed repair. Once all
three systems work, circulation returns to the channel.

## Native art and forest placement

- `tools/cultivation_models.py` preserves the approved models using the shared SDF
  primitives, camera and ramps. Wild plants are roughly astronaut height.
- `tools/cultivation_gen.py` writes `assets/cultivation/`: four wild views,
  Moonwell opening/collected frames, native depth/glow and inventory icons.
- `tools/nursery_gen.py` plus `nursery_cultivation.py` write eight independent repair
  combinations in four views, actual walk grids, five crop overlays and interaction
  anchors. `NURSERY_CONDITION=restored` retains the earlier intact-room art export
  for comparison; the default is the damaged cultivation room.
- `tools/cultivation_placement.py` chooses 16 plants of each species after terrain
  grading, using the map exporter's exact `world_walk_grid` slopes and blockers. Only filler undergrowth
  inside small clearings is removed; trees, trails and remaining placements retain
  the original random stream. `forage_sites.json` records sites and removed filler.
  Sites require at least 55% forest coverage, keeping seed plants off red/snow edges.
- The final map walk grid selects stable `stand_world` interaction approaches.
  `mars_map_gen.py --forage-stands-only` refreshes anchors without changing art.

`CropVisual` / `crop_depth.gdshader` use native per-pixel RG16 local view depth at
512 steps per world unit, offset 64; B is emissive coverage. Colour/depth silhouettes
match, including outlines. Sprites rebind the MapStream window on moves and views.
Glow-only billboards keep Moonwell lit through the camera swing.

## Pipeline and verification

`make map` includes clearings and cultivation art. `make cultivation` refreshes
wild sprites/icons; `make nursery` includes repair variants and crop overlays.
`make nursery-metadata` refreshes repair/scanner anchors without rerendering art.
Re-import after generation. `make check` includes `tools/check_cultivation.py`
and `tests/cultivation_test.tscn` alongside existing regression suites.

Capture hooks: overworld `--forage-at=cindercoil_00|moonwell_00`; nursery
`--nursery-at=console|light|rack|rack0..2|silo0..1`, `--nursery-repaired`,
`--nursery-seeds`, `--nursery-crops=ripe|sprout`. Existing time, turn, suit lamp,
capture and audio-debug hooks apply.

`tests/cultivation_test.tscn -- --cultivation-captures=ABSOLUTE_DIR` captures the
real repair/harvest input loop, backpack, daytime Moonwell, open/collected night
flower and Cindercoil when run with the native renderer (without `--headless`).

## Nursery cleanup and checklist

The nursery has eight player tasks on entry: repair UNIT, console/light/rack,
plant three food racks/two water silos, and harvest each crop once. UNIT's autonomous
cleaning stays off the checklist and never blocks player completion.
Base objectives remain independent. `CultivationState.harvested` changes only on a successful
inventory transaction; planting counts update immediately.

The console screen controls nursery power. Repairing it immediately lights the room and
exterior glass at every hour, independently of main-base generator/solar progress. UNIT
explains this on introduction. The grow-light and rack still need their own repairs before
planting. Oxygen remains supplied by the main-base O2 system; nursery lighting creates no air.
`tests/nursery_power_test.tscn` covers live repair, power isolation, four views and scene changes.

F1 Master Control includes separate Complete/Reset toggles for nursery UNIT, screen, grow
light and food rack. These change the real session state and refresh room art immediately;
the screen toggle also controls lighting. Reset clears only the selected repair's scan
progress. Crops, seeds, harvests, inventory and cleaned dirt remain intact. The UNIT toggle
resumes patrol directly or restores its dormant scanner without advancing the main-base story.

`tools/nursery_cleanup_gen.py` owns removable native soil, dead leaves and tray chips,
exported to `assets/maps/nursery_interior/cleanup/cleanup.json` plus four-view colour/depth
sheets. No generated room picture is painted over. UNIT walks the actual floor grid,
deploys its generated vacuum intake, sweeps while debris shrinks, then stows it. Partial
fractions live in `StoryState.cleanup_progress`; cleaned piles do not return after airlocks
or camera turns. Normal inspection patrols continue once all litter is gone. No loot is removed.

`make nursery` regenerates litter too. `tests/nursery_cleanup_test.tscn` checks actual bot
traversal, every animation stage, nearby-only removal, all views, persistence and checklist
completion; native captures accept `-- --out=ABSOLUTE_DIR`.

Both the nursery and base have six removable litter piles. UNIT strolls between occasional
random cleanup jobs (16–30 seconds plus brief idle stops), and never vacuums already clean
floor. `maintenance` in bot_story.json owns this timing; StoryState.maintenance_waits keeps
remaining roaming delays through airlocks. Quiet bot_vacuum audio is a separate generated
recipe. The integration test checks both bodies, every actual cleaning approach, full pile
removal, quest-loot preservation and no fake cleanup after all dirt is gone.
