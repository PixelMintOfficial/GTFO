# AGENTS.md — working on GTFO

GTFO is a cozy isometric pixel-art game set on a red planet. You are an astronaut on a broken
outpost: three domes linked by winding trails across three lands (red dust, an alien forest,
ice), under a sky that turns from morning to night as you play. The main base is dead when the game starts. You get into it, find it wrecked, and bring
it back to life with your multitool.

This file is for **everyone who works on the game: people and AI agents alike**. Read all of
it before your first change, and re-read the relevant section before each new task. It
describes how the game is built, the rules that keep it consistent, and how we work together.

> **The one rule above all others: consistency.** Every new thing must look as if the same
> artist drew it, move like it belongs to the same game, and be built the same way as what is
> already here. If something you want to do does not fit these rules, stop and ask the project
> owner. Do not quietly start a new style, a new system or a new way of doing things.

---

## 1. Before every change: checklist

1. **Read the header comment** of every file you will touch. Every script and generator
   explains what it does, its data and its test hooks at the top.
2. **Find out who owns the asset.** Almost every image in `assets/` is *generated* by a
   Python tool in `tools/`. Change the generator and regenerate. **Never paint over, edit,
   resize or replace a generated PNG/JSON by hand.** It will be overwritten on the next run.
3. **Check the locked decisions** in §9 and the decision log in §12. If your change touches
   one of them, get the owner's approval first.
4. **Reuse before you write.** There is almost certainly a helper already: an SDF primitive,
   a palette ramp, a decal, a draw pattern, a test hook. Search first (§6, §7).
5. **Make the change, regenerate, re-import, run and *look at it*** (§8). A change is not done
   until you have seen a screenshot of it in the game.
6. **Update this file** if you added a system or a data key, or if a decision was made (§12).

---

## 2. Setup

| What | Version used | Notes |
|---|---|---|
| Godot | **4.7.2 stable** | GL Compatibility renderer (set in `project.godot`). Use the same minor version. |
| Python | 3.13+ | Only for the generators in `tools/`. |
| Python packages | NumPy, Pillow, SciPy | `make env` builds `.venv` from `tools/requirements.txt` with [uv](https://docs.astral.sh/uv/). |
| ffmpeg | any recent | Only for `sfx_gen.py`: decodes the source recordings. |
| bsdtar or unzip | any | Only for `sfx_gen.py --fetch`: unpacks the sound packs. |
| RAM | several GB free | `mars_map_gen.py` renders a 7751×4350 map. Close other heavy apps. |

**`make` is the way in.** `make help` lists every target; the rest of this file names them as
it goes. Nothing in the pipeline needs to be remembered as a command line.

1. Clone, then open `project.godot` in Godot 4.7.2. The first open imports every texture,
   which takes a while (the map is big). `.godot/` is rebuilt locally and is git-ignored.
2. Press Play: `scenes/overworld.tscn` is the main scene. On a fresh run the satellite crash
   intro plays first; any button skips it.
3. You only need Python if you change art, sound, maps or data (§6): `make env`.
4. The sound's source recordings are not in the repo (they are large and they are other
   people's work). `make sources` downloads and checksums them into `assets/audio/sources/`.
   You only need them to *regenerate* sound; the baked `assets/audio/*.wav` are committed.

---

## 3. Project map

```
Makefile               the one entry point: generate, import, check, screenshot, listen
project.godot          viewport 384x216, integer scaling, nearest filtering, pixel snapping
.claude/
  settings.json        permissions, and a hook that reminds you to regenerate
  skills/              how to work here: art-pipeline, sound-pipeline, verify
scenes/
  overworld.tscn       main scene: the red planet
  interior.tscn        inside the main base (storage / power room / oxygen room)
  player.tscn          the astronaut: Shadow, AnimatedSprite2D (depth-occlusion shader), GameCamera
scripts/
  game_state.gd        autoload GameState: the only state carried between scenes (incl. the clock)
  day_night.gd         DayNight: the clock, the light through the day, lights kept lit at night
  day_clock.gd         DayClock: the time panel (sky window, day number, part of the day) and the new-day title
  audio.gd             autoload Audio: buses, one-shots, loops, ambience beds (§4.8)
  world_ambience.gd    WorldAmbience: the overworld's beds and the things you can hear
  inventory_ui.gd      six-slot hotbar and paused backpack; draws existing sprites and PixelFont
  map_terrain.gd       MapTerrain: walkability, ground height, biome, world<->pixel projection
  player.gd            Player: movement, low-gravity jump, slopes, multitool states, cutscene puppet
  game_camera.gd       GameCamera: pixel-snapped follow, zoom levels, cutscene focus, shake, zoom lock
  multitool.gd         Multitool: equip, job picking (mine/gather/lift/fix) and their effects
  world_prop.gd        WorldProp: a loose thing the tool works on (rock, chunk, scrap, crate)
  airlock_door.gd      AirlockDoor: "[F] ENTER/EXIT" prompt and the door cutscene, both ways
  overworld.gd         builds the overworld, doors, intro, test hooks
  interior.gd          builds the interior, exit door, test hooks
  repair/              circuit model/catalog, machine state, power-flow timeline, native panel, world adapter
  crash_site.gd        the satellite crash intro and the smouldering wreck
  biome_fx.gd          live plants, bioluminescence, pools, ice glints, embers
  dome_fx.gd           dome rim lights, airlock blinkers, comms beacon, animated dome parts
  wind_fx.gd           weather per land: dust gusts, spores, snow
  interior_fx.gd       sun shafts and dust, sparks, leaking gas, fault LEDs, room-name toast
  map_screen.gd        M: full map overview (pauses the game)
  pixel_font.gd        PixelFont: the 3x5 pixel font for every bit of in-game text
shaders/
  day_night.gdshaderinc  the time-of-day light every world shader includes (day_night(), dn_sky())
  map_light            the map: time of day, with its light mask kept lit (and indoors the sun mask)
  graded               any other sunlit thing (given automatically by DayNight)
  depth_occlusion      the astronaut behind scenery: silhouette, or tinted behind glass
  prop_depth           props behind scenery: hidden, or tinted behind glass
  flora_depth          live plants hide behind cliffs and thin out round the astronaut
  crash_reveal         uncovers the untouched ground behind the crashing satellite
  dust_gusts           dithered wind-gust overlay
tools/                 the pipeline (Python): generates everything in assets/
  astronaut_sprite_gen.py   the astronaut and the multitool: SDF model, rig, every animation
  godot_spriteframes.py     astronaut.json -> astronaut_frames.tres (SpriteFrames)
  mars_map_gen.py           the overworld: terrain, biomes, domes, props, plants, all map data
  props_gen.py              test props for the multitool and the list of dead lamps
  interior_gen.py           the base interior: rooms, machines, data
  sfx_gen.py                every sound: fetches the recordings, synthesises the alien tech
  requirements.txt          what make env installs
  *_viewer.html             browser previews of the sprites and the map
  wire_repair.html          browser companion to the native circuit panel
data/repair_circuits.json   authored five-circuit sequences for power and oxygen machines
assets/                (lowercase, always)
  characters/astronaut/     generated sprite sheets, astronaut.json, astronaut_frames.tres, previews
  characters/Astronaut_in_his_space_suit/   OLD reference art, not used by the game; don't build on it
  maps/red_planet/          generated overworld: map, depth, walk, biome, light, fx, props, flora, anim, previews
  maps/base_interior/       generated interior: map, depth, walk, light, sun, json, anim (door), preview
    machines/               the reactor and the oxygen generator as standalone sprites (+ machines.json, 4x previews)
  audio/                    generated sound: *.wav, audio.json, viewer.html, SOURCES.md,
                            CREDITS.md (ship this), preview.json
  audio/sources/            the open-licence recordings, git-ignored (make sources)
```

---

## 4. How the game is built

### 4.1 Pre-rendered world plus data layers
The world is not made of tiles or 3D meshes. Each map is **one big pre-rendered image**, plus
data images and JSON written by the same generator so they always match the picture exactly:

| File | Contents |
|---|---|
| `*_map.png` / `base_interior.png` | the picture |
| `*_depth.png` | per map pixel: camera depth (world Y × `depth_scale`) as 16 bits in R (high) and G (low); **B = 255** means dome glass, **B = 96** means a live plant (overworld) |
| `*_walk.png` | a 1-world-unit grid, pixel (u, v): R, G = 16-bit ground height `(z + height_offset) × height_scale`; **B = 255** walkable, **128** too steep (you can jump over, onto or down it), **0** solid |
| `red_planet_biome.png` | RGB = how much red dust / forest / ice (sums to 255) |
| `*_light.png` | grey: how much of each map pixel is its own light (lamps, lit windows, LEDs, glowing plants, pools and crystals, the light pooling round them, the stars). Kept lit at night |
| `base_interior_sun.png` | grey: how much of each pixel is daylight coming in (shafts, sunlit patches, the windows' glow). Taken away at night |
| `flora/*.png` | plant sheets: colour frames on top; below them the same frames' depth in **R** and, in **G**, 255 where the plant glows on its own |
| `*_map.json` / `base_interior.json` | projection constants (`game`, incl. `light_png` / `sun_png`), spawn, domes, zoom frames, door, fx |
| `red_planet_fx.json` | plants, glows, halos, crash scene, dome cracks, airlock doors |
| `red_planet_props.json` | sprite sheets and placements of the multitool test props, dead lamps |

Scripts must **read positions from this data** (door positions, LED pixels, crack outlines and
so on). Never hard-code a map pixel position in a script. If you need one, the generator
exports it.

`base_interior.json → repair_machines` contains `id`, `label`, `world`, `stand_world`
(interaction position in world units), and `progress_px` (bar anchor in map pixels).
`interior_gen.py` derives these from the actual machine model centres; its
`--repair-metadata-only` option updates just this data using the existing projection origin.

### 4.2 Coordinates: one projection everywhere
- **World**: X right, Y away from the camera, Z up, in *world units*. Gameplay lives here.
- **Map pixels**: `screen = (origin_x + X / world_units_per_px, origin_y − (depth_to_px · Y + Z) · px_per_unit)`.
  Use `MapTerrain.to_screen(p, z)`; never re-derive it.
- **Walk grid**: `u = (X + Y)/√2`, `v = (Y − X)/√2`, one cell per world unit.
- The constants: `PX = 2` map pixels per world unit of height, `world_units_per_px = cos30°/2 ≈ 0.433`,
  `depth_to_px = tan30° ≈ 0.577`. The camera is a 2:1 pixel-isometric orthographic view with
  a 30° pitch.
- **Sprite units**: 1 sprite pixel of height. `character_scale = 0.5` converts them to world
  units (the astronaut is 44 px = 22 world units tall). Player speeds are in sprite units/s.
- The interior is its own small world. Its rooms sit around Y ≈ 520 in its own coordinates
  (storage at (0, 520), power (236, 530), oxygen (−236, 530)) and share nothing with the overworld.

### 4.3 Draw order, depth and y-sorting
- **Overworld nodes, in draw order:** `Map` → `CrashSite` → `BiomeFX` → `DomeFX` → `Actors`
  (y-sorted: Player, props, doors) → `Multitool` → `WindFX` → `MapScreen`.
  (`Ambience` sits in the tree between `Multitool` and `WindFX` but draws nothing; see §4.8.)
- **Interior nodes, in draw order:** `Map` → `InteriorFX` → `Actors` → `Multitool`.
- Anything that moves in front of or behind the pre-rendered scenery must use a depth shader
  with `sprite_depth` = world Y of its feet:
  - `depth_occlusion` for characters (they show as a silhouette behind things);
  - `prop_depth` for props (they hide behind things).
  Both tint through glass.
- `snap_2d_transforms_to_pixel` is on, so **y-sort keys and offsets must differ by whole
  pixels**. Half-pixel offsets tie and swap draw order at random.

### 4.4 Day and night: how things are lit
`DayNight` sets five shader globals every frame (`dn_mul`, `dn_add`, `dn_sat`, `dn_night`,
`dn_lamp`, declared in `project.godot`). Everything in the world must take them:
- **A shader that draws the world** `#include`s `res://shaders/day_night.gdshaderinc` and passes
  its sunlit colour through `day_night(colour, map_px)` (or `dn_sky(colour)` when it has no map
  position). See `depth_occlusion`, `prop_depth`, `flora_depth`.
- **A world node with no material** gets the `graded` material from `DayNight` automatically,
  including nodes added later. Smoke, dust, gas, snow, sprites: nothing to do.
- **Lights must say so**, or they go dark at night: draw them in a child node with an additive
  `CanvasItemMaterial`, or in a node tagged `set_meta("dn_unlit", true)` (fire, sparks, beacons,
  warning lamps, beams and world-space prompts do this). On the map, a part drawn with an
  `EMISSIVE` ramp is written into the light mask by the generator; a plant part, into its sheet's
  glow row.
- **Sunlight effects fade at night**: multiply them by `DayNight.daylight` (sun glints, the
  interior's shafts and their dust).
- UI on its own `CanvasLayer` is never graded.

### 4.5 Input
Actions are registered **in code**, in each script's static `_ensure_actions()`, with a
`has_action` guard, keyboard *and* gamepad. Add new actions the same way. Don't add them to
`project.godot` by hand.

| Action | Keyboard | Gamepad | Where |
|---|---|---|---|
| move | WASD / arrows | left stick (part tilt walks slower) | player.gd |
| run | Shift | right shoulder | player.gd |
| jump (hold for higher) | Space | A | player.gd |
| tool_toggle (take out / put away) | T | Y | multitool.gd |
| tool_use (hold: mine, gather, fix; tap: lift / set down) | F | X | multitool.gd |
| interact (doors) | F | X | airlock_door.gd |
| toggle_inventory | E | Start | inventory_ui.gd |
| hotbar select | 1-6 / mouse wheel / click | left shoulder cycles | inventory_ui.gd |
| zoom_in / zoom_out (overworld only) | I / O | d-pad up / down | game_camera.gd |
| toggle_map (Esc also closes) | M | Back | map_screen.gd |

F / gamepad X is shared: while a door's prompt is showing, the door sets
`multitool.suppressed = true`, so it opens the door instead of using the tool.
Inventory pauses the world and independently sets `multitool.inventory_suppressed`;
after closing, F / X must be released before interactions resume. The inventory consumes
modal input before map/camera handlers. Do not add another meaning to these buttons
without the same suppression mechanism.
Machine repairs use `multitool.repair_suppressed` independently, pause the world and consume
modal input. F/X must be released after closing. On the board, arrows/WASD/d-pad select
movable modules; Enter/Space/F/A turns clockwise, Q/left shoulder turns back, Esc/B closes.
Mouse left/right click turns clockwise/back. Bolted modules and plates are skipped.

### 4.6 Scenes and state
- Cross-scene state lives **only** in the `GameState` autoload:
  - `intro_done`: the crash plays once;
  - `arrive` and `door_id`: where to appear next;
  - `tool_out`: the multitool stays out across the airlock;
  - `clock`: game hours since the start (`DayNight` turns it into the day, hour and part of
    the day).
  - `inventory`, `selected_slot`: 24 slot dictionaries (`kind`, `count`), first six are
    quick access. Empty slots are `{}`. Item kinds are `multitool`, `ore_chunk`, `scrap`;
    resources stack to 99. Use `store_item`, `swap_slots`, `select_slot` and listen to
    `inventory_changed`. A full bag leaves gathered props in the world.
  - `removed_props`, `spawned_props`: session ledger for gathered props/mined rocks and
    their loose chunks. IDs derive from props JSON path/index, with `/chunk/N` for mined
    chunks. Generated JSON is unchanged. Saving to disk is not implemented.
  - `machine_repairs`: `MachineRepair` instances obtained through `repair_for(id)`.
    Each stores its current puzzle, countdown, circuit index and completed repair tasks.
    Closing a panel or changing scenes preserves the attempt; leaving pauses its countdown.
- Going in: an overworld door emits `entered`, then `overworld.gd` sets `GameState` and
  changes to `interior.tscn`, which plays `door.arrive()`. Going out works the same way in
  reverse. Both base airlocks lead into the same storage room. You come back out of the one
  you went in by.

### 4.7 Effects pattern
FX scripts draw procedurally in `_draw()`:
- Positions come from the fx JSON. Draw only what the camera sees, and round every
  position to whole pixels.
- Glow goes in a child `Node2D` using `CanvasItemMaterial.BLEND_MODE_ADD`.
- Soft shapes come from cached `ImageTexture`s: the `_halo(r)` (dithered) and `_disc(r)`
  pattern.
- **Additive light disappears on white surfaces.** Anything that must read on the white
  machines (sparks, for example) is drawn as solid pixels in a `dn_unlit` layer, with only
  the halo additive.
- Keep light and matter in separate nodes (see §4.4): smoke in one, the fire in it in another.

### 4.8 Sound
There is no music. There is the environment of the red planet and the sounds of working on it.

**Sound is data.** `tools/sfx_gen.py` writes `assets/audio/*.wav` plus `audio.json`, and the
`Audio` autoload plays what that file says. Which file, which bus, how loud, how far it
carries, how much its pitch wanders per play, whether it loops, how long it fades: all of it
is in the JSON. **Nothing about a sound is decided in GDScript.** Retuning the mix is a
generator change, not a code change.

| File | Contents |
|---|---|
| `assets/audio/*.wav` | 16-bit mono PCM at 22050 Hz. Looping ones carry a `smpl` chunk, which is how Godot knows where the loop is |
| `assets/audio/audio.json` | bus levels, and per sound: its files (variants), bus, `gain_db`, `loop`, `seconds`, `pitch` range, `dist` (how far it is heard, map px), `fade`, and a `note` saying which recording it came from and why |
| `assets/audio/SOURCES.md`, `CREDITS.md` | every source pack, author, licence, URL. **`CREDITS.md` must ship with the game**: some packs are CC BY |
| `assets/audio/viewer.html` | listen to every sound, with its waveform, at the game's real levels |
| `assets/audio/sources/` | the raw recordings. Git-ignored; `make sources` fetches and checksums them |

Three ways to make a noise, all through the autoload:

```gdscript
Audio.play("rock_burst", screen_px)            # one-shot, positional (map pixels)
Audio.play("ui_map_open")                      # one-shot, flat
Audio.loop("beam_mine", "beam:mine", tip_px)   # held until release("beam:mine")
Audio.bed("amb_ice", weight)                   # ambience, crossfaded 0..1
```

- Buses (`amb`, `sfx`, `ui`) are created **in code** in `Audio._ensure_buses()`, for the same
  reason input actions are (§4.5). Don't add them to `project.godot` or a bus layout resource.
- Positions are **map pixels**; the 2D listener is the active camera. A sound further away
  than its `dist` is never started, so the comms dome's blinkers cost nothing from the base.
- **Put the call where the event already is.** Whatever owns the state owns its sound:
  `interior_fx.gd` plays `spark` where it spawns the sparks, `dome_fx.gd` ticks the beacon in
  step with the strobe it draws, the rock's crack sounds where its frame changes, footsteps
  come off the drawn gait. Never add a second timer that re-derives when something happens;
  it will drift out of step with the picture.
- Footsteps: contact is frame 0 and the middle frame of the walk/run cycle (the gait plants
  the left foot at phase 0 and the right at 0.5 — see `foot_cycle` in
  `astronaut_sprite_gen.py`), so they stay on the feet at any speed. The surface comes from
  `player.step_source`, which the scene sets: the overworld reads the biome image, the
  interior is always its tiled floor.
- Leaving a scene: `Audio.enter_scene()` at the top of the scene's `_ready`, or a beam will
  follow the astronaut through the airlock. Quitting: see §8.

---

---

## 5. Mechanics reference (current behaviour)
Change these only on purpose, and record the change in §12. The values are `@export`s and
consts in the named files.

- **Movement** (`player.gd`):
  - 8 directions; walk 71 sprite units/s; run = drawn run cycle × 1.8.
  - When blocked, you glide along the obstacle.
  - Steep ground (B = 128) can't be walked up, but you can jump onto, over or down it.
    Standing on it makes you slide.
  - Solid ground (B = 0) and `MapTerrain.blockers` (props) always stop you.
- **Jump**: a low-gravity moon jump.
  - Holding jump goes higher; letting go early cuts it short.
  - There's a floaty hang near the top, plus crouch and land squash.
- **Camera** (`game_camera.gd`):
  - Overworld: 4 zoom levels; the furthest frames the whole main base and never more.
    In-between levels land on whole-pixel scales at 1080p.
  - Interior: `zoom_locked = true` (no zooming).
  - Cutscenes use `focus_override`, `snap_to` and `release_focus`.
- **Multitool** (`multitool.gd`, `player.gd`):
  - T plays an 18-frame equip animation: the device on the backpack unfolds into a red-and-gold
    gauntlet on the right forearm.
  - With the tool out, every animation has a `_tool` version.
  - The tool **picks its job from the target in reach** (40 units). Use F / gamepad X.
    An icon over the nearest
    target shows which job it will do:

    | Job | Colour | Target | How it works |
    |---|---|---|---|
    | mine | orange `#ff8a3a` | ore rock | hold F for 1.6 s; the rock bursts into chunks |
    | gather | teal `#4fe0c8` | ore chunk, scrap | hold F for 0.55 s; a spiral pulls it into the backpack |
    | lift | violet `#b583ff` | crate | tap F to float it so it follows you; tap again to set it down |
    | fix | cyan `#7fd8ff` | dead lamp | hold F for 2.4 s; the lamp flickers back on |

  - Inventory now shows resource stack counts (§12); there are no health/resource bars.
- **Inventory** (`inventory_ui.gd`): six-slot bottom hotbar; E / Start toggles the paused
  24-slot backpack. Click two slots to swap, or arrows/d-pad and Enter/A to pick/place.
  Esc/B cancels a pending swap first, then closes. 1-6/wheel/left shoulder select hotbar;
  selecting the multitool equips it, selecting resources/empty slots holsters it.
  T/Y remains available. Ore/scrap have no consume/crafting action yet. Crates remain
  world objects handled by lift. Opening/closing without changing selection preserves
  the existing tool state. Inventory is blocked during intro/door cutscenes or map pause.
- **Machine repairs** (`scripts/repair/`): F/X near the power or O2 generator opens one
  rotating-wire circuit. Each machine has five authored layouts; after 30 active seconds
  without a solution it advances to the next, reshuffles and resets the timer. Bolted wires
  conduct but stay fixed. A matching supply-to-output route completes wiring once (50%).
  Local machine bars show overall progress. The future cracks task accounts for the other
  50% through `GameState.repair_for(id).complete_task("cracks")`; the task and repaired
  machine art are not implemented yet.
- **Doors** (`airlock_door.gd`):
  - Within 30 units, a `[F] ENTER` / `[F] EXIT` prompt shows.
  - Pressing F starts a cutscene: the camera moves behind the astronaut, the warning lamp
    blinks, the door unseals and vents gas, the astronaut walks in, the door closes, and
    the screen fades.
- **Intro** (`crash_site.gd`): the satellite crash-lands near the base, once per run, and any
  button skips it. Afterwards the wreck keeps smouldering.
- **Map screen**: M toggles it. It pauses the game and shows where you are and what the camera
  sees. Sound carries on while it is open (the `Audio` autoload always processes).
- **Day and night** (`day_night.gd`, `day_clock.gd`):
  - A game day lasts **12 real minutes** (`day_minutes`). The game starts on **day 1 at 08:00**.
    The clock runs indoors too, and stops while the map screen is open.
  - Four parts of the day: **MORNING** 05:00–11:00, **NOON** 11:00–16:00, **EVENING**
    16:00–20:00, **NIGHT** 20:00–05:00. A new day begins at **05:00**.
  - The light: a pink dawn, a warm morning, a clear noon, a golden evening, a violet dusk and a
    deep blue night (`KEYS` in `day_night.gd`). At night, what glows on its own stays lit, and
    a soft pool of light follows the astronaut.
  - The time panel sits top left, and a "DAY N" title comes up at dawn. It is hidden during the
    crash intro and comes in with "DAY 1" when it ends.
  - Time changes nothing in play yet (no sleep, no night dangers).
- **Sound** (§4.8, §7.6): the three lands each have their own ambience, crossfaded by the land
  you are standing in; the pools, spires, burning wreck and powered domes can be heard from
  near them; everything you do makes a noise. No music.

---

## 6. The art pipeline

### 6.1 How art is made
All art is **rendered by code**. Signed-distance-field (SDF) models are ray-marched straight
at pixel resolution through the game's exact camera, then cel-shaded from hand-picked colour
ramps, dithered, inner-lined and outlined. This is why everything matches. Do not import
hand-drawn, AI-generated, downloaded or upscaled art into the game.

This rule is about **art**. Sound is deliberately different: real recordings carry the weight
of the physical world in a way synthesis does not, so the natural half of the soundtrack is
open-licence field recordings and only the alien tech is generated. The consistency comes from
one mastering chain instead (§4.8, §7.6). If something new is needed,
**model it in the generator** with the existing primitives (`Sphere`, `Ellipsoid`,
`RoundBox`, `RoundCone`, `Torus`, `Disc`, and the interior's `Cut` / `Either` for carving) and
the existing renderer (`render_groups` / `render_sprite`).

### 6.2 Generators

| Generator | Writes | Run it when | Time |
|---|---|---|---|
| `python tools/astronaut_sprite_gen.py` then `python tools/godot_spriteframes.py` | `assets/characters/astronaut/*` | you change the astronaut, the multitool or any animation | slow (about 1,000 frames); `--quick` writes only the contact sheet |
| `python tools/mars_map_gen.py` | `assets/maps/red_planet/*` | you change anything on the overworld | about 3 minutes, several GB of RAM |
| `python tools/props_gen.py` | `assets/maps/red_planet/props/*`, `red_planet_props.json` | after **every** map regeneration, or when you change props | fast |
| `python tools/interior_gen.py` | `assets/maps/base_interior/*` | you change the interior | a few seconds |
| `python tools/sfx_gen.py` | `assets/audio/*` | you change any sound | fast (needs `make sources` once) |

**The generators share code.** `mars_map_gen.py` imports `astronaut_sprite_gen.py` (SDF
primitives, ray-marcher, base palette), and `props_gen.py` and `interior_gen.py` import both.
If you change shared code (a ramp, the renderer, `hole_shape`, the outline) you must
**re-run every generator that uses it** and check all of their outputs.

**Design versions** are switched with environment variables. They are kept so earlier approved
designs can be compared or restored:
- `BASE_DESIGN` = `v1` | `hex` | `v2` | `v3` (default **v3**) — the main base.
- `TOOL_DESIGN` = `v1` | `v2` (default **v2**) — the multitool.
- `MAP_OUT=<folder>` writes the map somewhere else, so you can preview a design without
  replacing the game's map.

Running with a non-default design and `MAP_OUT` unset **replaces the game's assets**.

After regenerating, **re-import** (`godot --headless --path . --import`, or focus the editor)
before you run the game.

### 6.3 Data contracts
The generators write the JSON keys that the scripts read. If you rename, remove or reshape a
key, update **every** reader in the same change (search `scripts/` for the key). Keys that are
waiting for a future feature are documented in §11. Don't remove them.

`audio.json` is the same kind of contract: `scripts/audio.gd` is the only reader, and every
field in it exists because something in the game asks for it (§4.8).

### 6.4 Recipes
- **A new prop or machine:**
  1. Model it in the generator with existing primitives and existing ramp names.
  2. Give it a decal function for printed detail.
  3. If the player can walk around it, check that it blocks the walk grid only where it
     really stands (the interior builds footprints by sampling the SDF from floor to body
     height, so overhead pipes don't block).
  4. If it needs to animate or be interactive, export its positions to the fx JSON and draw
     the motion in the scene's FX script.
- **A new loose interactable** (like the test props): render it as a sprite sheet in
  `props_gen.py`, place it in the props JSON, and let `WorldProp` / `Multitool` handle it.
  Give it one of the four jobs, or propose a new job first (§10).
- **Something that glows:** give its part an `EMISSIVE` ramp in the generator (the map's
  light mask and the plant sheets' glow row pick it up). If it is drawn by a script, draw it
  in an additive or `dn_unlit` layer (§4.4).
- **A new scene:**
  1. Copy the interior's structure: a generator for the picture and data (including its light
     mask), a `MapTerrain` from its JSON, the player's `setup`, and a scene FX script.
  2. Add a `DayNight` node and call `setup(player, $Map, terrain.light_mask, terrain.sun_mask)`.
  3. Add test hooks like `interior.gd`'s.
  4. Move between scenes through `GameState`.

---

## 7. Art bible (the look)

### 7.1 Projection and scale
- Everything is drawn through **the same camera**: 2:1 pixel isometric, orthographic, 30°
  pitch.
- Maps are rendered at `PX = 2` pixels per world unit of height.
- **The astronaut:**
  - 64×64 frames, feet anchored at (32, 56).
  - 8 directions: N NE E SE S SW W NW.
  - 44 px tall on screen, which is 22 world units.
- **Scale references:**
  - path lamps ≈ 22 units (as tall as the astronaut);
  - airlock doors ≈ 1.6 × the astronaut;
  - domes are designed at base size and scaled by `DOME_SCALE = 2.5` as a whole.
- New objects must be sized against these.

### 7.2 Light and shading
- **The sun comes from the upper left, in front:** `SUN = (−0.62, −0.32, 0.62)` on the
  overworld. Inside, the light falls from the front left (`SUN_IN`), and shafts of daylight
  come in through the broken windows (`LIGHT_IN`).
- **Cel shading:**
  - objects use 4-tone ramps; terrain uses 7–8-tone ramps;
  - tones are blended with a **4×4 Bayer ordered dither**;
  - no smooth gradients, no anti-aliasing, no blur.
- **Glow:** only real light sources (lamps, LEDs, screens, crystals, glowing plants) get a
  soft bloom. It is added on top, never painted into the colours.
- **Outline:** a 1 px silhouette in **`#22182c`**. Inner edges (where one surface passes in
  front of another) get a line in a darker shade of the surface's own colour.
- **Time of day** is applied in the game, not baked into the art: the art is always rendered
  in daylight, and `day_night.gdshaderinc` colours it. Change the look of a time of day only in
  `KEYS` (`day_night.gd`), and keep it cozy. The night is deep blue-violet, never black, and
  things that glow carry it.

### 7.3 Palette
- Ramps run dark → light. **Shadows lean violet; lights lean warm cream or peach.** Every
  colour comes from a named ramp:
  - `A.RAMPS` in `astronaut_sprite_gen.py` (the astronaut and the tool);
  - `T_RAMPS` / `T_RAMPS_F` / `T_RAMPS_I` and `STRATA*` in `mars_map_gen.py` (terrain for
    red dust, forest and ice);
  - `O_RAMPS` in `mars_map_gen.py` (objects), extended in `interior_gen.py`.
- **Use an existing ramp.** If you really need a new one:
  - give it 4 colours, hue-shifted the same way (darks toward violet, lights toward warm);
  - register it in the ramp dictionary;
  - add it to `EMISSIVE` only if it is a light source;
  - note it in §12.
- **Accent colours used throughout:**

  | Colour | Hex |
  |---|---|
  | coral | `#ec7a5a` |
  | mustard | `#efb950` |
  | teal | `#4fc6b4` |
  | glossy white | `#fbfbff` |
  | amber warning light | `#ffb24a` |
  | fault red | `#ff5a4a` |
  | screen cyan | `#7fe6cf` |
  | outline / dark plates | `#22182c` |
  | night void | `#0b0915` |

  FX colours in GDScript are `const Color("#…")` taken from these ramps.

### 7.4 The world
- **Lands:**
  - **red dust** around the main base: dunes, mesas, craters, spiky ranges;
  - **alien forest** around the nursery dome: violet-teal moss, glowing pools, crystal
    spires, swaying alien plants;
  - **ice** around the comms dome: snowfields, frozen lakes, charcoal peaks and cliffs
    under snow.
  - The comms dome sits on a stepped charcoal massif reached by ramped trails.
  - Lands blend with soft, dithered, domain-warped edges, never hard lines.
- **Trails, not roads.** Nothing is drawn on the ground: a trail is the way through where
  nothing grows. Toward a trail the forest thins out gradually and unevenly, and tall plants keep
  out of the strip just in front of it (from this camera they would hide it). Lamps line the way.
  Trails wind; they are never straight. The map screen shows them as dotted routes.
- **The main base (v3):**
  - three smooth white rooms joined by corridors;
  - a ring of tinted, reflective honeycomb glass round each room, with straight borders
    between glass and metal and thin frame lines;
  - two smashed holes per room, each a different irregular shape.
- **The base is dead at the start** (`BASE_POWERED = False`): no lights, nothing turning.
  The nursery and the comms dome are powered.
- **Inside:**
  - glossy white walls with a coral strip, a dark kick plate and a window band;
  - glossy diamond-tile floors;
  - the power is out, so daylight comes through the holes.
  - The power room has a smashed reactor with spilling wires and an open service cabinet
    with a circuit board.
  - The oxygen room has a broken oxygen generator, two O2 bottles and scrap.
- **Mood:** cozy, clean, beautiful and hopeful. Damage reads as clean, readable shapes
  (cracks, gashes, loose wires, sparks), never grime or gore.

### 7.5 UI and text
- All text is `PixelFont` (3×5 glyphs): scale 1 for prompts, scale 2 for titles. Extend its
  glyph table if you need a letter; never use a vector font.
- Prompts read `[F] LABEL` for world interactions, in capitals; E opens the backpack.
- Room titles fade in at the top of the screen on a dark translucent plate with a coral
  underline (`interior_fx.gd`). Reuse this look.
- The **time panel** (top left) is the model for any panel: a dark translucent plate
  (`#120f1d`-ish at 84 %) with a 1 px `#22182c` edge, pixel-rounded corners, a faint top
  highlight, PixelFont text and the part of the day's colour as the accent.
- No HUD clutter (see §9).

### 7.6 Sound (the ear)
The same rule as the eye: everything must sound as if one person made it.

- **No music.** Not "no music yet": the planet is quiet, and that quiet is the point. What
  fills it is wind, machinery, and the noise of your own work.
- **Two layers, and the line between them is deliberate:**
  - *recorded* — wind, snow underfoot, fire, water, stone, sheet metal, switches. Real
    recordings, because nothing synthesised sounds like real snow. Open licences only (§10.2).
  - *synthesised* — the multitool's beams and lens, the lamps, the crystal spires, the
    beacons, the UI. Generated in `sfx_gen.py`, because a recording of Earth hardware sounds
    like Earth hardware, and none of this is from Earth.
- **One mastering chain.** Every sound, recorded or not, is resampled to mono 22050 Hz,
  filtered, loudness-matched with `rms_to` and peak-limited by the same code. That is what
  makes a field recording sit next to a synthesised beam. Do not bypass it.
- 22050 Hz reaches 11 kHz. That is a choice, like the 384×216 viewport: it is all the wind,
  grit and metal here need, and it keeps the whole soundtrack a few MB.
- **Nothing is a note.** Struck things use inharmonic partials; the spires breathe one tone
  that never resolves anywhere. The moment two sounds imply a key, it is music (see above).
- **Quiet by default.** Ambience sits around -21 dBFS RMS, one-shots around -18, UI ticks
  near the threshold of notice. A sound that makes you look at the mixer is too loud.
- **Earth wildlife is not on this planet.** Several otherwise-perfect "forest" recordings are
  full of birdsong and crickets; `--probe` measures onset rate in the 2-8 kHz band so you can
  tell before you listen. The alien forest is a low drone plus synthesised voices instead.
- Anything that happens on screen and matters should be audible, and anything audible should
  be happening on screen. Sound is placed where the light is: the pools, spires and embers get
  their positions by clustering the glow points the map generator already exports.

---

## 8. Testing and verification

`godot` below means your Godot 4.7.2 executable (on Windows, the `_console.exe` build prints
errors to the terminal). The scenes take test hooks after `--`; the full lists are in the
headers of `overworld.gd` and `interior.gd`:

```
make verify                        # import + both scenes headless, fails on any error/warning
make shot ARGS="--spawn=-827,1440 --seconds=2"
make sounds                        # listen to every sound at the game's real levels
```

Or by hand:

```
godot --headless --path . --import                                   # re-import after regenerating
godot --headless --path . res://scenes/overworld.tscn --quit-after 20000 -- --no-intro --quit=4
godot --headless --path . res://scenes/interior.tscn --quit-after 20000 -- --quit=4
godot --path . res://scenes/overworld.tscn -- --spawn=-827,1440 --capture=shot.png --seconds=2
godot --path . res://scenes/interior.tscn -- --spawn=-236,492 --walk=0,-1 --capture=walk.png --seconds=3
godot --path . res://scenes/overworld.tscn -- --door --capture=in.png   # through the airlock; the interior takes the shot
godot --path . res://scenes/overworld.tscn -- --no-intro --time=22 --capture=night.png   # check a change by night too
godot --headless --path . res://tests/inventory_test.tscn             # inventory integration suite
godot --headless --path . res://tests/repair_test.tscn                # circuits + real machine/input integration
godot --path . res://tests/repair_gallery.tscn -- --out=ABSOLUTE_DIRECTORY  # all ten native boards + solved states
node tools/test_wire_repair.cjs                                     # browser circuit model checks
godot --path . -- --no-intro --inventory-demo --open-inventory --capture=bag.png
```

Useful hooks:
- `--spawn=X,Y`, `--walk=DX,DY[,run]`, `--capture=PATH`, `--seconds=S`, `--burst=N`, `--gap=S`
- `--quit=SECONDS`, `--audio-debug` (both scenes)
- overworld only: `--equip`, `--use`, `--face=DX,DY`, `--door`, `--intro` / `--no-intro`,
  `--zoom=L`, `--open-map`, `--debug`
- interior only: `--arrive`, `--exit`, `--repair=power|oxygen`,
  `--repair-done=power|oxygen` (wiring credit for screenshots), `--repair-bars`
  (ignore ambient F input during progress-bar captures)
- repair panel: `--reduced-motion` disables turn and completion animation; receiving
  power activates immediately. The browser follows `prefers-reduced-motion`.
- both: `--time=HOUR` (e.g. `--time=22` for night), `--day=N`, `--day-speed=X` (time runs X
  times faster)

**Quit with `--quit=SECONDS`, not with `--quit-after`.** `--quit-after` counts *frames*, and a
headless frame can take under a millisecond, so it is unpredictable in wall-clock time and it
ends the process behind the game's back. `--quit` runs for a real number of seconds and then
awaits `Audio.quiet()` before quitting, because a sound still playing when the engine tears
down is reported as a leaked playback (the mixer drops a stopped playback the next time it
mixes, and during shutdown there is no next mix). Keep `--quit-after` as a high backstop in
case a scene hangs — high enough that it cannot win the race. If you ever see
`ObjectDB instances were leaked` together with `resources still in use`, that is this.

**Sound has no screenshot.** Prove it twice:
- `--audio-debug` prints every event as it plays (`[audio] rock_crack at (…) pitch=1.10`),
  which shows the trigger fired, in the right order, in the right place. This is how an
  automated run checks sound.
- `make sounds` opens `assets/audio/viewer.html`: click a waveform to hear it, at the real
  `gain_db` and bus levels. Looping sounds latch, so you can stack a land's bed with what
  lives in it. Then say what you heard.

**Definition of done:**
1. Both scenes run headless with **no errors or warnings** (`make check`).
2. You captured screenshots of what you changed and **looked at them**, at 1:1 and zoomed in,
   **by day and by night** (`--time=12`, `--time=22`).
3. Walk tests show the astronaut can reach everything they should, and nothing else.
4. Any sound you touched fires in an `--audio-debug` run, and you listened to it in the viewer.
5. Previews and viewers (`assets/maps/red_planet/preview/`, `assets/audio/viewer.html`,
   `tools/*_viewer.html`) still look right if your generator writes them.

---

## 9. Locked decisions (owner approval needed to change)
- The camera, projection, scale, sun direction, outline colour, dithering and palette
  family (§7).
- The astronaut's proportions and animation set; multitool design **v2** (red and gold
  gauntlet) is the default.
- Main base design **v3** is the default. The old designs stay available as versions.
- The three lands and where they are; the comms massif.
- **Trails are not drawn on the ground**: they form where the plants thin out, and lamps line
  them.
- The base starts dead and broken; it gets repaired through play.
- **No HUD bars**; inventory stack counts, a six-slot hotbar, local machine repair
  progress bars and the time panel (day number and part of the day) are approved (§12).
- **A day/night cycle** with four parts of the day; lights stay lit at night.
- The multitool picks its job from the target. One button (F / gamepad X) uses it.
- **No zooming indoors.**
- **Dome cracks keep their original look** (a thin bright rim, no heavy dark outline).
  Each room has two different irregular holes, kept as data so they can be traced later.
- **No music.** Sound is the environment and the work, nothing else (§7.6).
- **Sound is data, not code**: every sound is declared in `sfx_gen.py` and read from
  `audio.json`. The alien tech is synthesised; the natural world is recorded, under an open
  licence, through one mastering chain (§4.8, §7.6).

---

## 10. Working together

### 10.1 Designs and approvals
- **New mechanics are proposed before they are built.** Write a short design (what the
  player does, what they see, how it fits the existing jobs and controls) and get the owner's
  OK. This is how the multitool was made.
- **Never throw away an approved design.** When you replace a major asset, keep the old one
  as a numbered version (`v1`, `v2`, …) behind a constant or environment variable, leave the
  approved one as the default, and only switch the default after approval.
- Small fixes that follow the rules here need no approval. Changes to anything in §9 do.

### 10.2 Git
- Branch per task: `feature/<thing>` or `fix/<thing>`. Commit messages follow the existing
  style: `feature: zoom|slopes|animations`, `fix: walk/run speed`.
- **Commit a generator change and its regenerated outputs together**, in one commit, so the
  repo always matches its tools.
- **Generated images and JSON cannot be merged.** On a conflict, take either side, re-run the
  generator on the merged code, and commit the result. Avoid conflicts by saying which
  generator you are working on before you start; only one person at a time per generator.
- Pull before you regenerate. Regenerate on the latest code.
- Commit `*.import` and `*.uid` files (Godot needs them for stable references). Never commit
  `.godot/` or `__pycache__/` (see `.gitignore`).
- **Keep the folder `assets/` lowercase**, and match the case of every path exactly. Windows
  ignores case; Linux, and therefore other people's machines, does not.
- **Sound sources are other people's work.** `assets/audio/sources/` is git-ignored: the repo
  keeps the baked `*.wav`, and `PACKS` in `sfx_gen.py` records every source's author, licence,
  URL and SHA-256 so `make sources` can fetch and verify them. Only **CC0 or CC BY** may go in.
  A checksum mismatch stops the build on purpose: a pack whose contents changed is a pack whose
  licence you have not read. `assets/audio/CREDITS.md` is generated from that table and lists
  the CC BY packs; **the licence requires the game to ship it**.
- Move or rename resources in Godot's FileSystem dock so references update, or update every
  `res://` path by hand.
- Line endings are normalised by git. Don't reformat or convert whole files; keep diffs to
  what you changed.

### 10.3 For AI agents specifically
- Follow this file over your own habits. Match the surrounding code: its naming, comment
  density, typing and idioms.
- `.claude/skills/` holds the procedures for the three things you will actually be doing:
  `art-pipeline` (anything visual), `sound-pipeline` (anything audible), `verify` (proving it
  works). Read the matching one before the first change of a task; this file is still the law.
- `make help` is the list of everything the pipeline can do. Prefer it to hand-written command
  lines, so a change to how the project builds only has to be made once.
- Don't guess at APIs or data. Read the code and the JSON. Search for every reader before you
  change a data key or a public function.
- Make the smallest change that does the job. No drive-by refactors, renames or
  reformatting.
- Never hand-edit generated assets. Change the generator, then regenerate.
- **Always verify visually** (§8) and report what you saw. Include screenshots for the human.
- Don't kill a running Godot editor. Don't run two generators that write the same folder at
  once. Don't commit or push unless you are asked to.
- When a request is a matter of taste (look, feel, layout), offer options or a mock-up first,
  in the style of §7.

---

## 11. Current state and open threads
- **The repair loop is partly implemented.** Wiring is playable; these pieces remain:
  - **Dome cracks to trace and fix:**
    - `red_planet_fx.json → cracks` has, per hole: room, id, shape, outline polygon, crack
      strokes, centre, world position, and patch image and position;
    - the images are in `assets/maps/red_planet/anim/cracks/`.
  - **The power room cabinet art** remains the original generated asset:
    - `base_interior.json → fx.circuit_board` has `center`, `socket`, the 4 `corners`
      (map px) and `world`;
    - `interior_fx.gd` pulses the empty socket.
  - **Reactor/O2 wiring is implemented:** F/X, five circuits each, timed replacement,
    session state, bolted wires and local progress bars. The native panel uses octagons,
    detailed PCB housings, a blue-green recess and neon green power (owner-approved).
    One circuit earns 50% repair; cracks and the fully repaired assets are still pending.
  - **Dead path lamps** by the base can be fixed with the tool (the `fix` job).
- **The multitool works on test props only** (ore rocks, chunks, scrap and crates near the
  spawn, from `props_gen.py`). Real ore deposits are not placed yet.
- **Inventory is implemented:** session backpack, resource stacks, quick access and slot
  swaps. Resources are gathered through the existing tool; crafting/consumption is not
  implemented. No new generated item art or map data keys.
- **Sound is built** (§4.8, §7.6): ambience for the three lands and the dead base, positional
  pools / spires / wreck / powered domes / repaired lamps, footsteps per surface, the jump,
  the four multitool jobs, the airlock cutscene, the crash, the backpack, the circuit panel
  and the UI. What is missing:
  - no volume controls and nothing saved (there are no settings and no save file yet);
  - `CREDITS.md` is generated but nothing in the game shows it yet. It must be shown before
    the game is distributed (§10.2).
- **Not built yet:** interiors for the nursery and comms domes, saving and loading (the clock
  would be saved with `GameState.clock`), anything that depends on the time of day, music
  (and there will not be any, §9).

---

## 12. Decision log (append only, newest last)
Write one line per decision: date — decision (who approved it).

- 2026-10-04 — v1: the generated astronaut, the red planet map and its depth and walk data,
  walking (owner).
- 2026-10-05 — Walk and run speeds tuned; zoom levels, slopes, jump and dome animations
  (owner).
- 2026-10-06 — Three lands: red dust, alien forest round the nursery, ice with charcoal peaks
  round comms. Bigger map, winding roads, comms dome on a stepped snowy massif (owner).
- 2026-10-06 — The satellite crash-landing intro near the base (owner).
- 2026-10-06 — Main base v3 (white rooms, honeycomb glass ring, irregular holes) is the
  default. v1, hex and v2 are kept as versions (owner).
- 2026-10-06 — Multitool: T to equip, E to use, job picked from the target
  (mine/gather/lift/fix), no counters. Design v2 (gauntlet) is the default; v1 is kept
  (owner).
- 2026-10-06 — Airlock door cutscene and the base interior (storage, power room right,
  oxygen room left) (owner).
- 2026-10-06 — Broken reactor with thin wires and a circuit-board cabinet; broken oxygen
  generator, O2 bottles and scrap; walkable footprints only at body height (owner).
- 2026-10-06 — No zooming indoors. Dome cracks keep their original look (owner).
- 2026-10-07 — Day/night cycle: 12-minute days, MORNING/NOON/EVENING/NIGHT, lights stay lit at
  night, a light round the astronaut. A time panel with a day counter (top left), the only HUD
  element (owner).
- 2026-10-07 — No drawn paths: trails form where the forest thins out naturally (owner).
- 2026-10-07 — Inventory feature request approves a visible six-slot hotbar, 24-slot
  backpack and resource stack counts. E opens/closes inventory; existing world interactions
  move to F (gamepad X unchanged). PixelFont/palette/generated sprites are reused; inventory
  pauses gameplay. Ore/scrap are stored in GameState, persist through scenes, and can be
  rearranged; no crafting or new resource-use jobs (owner's explicit inventory request).
- 2026-10-07 — Power/O2 generators get F/X circuit repair and local repair-progress bars.
  Five circuits per machine; one successful circuit completes wiring, with a new circuit
  after 30 active seconds if unsolved. Wiring earns 50%; cracks and fixed machine art come
  later. The panel uses minimal copy, a blue-green circuit-board palette and neon green
  connected wires. Octagonal detailed housings replace hexagons; fixed wires use bolts
  instead of padlocks (owner's explicit repair integration and octagon requests).
- 2026-10-07 — Enlarge the circuit terminals into a charged capacitor bank and receiving
  relay. A single bright pulse follows the player's actual connected route from source to
  receiver after solving; the relay closes and status LEDs light on arrival. The effect
  is skippable and does not delay repair credit (owner's terminal/animation request).
- 2026-10-07 — The pipeline gets a `Makefile`, a pinned Python env (`make env`, uv + `.venv`,
  `tools/requirements.txt`) and `.claude/` skills for working here (owner, requested).
- 2026-10-07 — Sound: ambience and interaction sounds, **no music**. Built by
  `tools/sfx_gen.py` into `assets/audio/` + `audio.json`, played by the `Audio` autoload.
  Hybrid by decision: open-licence field recordings (CC0 and CC BY) for the natural world,
  synthesis for the alien tech, both through one mastering chain. Source packs are fetched and
  checksummed rather than committed; `CREDITS.md` must ship (owner).
- 2026-10-07 — Scenes take `--quit=SECONDS`, which stops the sound before quitting, and
  `--audio-debug`, which prints every sound event. `make check` uses them, and runs the
  inventory and repair suites too (owner, requested).
- 2026-10-07 — The backpack and the circuit panel get sound: a real buckle for the pack, a
  real metal click per module turned, and synthesis for the screens and the charge reaching
  the relay. Everything that ends the process goes through `Audio.quit()` (owner, requested).
