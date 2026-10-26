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
  nursery.tscn         the damaged nursery, growing beds and two working airlocks
  player.tscn          the astronaut: Shadow, AnimatedSprite2D (depth-occlusion shader), GameCamera
scripts/
  game_state.gd        autoload GameState: the only state carried between scenes (incl. the clock)
  day_night.gd         DayNight: the clock, the light through the day, lights kept lit at night
  suit_light.gd        SuitLight: the lamp on the astronaut's suit (L / pad B), off until you light it
  day_clock.gd         DayClock: the time panel (sky window, day number, part of the day) and the new-day title
  audio.gd             autoload Audio: buses, one-shots, loops, ambience beds (§4.8)
  world_ambience.gd    WorldAmbience: the overworld's beds and the things you can hear
  inventory_ui.gd      six-slot hotbar and paused backpack; draws existing sprites and PixelFont
  map_terrain.gd       MapTerrain: walkability, ground height, biome, the views, world<->pixel projection
  map_stream.gd        MapStream: the window of the map that is in memory (§4.10)
  view_data.gd         ViewData: the map JSONs, parsed once
  perf_probe.gd        PerfProbe: --perf, what the game costs as it runs
  view_turn.gd         ViewTurn: G / H turn the camera round the world; loads the next views ahead
  turn_overlay.gd      TurnOverlay: the turn's swing, the world stood up in 3D for a moment
  player.gd            Player: movement, low-gravity jump, slopes, multitool states, cutscene puppet
  game_camera.gd       GameCamera: pixel-snapped follow, zoom levels, cutscene focus, shake, zoom lock
  multitool.gd         Multitool: equip, job picking (mine/gather/lift/fix) and their effects
  world_prop.gd        WorldProp: a loose thing the tool works on (rock, chunk, scrap, crate)
  solar/               stateless optics, session field state, world equipment/controls and engine inlet
  airlock_door.gd      AirlockDoor: "[F] ENTER/EXIT" prompt and the door cutscene, both ways
  overworld.gd         builds the overworld, doors, intro, test hooks
  interior.gd          builds the interior, exit door, test hooks
  nursery.gd           builds the nursery, both exit doors, four views and test hooks
  nursery_cleanup.gd   removable native litter for nursery and base, shared UNIT cleanup controller
  reserve_meter.gd     compact physical O2 wall reserve readout, native generated frames
  facility_air.gd       shared base/nursery O2 reserve, sealing and generator/solar supply
  cultivation_state.gd session nursery repairs, growing beds and wild seed cooldowns
  cultivation_world.gd F/X seed gathering, simple repairs, planting and harvesting
  crop_visual.gd       native crop depth/glow, four views and camera-swing boards
  repair/              circuit model/catalog, machine state, power-flow timeline, native panel, world adapter;
                       window_repair.gd / window_cracks.gd: storage's smashed panes and the cargo box
                       glass_puzzle.gd / glass_repair_ui.gd: live glass jigsaw and sealing scan
  story/               the opening chapter: StoryState (session), PlayerProfile (the name, user://), Bot,
                       Bulkhead, BotDialogue, NameEntry, ObjectiveHUD
  crash_site.gd        the satellite crash intro and the smouldering wreck
  biome_fx.gd          live plants, bioluminescence, pools, ice glints, embers
  dome_fx.gd           dome rim lights, airlock blinkers, comms beacon, animated dome parts
  wind_fx.gd           weather per land: dust gusts, spores, snow
  interior_fx.gd       sun shafts and dust, sparks, leaking gas, fault LEDs, room-name toast
  map_screen.gd        M: full map overview (pauses the game)
  pixel_font.gd        PixelFont: the 3x5 pixel font for every bit of in-game text
  dev_panel.gd         DevPanel: F1 master control panel (debug builds): time, frozen needs, task toggles
  pause_menu.gd        Escape: paused options, master volume slider and Small/Medium/Large GUI
  game_settings.gd     user preferences, saved separately from session progress in settings.cfg
shaders/
  day_night.gdshaderinc  the time-of-day light every world shader includes (day_night(), dn_sky(),
                         dn_lamp_shape(): the suit lamp's beam on the ground)
  map_light            the map: time of day, with its light mask kept lit (and indoors the sun mask)
  graded               any other sunlit thing (given automatically by DayNight)
  depth_occlusion      the astronaut behind scenery: silhouette, or tinted behind glass; lit by
                       the lamp they carry (sprite_lamp)
  prop_depth           props behind scenery: hidden, or tinted behind glass
  flora_depth          live plants hide behind cliffs and thin out round the astronaut
  crash_reveal         uncovers the untouched ground behind the crashing satellite
  turn_relief          one view's picture stood up on its depth map, for the turn's swing
  dust_gusts           dithered wind-gust overlay
tools/                 the pipeline (Python): generates everything in assets/
  astronaut_sprite_gen.py   the astronaut and the multitool: SDF model, rig, every animation
  godot_spriteframes.py     astronaut.json -> astronaut_frames.tres (SpriteFrames)
  mars_map_gen.py           the overworld: terrain, biomes, domes, props, plants, all map data
  props_gen.py              test props for the multitool and the list of dead lamps
  interior_gen.py           the base interior: rooms, machines, data
  nursery_gen.py            the approved nursery interior, walk grid and two airlocks, four views
  check_nursery.py          nursery floor/door-layer/screen/scale QA against native models and sheets
  cultivation_models.py     approved crop, wild seed plant and modest nursery damage models
  cultivation_gen.py        wild sheets, crop depth/glow and native inventory icons
  cultivation_placement.py  reachable forest seed clearings, preserving the original scatter stream
  nursery_cultivation.py    nursery repair variants and independent crop overlays
  check_cultivation.py      forest/approach/atlas/crop/repair-state QA
  window_repair_gen.py      source-matched window inspections, connected glass pieces and working tool
  bot_gen.py                the base's bot: SDF model, eight facings, dormant/wake/idle/talk/move (BOT_DESIGN)
  solar_field_gen.py        solar mirror/feed sheets and four-view indicator metadata (shared SDF renderer)
  sfx_gen.py                every sound: fetches the recordings, synthesises the alien tech
  requirements.txt          what make env installs
  *_viewer.html             browser previews of the sprites and the map
  wire_repair.html          browser companion to the native circuit panel
data/repair_circuits.json   authored five-circuit sequences for power and oxygen machines
data/cultivation.json       repair/crop IDs, growth/yields, wild scales and clearing balance
data/bot_story.json         every placeholder name (the bot, the previous owner), the bot's lines,
                            objectives and lore: change a name here and everything follows
assets/                (lowercase, always)
  cultivation/             four-view wild plants, native colour/depth/glow sheets and inventory icons
  characters/astronaut/     generated sprite sheets, astronaut.json, astronaut_frames.tres, previews
  characters/Astronaut_in_his_space_suit/   OLD reference art, not used by the game; don't build on it
  maps/red_planet/          generated overworld: map, depth, walk, biome, light, fx, props, flora, anim, previews;
                            each view's own set beside view 0's, suffixed _r1, _r2, _r3 (§4.9)
  maps/base_interior/       generated interior: map, depth, walk, light, sun, json, anim (door), preview (four views too)
    machines/               the reactor and the oxygen generator as standalone sprites (+ machines.json, 4x previews)
    props/                  the cargo box (whole, 3 cracks, crushed) and ration packs, four views
    bot/                    the bot's sheet (eight facings x every frame) and bot.json (animations, anchor, face)
    anim/bulkhead_*         the bulkheads' leaves opening (power, oxygen), four views
  maps/nursery_interior/    generated nursery: colour, depth, walk, light, sun, metadata, animated doors and previews
  audio/                    generated sound: *.wav, audio.json, viewer.html, SOURCES.md,
                            CREDITS.md (ship this), preview.json
  audio/sources/            the open-licence recordings, git-ignored (make sources)
```

---

## 4. How the game is built

### 4.1 Pre-rendered world plus data layers
The world is not made of tiles or 3D meshes in the usual sense: nothing is assembled out of
repeated art. Each map is **one big pre-rendered image**, plus data images and JSON written by
the same generator so they always match the picture exactly.

A view of the overworld is 7751x4350, and its picture, depth map and light mask come to about
240 MB. Keeping three views for the camera's turns meant over a gigabyte of **texture** memory,
so each of those three layers is also **cut into 512 px tiles**, and the game keeps only a
window of them around the camera (§4.10). That is GPU memory: it is what the frame rate and an
integrated GPU care about, and it is not the number a task manager shows for the process. The
whole-picture PNGs are still written - they are what the browser viewer and the previews use,
and the tiles are cut from them - but the game never loads them.

| File | Contents |
|---|---|
| `*_map.png` / `base_interior.png` | the picture |
| `*_depth.png` | per map pixel: camera depth (world Y × `depth_scale`) as 16 bits in R (high) and G (low); **B = 255** means dome glass, **B = 96** means a live plant (overworld). Three channels: there is no alpha to read |
| `*_walk.png` | a 1-world-unit grid, pixel (u, v): R, G = 16-bit ground height `(z + height_offset) × height_scale`; **B = 255** walkable, **128** too steep (you can jump over, onto or down it), **0** solid |
| `red_planet_biome.png` | RGB = how much red dust / forest / ice (sums to 255) |
| `*_light.png` | grey: how much of each map pixel is its own light (lamps, lit windows, LEDs, glowing plants, pools and crystals, the light pooling round them, the stars). Kept lit at night |
| `base_interior_sun.png` | grey: how much of each pixel is daylight coming in (shafts, sunlit patches, the windows' glow). Taken away at night |
| `flora/*.png` | plant sheets: colour frames on top; below them the same frames' depth in **R** and, in **G**, 255 where the plant glows on its own |
| `*_map.json` / `base_interior.json` | projection constants (`game`, incl. `light_png` / `sun_png`), spawn, domes, zoom frames, door, fx |
| `red_planet_fx.json` | plants, glows, halos, crash scene, dome cracks, airlock doors |
| `red_planet_props.json` | sprite sheets and placements of the multitool test props, dead lamps |
| `tiles/<layer><_rk>/t_XX_YY.png` | the picture, depth and light of view k in 512 px tiles. A tile of one colour throughout (over half of every map is sky) is not written: the view JSON's `tiles` block gives the grid, which tiles exist and what a missing one is filled with. Imported as **Image**, never as a texture, so they can be stitched on a worker thread |

Scripts must **read positions from this data** (door positions, LED pixels, crack outlines and
so on). Never hard-code a map pixel position in a script. If you need one, the generator
exports it.

**Every map has four views** (§4.9): everything above that is a picture or a pixel position
exists once per view - view 0's files as named above, view k's beside them with a `_rk`
suffix (`red_planet_map_r1.png`, `red_planet_fx_r2.json`, `flora/tree_3_r1.png`...). Each
view's meta JSON lists them all (`views`) and its `game` block says which view it is
(`heading`, `view_center`). What belongs to the world - the walk grid, the biome grid, the
spawn, every `world` position in the data - exists once, in view 0's frame.

`base_interior.json → window_cracks` lists storage's three smashed panes: `id` (its hole shape),
`world` (where to stand under it: the middle of the box pushed to the wall), `hole` (the hole's
middle, with height), `px` (where this view draws it), `seen` (this view leaves its wall
standing), `reach_min_height` (feet height needed to interact) and `patch` (`file`, `height`,
`sun`, `light`, `position`: restored glass, world-height and local lighting masks for the scan).
`window_restorations` lists the seven completed-pane combinations (`panes`, plus `file`, `sun`,
`light`, `position` when this view changes). These exact re-shaded replacements remove the
aperture, rim, bloom, baked beam and floor light together, while retaining other panes' beams.
Each `fx.shafts` entry has a `pane` ID; sealing it removes that shaft and its floating dust.
`windows/inspection/catalog.json` owns each silhouette, six fragment targets/anchors and initial
quarter turns, cost and scan duration. `interior_props.json` adds eighteen gatherable glass
pickups; its `cargo_box` object adds `top` (its height), `half` (half its
footprint), `yaw` (its turn) and `contents` (what spills when it breaks). Glass sheets use
`animation.variant_frames` / `fps` and `shadow_alpha`: three small single-chip variants with
brief reflection sweeps, staggered in the world and retained through camera turns.

`base_interior.json → rooms.storage.dome` names the overworld base room storage sits in
(`command`: the airlocks are cut into it). When all three panes are mended, all three base
domes' holes outside get their glass back: `DomeFX` lays each hole's `red_planet_fx.json → cracks →
patch` (the band's glass as it was, glare and trim shade included) over the map at `patch_pos`.

`base_interior.json → bulkheads` lists the two doors sealing storage from the power and oxygen
rooms (every view and repair variant): `id` (the room), `world` (the doorway's middle), `axis`
(0: its corridor runs along X), `half_width`, `height`, `lamp_px`, and the leaves' sheet (`file`,
`frames` closed -> open, `position`, `frame_size`, `sort_y`). Their frames are baked into the room;
their threshold is walkable. `bot` gives the cradle's `world` (in storage), `facing`, `radius` and
`height`; the bot's own sheet is `bot/bot.json` (`file`; `facings`: Player.DIRS, one row each, drawn
once for every view because the light stays put on screen; `frame_size`, `anchor`; `face`: its
eyes from the foot per facing; `animations`: name -> [first, count, fps, loop]). `game.reserve_png` retains its historical name but is the mains lighting
overlay: emergency lines and floor rings appear only with repaired generator + all solar routes.
Unlocking maintenance access and the O2-only reserve never switch these lights on.

`base_interior.json → repair_machines` contains `id`, `label`, `world`, `stand_world`
(interaction position in world units), and `progress_px` (bar anchor in map pixels).
`interior_gen.py` derives these from the actual machine model centres; its
`--repair-metadata-only` option updates just this data using the existing projection origin.

`game.no_sun_png` is the same base room with incoming sunlight omitted: no baked beams,
floor sunlight or aperture bloom, with physical holes, sand, furniture and internal lamps
retained. Window `patch` and `window_restorations` entries add matching `no_sun` images.
`MapTerrain.no_sun_map` and `WindowCracks` compose those pixels alongside the day image;
`DayNight.set_masks` takes them as its optional third argument. Map, live scan and camera
relief shaders blend to this reference with `dn_night`, so nighttime electrical lighting
cannot turn sunlight into dark rays. Daytime art and glass-repair requirements stay the same.

`nursery_interior/nursery.json` uses the same map layers and projection. Its `doors` array
contains both animated airlocks (stable overworld IDs 1 and 5), with canonical `world`/`dir`
and per-view `file`, `position`, `frame_size`, `sort_y` and `lamp_px`. Overworld FX door
entries carry `interior`, the destination scene path: base doors lead to `interior.tscn`,
nursery doors to `nursery.tscn`. `make nursery` regenerates the room and runs the map
generator's `--doors-only` export, preserving all terrain, vegetation and map tiles.
`game.layout_scale` describes the nursery's authored room/furniture scale; it does not
change the shared `character_scale`. Landing pads are baked into the map only, outside
the animated door sprites, so the door's sort order cannot cover the player's legs.

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
- **The camera turns, the world doesn't** (§4.9). World X/Y are always view 0's: gameplay,
  `world_pos`, props, doors, the walk grid never change with the view. `MapTerrain` turns them
  into the current view: `to_screen()` (pixels), `view_depth()` (what the depth map holds - use
  it, never world Y, for `sprite_depth`), `view_dir()` / `world_dir()` (the stick is screen
  space: turn it into the world with `world_dir()`), `view_point()` / `world_point()`.

### 4.3 Draw order, depth and y-sorting
- **Overworld nodes, in draw order:** `Map` → `CrashSite` → `BiomeFX` → `DomeFX` → `Actors`
  (y-sorted: Player, props, doors) → `Multitool` → `WindFX` → `MapScreen`.
  (`Ambience` sits in the tree between `Multitool` and `WindFX` but draws nothing; see §4.8.)
- **Interior nodes, in draw order:** `Map` → `InteriorFX` → `Actors` → `Multitool`.
- Anything that moves in front of or behind the pre-rendered scenery must use a depth shader
  with `sprite_depth` = `terrain.view_depth(feet)` (its depth in the current view):
  - `depth_occlusion` for characters (they show as a silhouette behind things);
  - `prop_depth` for props (they hide behind things).
  Both tint through glass.
- `snap_2d_transforms_to_pixel` is on, so **y-sort keys and offsets must differ by whole
  pixels**. Half-pixel offsets tie and swap draw order at random.

### 4.4 Day and night: how things are lit
`DayNight` sets five shader globals every frame (`dn_mul`, `dn_add`, `dn_sat`, `dn_night`, `dn_power`) and
`SuitLight` two more (`dn_lamp`, `dn_beam`); all seven are declared in `project.godot`. Everything
in the world must take them:
- **A shader that draws the world** `#include`s `res://shaders/day_night.gdshaderinc` and passes
  its sunlit colour through `day_night(colour, map_px)` (or `dn_sky(colour)` when it has no map
  position). See `depth_occlusion`, `prop_depth`, `flora_depth`.
- **The suit lamp is a shape, not a light node**: `dn_lamp_shape()` lays its beam along the
  ground in the include, so every shader that calls `day_night()` already has it and nothing
  dynamic is added to the scene. Whoever *carries* the lamp is lit by it all over instead -
  `day_night_lit(colour, map_px, amount)`, which is how the astronaut's sprite takes it
  (`sprite_lamp`, set by `Player.set_suit_lamp`). Anything drawn in a view's own map pixels
  outside the ordinary shaders (the camera's swing) needs that view's own lamp position and
  direction: `SuitLight.beam_dir(terrain, player)`.
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

Facilities use `DayNight.facility`: without their power source, rooms and fixtures are dim at
every hour. Base lighting requires generator plus all solar routes. Nursery lighting requires
its repaired console screen, independently of base mains. Nursery sets DayNight's
`facility_power_source` to `GameState.nursery_powered`; the default remains base mains.
`dn_power` gates map/turn fixture emission; `DayNight.darkness` controls the suit lamp independently
of astronomical `night`. O2 repair starts its own 24-hour reserve and never powers the rest of
the base. A compact battery beside the clock appears only after O2 repair while mains are
off, showing reserve percent/empty and leaks. It disappears once generator + solar restore mains.
When empty, O2 production stops and indoor suit oxygen drains until mains are restored.

Exterior mains lighting uses `BasePower` and two compact crops per view. Generated
`power/catalog.json` retains `views` for the main base and adds `nursery_views` for the nursery,
each with `file` and map-pixel `rect`. RGB stores illumination, damaged glass emission and
restored glass emission. Both facilities share the same glow/spill strengths. Shader globals
`bp_nursery_rect` / `bp_nursery_mask` extend the existing base mask, with independent
`bp_nursery_active` driven by the console repair; camera reliefs receive each
view's own pair. No texture spans the empty distance between facilities. `make base-power`
regenerates both, using actual shell geometry and final depth to avoid foreground glare.

Opaque band-dome shells must occlude old interior emission as well as colour. The map generator's
`opaque_dome_pixels` checks actual ray hits against final scene depth; `--dome-light-only`
refreshes only derived light masks/tiles. `tools/check_dome_light.py` checks all four views.

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
| turn_left / turn_right (turn the camera a quarter turn) | G / H | d-pad left / right | view_turn.gd |
| toggle_map (Esc also closes) | M | Back | map_screen.gd |
| suit_light (the lamp on the suit, on/off) | L | B | suit_light.gd |
| wake the bot (the fix job) | hold F, tool out | hold X | multitool.gd, story/bot.gd |
| talk to the awake bot (interact) | F | X | story/bot.gd |
| dialogue_next / dialogue_close | F, Enter, Space / Esc | A, X / B | story/bot_dialogue.gd |
| name entry | type A-Z 0-9 space -, Backspace, Enter | d-pad, A picks, B deletes, Start | story/name_entry.gd |
| dev_panel (debug builds only) | F1 | Guide | dev_panel.gd |
| pause_options | Escape | Share / Misc 1 | pause_menu.gd |

F / gamepad X is shared: while a door's prompt is showing, the door sets
`multitool.suppressed = true`, so it opens the door instead of using the tool.
L / gamepad B switches the suit's lamp. B is also every modal's cancel, so `SuitLight` ignores
the press while the game is paused, in a cutscene, mid-turn or with the window panel open: a
modal takes the press and the lamp never flicks on behind it.
Inventory pauses the world and independently sets `multitool.inventory_suppressed`;
after closing, F / X must be released before interactions resume. The inventory consumes
modal input before map/camera handlers. Do not add another meaning to these buttons
without the same suppression mechanism.
Machine repairs use `multitool.repair_suppressed` independently, pause the world and consume
modal input. F/X must be released after closing. On the board, arrows/WASD/d-pad select
movable modules; Enter/Space/F/A turns clockwise, Q/left shoulder turns back, Esc/B closes.
Mouse left/right click turns clockwise/back. Bolted modules and plates are skipped.
Window repairs use independent `window_suppressed` and `window_panel_open` ownership. They
disable movement input while keeping physics, the clock and survival running; leaving reach
closes the panel. F/X must be released before world interactions resume. Drag/click places glass;
R/right-click/left shoulder rotates clockwise, Tab/right shoulder cycles pieces, Q cycles back,
WASD/arrows/left stick/d-pad moves the selected fragment, Enter/Space/F/A/X places, Esc/B closes.
The awake bot's `[F] TALK` prompt and its conversation use independent `bot_suppressed`
ownership (released only once F/X is let go). The dialogue and the name entry pause the world,
like the backpack, and take every key, button and click while open, so nothing underneath (the
map screen, camera turns, the hotbar) acts on them; the name entry cannot be cancelled.
Solar equipment uses independent `solar_suppressed` proximity/release ownership. F/X
opens/closes a nearby sun feed or turns a mirror clockwise 22.5 degrees. Q has no solar
action; left shoulder retains hotbar cycling. No modal/pause;
camera turns reproject equipment and rays without changing the optical puzzle.
Escape closes an existing inventory, map, repair, F1 panel or dialogue before it opens options.
Options own pause and consume all input; independent `options_suppressed` keeps multitool F/X
blocked until released after resume. Gamepad B resumes without switching the suit lamp.
Cultivation uses independent `cultivation_suppressed` proximity/release ownership.
F/X taps collect ripe wild seeds, plant a dead bed or harvest. Repair nursery UNIT before its systems. Nursery repairs require
the equipped multitool (T/Y) and its existing held F/X fix job: use pose and cyan scanner,
2.4 seconds per system. Unfinished scans resume after releases, unequipping, turns or airlocks.
Airlocks take priority; modals, cutscenes, jumps and turns block cultivation. Completing a
held scan cannot also plant or start another job before release. No minigames or new buttons.
See docs/cultivation.md.

### 4.6 Scenes and state
- Cross-scene state lives **only** in the `GameState` autoload:
  - `settings`: `GameSettings`, master volume and GUI size. `user://settings.cfg` keeps these
    preferences between launches; it is separate from gameplay saving. `changed` updates UI
    immediately, including while paused. Large preserves the original size; Small/Medium use
    smaller pixel-snapped display scales. Invalid/missing preferences use compact Small and full volume.
  - `intro_done`: the crash plays once;
  - `arrive` and `door_id`: where to appear next;
  - `tool_out`: the multitool stays out across the airlock;
  - `suit_light`: the lamp on the suit, off when the game begins and as you left it after that;
  - `clock`: game hours since the start (`DayNight` turns it into the day, hour and part of
    the day).
  - `heading`: which way the camera faces (quarter turns, 0..3), the same indoors and out.
  - `inventory`, `selected_slot`: 24 slot dictionaries (`kind`, `count`), first six are
    quick access. Empty slots are `{}`. Item kinds are `multitool`, `ore_chunk`, `scrap`, `glass`, `ration`, `water`;
    resources/rations/water stack to 99. Use `store_item`, `swap_slots`, `select_slot` and listen to
    `inventory_changed`. A full bag leaves gathered props in the world.
    Cultivation adds `emberpod_seed`, `dewpod_seed`, `emberpod`, `dewpod`, also stacking to 99.
    `can_store_items` / `store_items` preflight complete handfuls and harvests atomically.
  - `removed_props`, `spawned_props`: session ledger for gathered props/mined rocks and
    their loose chunks. IDs derive from props JSON path/index, with `/chunk/N` for mined
    chunks and `/spill/N` for the cargo box's rations; `spawned_props` entries keep their `kind`
    and `radius`. Generated JSON is unchanged. Saving to disk is not implemented.
  - `window_repair`: `WindowRepair`: storage's mended panes, the cracks the cargo box has
    taken (one per pane), where it was last set down, and whether it broke. Its `puzzles` keep
    independent `GlassPuzzle` placements/rotations and unfinished scan progress through closes,
    views and airlocks. Six glass are consumed atomically only when that pane's scan completes.
    `dome_mended` is `"base"` when every pane is mended, restoring the three command/storage holes
    (read by `DomeFX`); `""` retains damage. Single-room IDs remain developer previews. Reset with the
    world ledger (`reset_inventory`), which holds its spilled rations.
  - `machine_repairs`: `MachineRepair` instances obtained through `repair_for(id)`.
    Each stores its crack placements/seams, circuit puzzle/countdown/index and completed tasks.
    Closing or changing scenes preserves both puzzles. `item_count` and `consume_item` perform
    the atomic three-scrap transaction only on crack success; ore is never consumed here.
  - `survival`: `SurvivalState` with health/oxygen/hunger/thirst, changed/died signals and
    clamped mutation APIs. `data/survival.json` owns balance, starter supplies and consumable
    restoration. `consume_slot` uses the existing inventory. `rescue` restores vitals and
    supplies at overworld spawn while preserving session progress. See docs/survival.md.
    `frozen` (kind -> true) holds needs still - no drain, recovery or damage - set from the
    master control panel; it is kept through rescue.
  - `facility_air`: `FacilityAir`: `reserve_started_at` on the game clock, full O2 repair,
    three storage seals, and generator/solar supply shared by base and nursery. The scene's
    `Player.air_source` queries it indoors; outdoors is always unbreathable. See docs/survival.md.
  - `story`: `StoryState`: the opening chapter - `bot_awake`, `named`, `player_name`,
    `access_opened` (mechanical maintenance bulkheads open, without lighting the base), `objectives_given`, the lore lines `heard`, and
    `bot_world` (main patrol position), `nursery_bot_world`, `nursery_awake`,
    `nursery_introduced`, `body_repair_progress`, `cleanup_progress`, `maintenance_waits` and `guidance_seen`. Every
    name and line comes from `data/bot_story.json` (tokens `{BOT}`, `{OWNER}`, `{NAME}`).
    Seven objectives query full machine repair, three seals, feed states and solar routes. Kept through rescue. The
    player's name is also remembered between launches in `user://profile.cfg` (`PlayerProfile`:
    a name preference, not a save file). HUD placement is fixed. `skip_intro()` for tests.
  - `solar_field`: `SolarFieldState`: ten world mirror orientations, three closed/open
    feeds and cached optical routes. All three complete 3/3/4 Amber/Jade/Coral routes supply the base reactor;
    `base_powered()` also requires the power machine fully repaired (cracks and
    wiring). Full power lights the main base indoors and outdoors through day and night.
    The O2-only reserve is independent and does not light the base. State survives turns, airlocks
    and rescue. See docs/solar-field.md for optics, generated art, ownership and test hooks.
  - `cultivation`: `CultivationState`: three nursery repair bits, `repair_progress` (scan fractions), planted-bed ready times
    and wild seed cooldowns, plus successful first crop-kind `harvested` flags. Uses the existing clock and survives views, airlocks and rescue;
    explicit inventory/world reset resets it. `data/cultivation.json` owns balance/IDs.
    Crops start dead, need collected seeds and regrow after harvesting. Emberpods restore
    hunger; Dewpods restore thirst via the existing C action. See docs/cultivation.md.
- Inside, the corridors to the power and oxygen rooms are sealed by bulkheads until the bot
  releases maintenance access: they stand in `MapTerrain.blockers` while sealed.
- Going in: an overworld door emits `entered`, then `overworld.gd` sets `GameState` and
  changes to `interior.tscn`, which plays `door.arrive()`. Going out works the same way in
  reverse. Both base airlocks lead into the same storage room. You come back out of the one
  you went in by.
- Both nursery airlocks lead into `nursery.tscn`. Entering uses the matching inside doorway;
  leaving through either doorway returns to that doorway outside, including when it differs
  from the entry. Shared `AirlockDoor` proximity ownership keeps the multitool suppressed
  while any door offers interaction. The clock, inventory, tool and suit lamp carry through.

`NurseryCleanup` loads six reachable soil/leaf/tray-chip piles per facility from
`nursery_interior/cleanup/cleanup.json` or `base_interior/cleanup/cleanup.json`, generated by
`tools/nursery_cleanup_gen.py` with the
existing cultivation colour/local-depth exporter and native ramps. Four diminishing frames
per view disappear only after UNIT vacuums in reach. `StoryState.cleanup_progress` stores each
pile's fraction. Native `clean_start`, `clean`, `clean_end` frames deploy/sweep/stow the intake;
`bot.json.nozzle_tips` anchors graded pickup particles to the actual attachment. Ordinary
patrols continue between jobs and after all piles are gone. `maintenance.stroll_seconds`
(16–30 seconds) and `idle_seconds` (1.2–3.5) in bot_story.json control random roaming breaks;
`StoryState.maintenance_waits` preserves each body's remaining delay through airlocks. Jobs
choose actual unfinished piles only; empty floor never runs a vacuum animation. The floor
graph validates movement segments around curved walls and tries alternate nearby approaches.
Leaving, talking, pausing or turning cannot clean remotely.
The nursery checklist shows player body/system repairs, planting 0/3 and 0/2, and first harvests.
UNIT's autonomous cleanup is not a player task and does not block checklist completion.
`CultivationState.harvested` records successful crop-kind harvests only after inventory accepts them.

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

### 4.9 Four views: turning the camera
The camera turns round the world in quarter turns, Don't Starve style (G / H). A pre-rendered
map can't turn, so every map is rendered **four times**, once per view, and a turn switches
the scene from one view to the next.
- **The generators** build the world once, in view 0's frame, then render each view with the
  world turned about the middle of its grid (`VIEW_C`): view = R_k (world − c) + c, R_k a quarter
  turn clockwise k times, (x, y) → (y, −x) per turn. Terrain grids turn with the world
  (`rot_grid`); every model is built in view 0's frame inside `canonical()` and turned whole
  with `turned()` (an SDF wrapper), so each view shows the other sides of things. **The sun
  stays put on screen** (upper left, §7.2): each view is lit alike, its shadows cast afresh.
  Positions written into the data are the view's pixels; `world` positions stay view 0's.
  Every view is as deep as the whole world (2 × `VIEW_C`'s Y ≈ 3253 units), so the depth
  map's `DEPTH_SCALE` (20) must keep that under 65535; `view_turn_test` checks it.
- **The game** keeps one `MapTerrain`, which loads a view with `load_view(k)`. On a turn the
  scene's `_apply_view(k, facing)` calls every system's **`load_view(meta)`** (or `set_view`):
  the map texture, the player (`refresh_view`: depth map, facing kept in the world), the
  camera (`set_view_limits`), DayNight's masks, BiomeFX, DomeFX, CrashSite, WorldAmbience,
  MapScreen, the multitool's props and lamps, doors (rebuilt), InteriorFX, the repair bars.
  **Anything you add that draws at map pixels must do the same**: read its positions from the
  current view's data (`terrain.view_json`) and reload them in its `load_view`. Sounds,
  carried crates, the inventory and the clock carry on through a turn.
- **The turn itself** (`ViewTurn` + `TurnOverlay`): ~0.4 s, eased, round the astronaut, who
  stands still (`player.turning`). For that moment the world is stood up in 3D - each view's
  picture lifted onto its depth map (`turn_relief`), plants, props, the domes' moving parts and
  the astronaut as billboards (they come from each system's `visible_plants()` / `boards()`) -
  and the game's own orthographic camera swings round. The view left dissolves into the view
  arrived at (a pixel dither), then the overlay fades into the live view. It sits above the
  world (layer 3) and below every UI layer. Turns wait for a calm moment: not in a cutscene, a
  modal, mid-jump, or while the tool is being drawn or at work. The next views' sprite sheets
  load in the background ahead of time and their windows are kept stitched (§4.10), so a turn
  never waits for the disk. A press whose view is not ready yet is kept and played as soon as
  it is, rather than freezing the frame.


### 4.10 The map window: only what you can see is in memory

`MapStream` (`scripts/map_stream.gd`) stitches a window of each resident view out of the tiles
§4.1 describes, and that window is what the game actually draws and samples. **Texture** memory
then follows the zoom instead of the size of the world: 1097 MB down to 200 MB at the default
zoom on an Intel UHD 620 (`--no-stream` loads the whole pictures instead, so the two can be
compared in one build). This is GPU memory. It is not what a task manager shows for the
process, which moves by about 11 MB - see §12.

- **What it covers**: what the camera shows, grown by the margin the turn's swing lays out
  (`TurnOverlay.MARGIN`) and then by `PAD`, so walking does not restitch every step. It is
  sized from the zoom level being tweened *to*, so a zoom stitches once.
- **Where it is**: `MapTerrain.window` (map pixels), with `map_texture`, `depth_map` and
  `light_mask` holding that rect and nothing else. `map_size` still means the whole map - the
  camera's limits and `to_screen()` depend on it. **Do not let the two merge.**
- **Three views at a time**, as before, so a turn never waits: the one you are looking at and
  the two you could turn to. Only one is restitched per frame, the current one first, and the
  old windows stay on screen until the new one is ready - a rebuild is never visible. A turn
  waits for its view's window (`ViewTurn.request`) rather than stitching on the spot.
- **Anything that samples the depth map** must sample the window: `(map_pos - map_win.xy)`,
  with a bounds test, and **a pixel outside the window counts as sky** so a sprite there draws
  whole instead of being wrongly hidden. `MapStream.bind(material, terrain)` points a material
  at the current window; re-point on the scene's `_window_moved` as well as on a view switch.
- **The map's light mask must follow the same publication.** Call `DayNight.set_masks()` from
  `_window_moved`: zooming or a map-edge resize can allocate a new light texture. Keeping the
  previous texture stretches old light patches over new ground, most visibly at night.
- **Small maps are not streamed.** The interior has no `tiles` block, so `MapTerrain.streaming`
  is false, its layers are loaded whole, and its window is the whole map - the same shaders and
  the same code path, with the window simply never moving.
- `--stream-debug` prints every window as it is stitched; `tests/map_stream_test.tscn` checks
  that the window always covers what the camera shows and that its pixels are the generator's.

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
  - Boxes you can stand on (`MapTerrain.platforms`, registered by a `WorldProp` with a footprint)
    stop you at their sides; a held jump lands you on top; walking off the edge drops you.
    On or over one, the astronaut draws above it. `collapse()` knocks you down (a box giving way):
    a hard landing, then `collapse_time` (0.9 s) crouched with no control.
- **Jump**: a low-gravity moon jump.
  - Holding jump goes higher (about 30 units: enough for the 14.4-unit cargo box); a tap does not.
  - There's a floaty hang near the top, plus crouch and land squash.
- **Camera** (`game_camera.gd`):
  - Overworld: 4 zoom levels; all follow the astronaut. The furthest shows a main-base-sized area.
    In-between levels land on whole-pixel scales at 1080p.
  - Interior: `zoom_locked = true` (no zooming).
  - Cutscenes use `focus_override`, `snap_to` and `release_focus`.
  - **Turning** (`view_turn.gd`): G / H (d-pad left / right) turn the view a quarter turn left /
    right, indoors and out, in a 0.42 s eased swing round the astronaut. The stick stays screen
    relative (up is always up the screen); the astronaut keeps facing the same way in the
    world, so their sprite turns as the camera goes round. A press during a swing is kept.
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
    | gather | teal `#4fe0c8` | ore chunk, scrap, ration pack | hold F for 0.55 s; a spiral pulls it into the backpack |
    | lift | violet `#b583ff` | crate, cargo box | tap F to float it so it follows you; tap again to set it down (never the box under your feet) |
    | fix | cyan `#7fd8ff` | the sleeping bot; dead lamps (none placed now) | hold F for 2.4 s; the lamp flickers back on, the bot boots up |

  - Inventory shows resource stack counts; survival meters above it are approved (§12).
- **Inventory** (`inventory_ui.gd`): six-slot bottom hotbar; E / Start toggles the paused
  24-slot backpack. Click two slots to swap, or arrows/d-pad and Enter/A to pick/place.
  Esc/B cancels a pending swap first, then closes. 1-6/wheel/left shoulder select hotbar;
  selecting the multitool equips it, selecting resources/empty slots holsters it.
  T/Y remains available. Rations/water use C/right-stick click; scrap is consumed only on
  machine crack success; ore has no consume action. Crates remain
  world objects handled by lift. Opening/closing without changing selection preserves
  the existing tool state. Inventory is blocked during intro/door cutscenes or map pause.
- **Machine repairs** (`scripts/repair/`): F/X near power/O2 requires three scraps and opens
  untimed, full-screen **Crack Repair** on the owner's exact supplied Power/O2 panel images.
  Original PNGs stay unchanged under `machines/reference/`; the UI displays their wall crop.
  This is an explicit owner-approved exception to the generated-art rule (§12).
  The teal console and pale silver worn scraps match the approved browser draft; scraps are
  enlarged 12%. Pick or drag three
  irregular scraps over the holes, covering each aperture/fracture with a 2px margin, then
  weld each perimeter to 95% with a 3px torch. Steady strokes work; fast strokes leave gaps,
  holding still for about three seconds overheats and melts a small nearby weld. Lift to cool.
  The draft's rounded raised filler and crescent ridges follow the hand stroke, cooling from
  red hot metal to grey steel; its small red/gold torch is reused. No timer or visible percentages
  in this task; each sealed scrap glows teal once and fades fully over one second.
  Q/left shoulder selects scrap, arrows/d-pad move the virtual cursor, F/Enter/A picks/places
  or holds the torch, Esc/B closes. The tray also supports click-hover-place and drag/drop.
  All three seals spend three scraps once and earn 50%; CIRCUIT continues into wiring.
  Five circuit layouts per machine retain their 30-active-second replacement and bolted wires.
  A matching route earns the other 50%. Both tasks persist through closes/airlocks. After both,
  generated restored machine geometry replaces broken room art, debris, depth, walk and light
  data in all four views, with fault sparks/leaks removed. Power completion also closes its
  service cabinet, stows its exposed board/leads, and reconnects the torn battery feed.
  Six gatherable scraps in the base
  use the existing prop sheets and normal multitool gathering. Reduced motion disables sparks.
- **Storage's smashed panes and the cargo box** (`scripts/repair/window_cracks.gd`):
  - Three panes are smashed in storage's window band: two in the wall you face coming in, the
    third in the wall behind you, cut away in that view (turn to find it: views 1 and 2 show it).
  - The cargo box is a loose prop: lift it with the tool, set it down under a pane, jump on.
    It takes your weight with a crack, once per pane, and not again until that pane is mended.
  - When the last pane is mended with you standing on it, it groans (0.45 s), gives way and
    crushes flat: you go down with it (`collapse`), and its 4 ration packs (MREs) spill clear
    of the wreck, to be gathered with the tool. The wreck stays; nothing to lift or stand on.
  - F/X within 20 units of an unrepaired visible pane opens **Window Repair** with the tool
    equipped and six collected glass. The set-down box supports the player; levitated boxes
    cannot be ridden. A floor jump can open it briefly but gravity closes it when out of reach.
  - Six connected fragments need placement and quarter-turn rotation. Inside-facing crescent,
    star (`burst`) and gash silhouettes stay constant; SKYWIN colours, honeycomb, dithering and
    reflections reuse the actual window shader. Fractures remain clipped to the pane.
  - After all pieces fit, the actual working gauntlet scans top to bottom for 2.4 seconds,
    progressively restoring continuous glass in the panel and world. Closing pauses the scan;
    reopening resumes it. Completion spends six glass once and calls `WindowCracks.fix(id)`.
    The final panel closes before the box's groan snapshots controls. Landing or moving the
    box never repairs a pane or triggers collapse; all three completed repairs are required.
  - Completed panes replace their entire damaged appearance and lighting; their hole beams,
    floor light and illuminated dust stop. Camera turns, machine repairs and airlocks retain this.
    Partial scans use generated world-height masks and pristine local day/night shading.
  - Glass pickups are small individual teal shards with sharp pale edges and brief animated
    white reflections, matching the owner's floor-glass reference. The three storage barrels
    and their collision are removed to leave room for carrying the cargo box.
  - State survives the airlock (`GameState.window_repair`). No `[F] EXIT` prompt while up on a box.
  - Storage's three holes exist outside too: front burst/crescent and rear gash on the
    command dome. Mending the three interior panes restores all of them in every view.
    Habitat and garage glass is intact; they have no exterior holes.
- **Solar field** (`scripts/solar/`, `data/solar_field.json`):
  - Three elevated, closed sun feeds and 3/3/4 Amber/Jade/Coral reflectors surround one conical receiver
    (three yellow, three blue/teal, four red). Relays descend from hilltops into the clearing.
    F/X opens a feed or turns a nearby mirror clockwise 22.5 degrees. No Q reverse action.
    Movement, survival and the clock continue. Every assigned reflector is required.
    Local solar prompts and bars avoid the fixed survival HUD using its canvas-aware
    `plate_position`; prompts sit beside the equipment's feet to stay readable at close zoom.
  - The receiver's local bar has three channel segments. Its cable goes into the base's
    power conduit; all three complete paths plus the fully repaired reactor AND oxygen
    generator restore full base power. Closing a feed removes full power; night does not.
    Routes persist through views and airlocks. Time of day fades beams without losing progress.
  - The receiver sits farther right/down in the original array clearing. Amber uses capped western
    peaks, Jade the right-hand hill and Coral the upper cliff. Flat equipment pads and graded
    approaches are shaped after the original flora placement stream; plants retain X/Y and settle
    onto the reshaped ground. The forest is preserved.
  - Mirrors have silver sweeps/pivots; feeds deploy crystals and gather sunlight. Completing
    all routes sends a charge wave through receiver cells, lights its crown and pulses outward.
  - Canonical `SolarOptics` and session `SolarFieldState` are separate from `SolarField`
    input, `SolarFieldFX` animation and `SolarPowerInput` wall lenses. No prototype navigation box.
- **The bot and the opening chapter** (`scripts/story/`, `data/bot_story.json`):
  - The airlock opens into storage, where the bot sleeps in its charging cradle (south-west
    floor). The corridors to the power and oxygen rooms are sealed by bulkheads (their lamps
    require mains; walk up and SEALED shows).
  - It is a fix job: hold F with the tool out (2.4 s). It boots (1 s: eyes flicker on, it rises
    off the cradle), then talks. Lines type out with a chirp; F / Enter / A move on.
  - It takes you for the previous owner (`names.previous_owner`). You tell it your name in the
    name entry (prefilled with the one you gave last time); from then on it uses it.
  - It releases maintenance access with a relay clunk and both bulkheads open (1.8 s beat,
    controls held). Main lighting remains off. Then the objectives:
    O2, glass, generator, then solar instructions. Seven checklist tasks cover O2, the three-pane
    seal, generator, open sun feeds, and Amber/Jade/Coral alignment. Actions can be completed
    out of order; UNIT explains the earliest unfinished stage. An exclamation shows new advice
    until heard. Glass advice resolves the current turn-key bindings.
  - Awake UNIT patrols cleaning sites instead of following the player. Native clean poses
    deploy/sweep/stow a vacuum intake while actual nursery litter shrinks. Walk-grid routes avoid walls and loose props.
    It never blocks the player or teleports to follow an airlock. Its position is session state.
  - The nursery has a second dormant UNIT body using the same sheet and shared mind. Repair
    it first with the equipped tool's 2.4-second held scanner; partial scans survive airlocks.
    Its mandatory introduction explains Emberpods/racks/food, Dewpods/silos/water, Moonwell
    seeds only at NIGHT (20:00–05:00), and full-day crop growth. It then cleans independently.
  - F/X talks when facing UNIT within reach; doors, repair targets and modals retain ownership.
    Dialogue/name entry pause survival and time. Release F/X before the next world action.
  - State survives turns, airlocks and rescue (`GameState.story`).
- **Outdoors** there are no loose test props (ore rocks, scrap, crates) and no trail lamps any
  more (owner, §12); the gather/mine/lift/fix jobs remain for the base and what comes next.
- **Master control panel** (`dev_panel.gd`, editor and debug builds only): F1 / Guide opens it
  in either scene, outside cutscenes and pauses. Set the time in half-hour steps or to a part
  of the day (dawn, morning, noon, evening, night; same day), and freeze food, water and
  oxygen where they are (`GameState.survival.frozen`). The clock runs on while it is open; the
  astronaut stands still. Arrows / d-pad, Enter / A, Esc / B / F1 closes; mouse works too.
  Eight task toggles complete oxygen repair, power repair (both cracks and wiring), all three
  storage glass cracks, all solar reflection routes, nursery UNIT, nursery screen, grow light
  or food rack remotely, without materials or puzzles. The taller plate keeps every row visible.
  DONE reflects real session progress, including manual play; toggle again to reset that task
  for replay. Reset solar restores initial mirror angles and closed feeds. Glass reset clears
  pane puzzles and restores damaged interior/exterior glass and lighting, preserving cargo-box
  history. Machine reset clears that machine's puzzles. These use the existing session objects
  and notifications, so room art, safe air and full-power lighting update immediately and state
  carries through turns and airlocks; no main-story skip or extra supplies are granted.
  `CultivationState.debug_complete(id, completed)` changes only that repair bit/progress.
  `StoryState.debug_complete_nursery(completed)` completes or resets the nursery body/intro;
  its live Bot listens to the existing story signal, updating scanner/patrol state immediately.
  UNIT reset preserves all crop/system/cleanup progress. Screen reset also removes nursery
  lighting/glow; completing it restores them. The main-base story remains independent.
- **Pause/options** (`pause_menu.gd`): Escape pauses gameplay, the clock and survival in all
  three scenes. An 85%-opaque dark-grey overlay leaves 15% of the current game visible.
  VOLUME sits above a horizontal master slider (0–100%, zero mutes); GUI SCALE sits above
  SMALL / MEDIUM / LARGE, default Small. Sizes apply to the hotbar, E backpack, day/night clock,
  stat panel, tasks and reserve counter. The backpack stays centred, the hotbar stays at the
  bottom and stats retain their fixed top-left location. Scaled hitboxes follow the art.
  The options themselves keep a steady size. Mouse,
  arrows/d-pad and Enter/A operate the controls; Escape/B resumes and saves preferences.
  Existing modal/cutscene ownership is retained. See docs/options.md.
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
    **dark night** (`KEYS` in `day_night.gd`). What glows on its own stays lit after dark - the
    pools, the spires, the two powered domes, the stars - and nothing else does: the ground is
    down to a deep blue-violet you can just read shapes in, and you need the suit lamp to get
    anywhere. Nothing lights the astronaut for them any more.
  - The time panel sits top left, and a "DAY N" title comes up at dawn. It is hidden during the
    crash intro and comes in with "DAY 1" when it ends.
  - Moonwell seed plants open only during NIGHT (20:00–05:00). There is no sleep or night danger.
- **The suit lamp** (`suit_light.gd`):
  - L / gamepad B switches it on and off. It **starts off**, every time, and stays as you left
    it through the airlock (`GameState.suit_light`). Nothing else turns it on.
  - A beam thrown along the ground the way the astronaut faces (`reach` 120 map px, `spread`
    38 degrees either side), with a small pool spilling round their feet (`spill`), in the same
    three dithered steps as the rest of the light. It lights the astronaut themselves all over,
    since they carry it.
  - The beam's origin follows the raised, pixel-snapped sprite during jumps, falls and while
    standing on a cargo box; it never stays at the ground sorting position. Camera reliefs
    use the same suit anchor. Standing on the ground retains the original beam placement.
  - Its strength follows `DayNight.darkness`: astronomical night outdoors, power status
    indoors. It lights an unpowered facility at noon too; each facility's repaired power source
    lights its interior at all hours.
  - It is two shader globals, not a light node (§4.4): it costs nothing per lit thing, and it
    follows the camera's quarter turns because its direction is worked out in the current view.
- **Sound** (§4.8, §7.6): the three lands each have their own ambience, crossfaded by the land
  you are standing in; the pools, spires, burning wreck and powered domes can be heard from
  near them; everything you do makes a noise. No music.

---

## 6. The art pipeline

### 6.1 How art is made
All world art is **rendered by code**. The owner's exact Crack Repair panel PNGs are the
explicit approved UI exception (§12): preserve those source files unchanged; derive only
their crop and hole metadata in the generator. Signed-distance-field (SDF) models are ray-marched straight
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
| `python tools/mars_map_gen.py` | `assets/maps/red_planet/*` | you change anything on the overworld | ~35 min for the four views (~9 each, measured on an 8-core laptop), several GB of RAM. `--tiles-only` re-cuts the tiles from the pictures already on disk in a couple of minutes |
| `python tools/props_gen.py` | `assets/maps/red_planet/props/*`, `red_planet_props.json` | after **every** map regeneration, or when you change props | fast |
| `python tools/solar_field_gen.py` | `assets/maps/red_planet/solar/*`, `solar_field.json` | after every map regeneration or equipment change; `make map` includes it | seconds |
| `python tools/cultivation_gen.py` | `assets/cultivation/*` | wild seed models, opening frames or inventory icons change; `make map` includes it | seconds |
| `python tools/nursery_gen.py` | `assets/maps/nursery_interior/*` | nursery geometry, repairs or growing beds change; `make nursery` also refreshes exterior door routes | a few minutes |
| `python tools/interior_gen.py` | `assets/maps/base_interior/*` | you change the interior | about 2.5 minutes (four views × four machine variants, ~40 s each) |
| `python tools/bot_gen.py` | `assets/maps/base_interior/bot/*` | you change the bot; `make interior` runs it | seconds |
| `python tools/sfx_gen.py` | `assets/audio/*` | you change any sound | fast (needs `make sources` once) |

**The generators share code.** `mars_map_gen.py` imports `astronaut_sprite_gen.py` (SDF
primitives, ray-marcher, base palette), and `props_gen.py` and `interior_gen.py` import both.
If you change shared code (a ramp, the renderer, `hole_shape`, the outline) you must
**re-run every generator that uses it** and check all of their outputs.

**Design versions** are switched with environment variables. They are kept so earlier approved
designs can be compared or restored:
- `BASE_DESIGN` = `v1` | `hex` | `v2` | `v3` (default **v3**) — the main base.
- `NURSERY_DESIGN` = `v1` | `v2` (default **v2**) — the earlier clear ribbed nursery or the
  approved tinted honeycomb dome: larger panes, a taller white/coral base and a tiny round cap.
  Both entrances use the existing framed white/coral airlock model and enter the playable
  nursery. The v1 wind gauge and rim LEDs stay with the earlier design.
  V2 clears the three tall trees covering the door faces, retaining the forest's random
  placement sequence and all other plants, including the low growth at the entrances.
- `NURSERY_SIZE` = `compact` (default) | `original` — v2's owner-approved 150-world-unit
  exterior radius or its earlier 200-unit radius. Door dimensions stay at the shared scale.
  The original terrain clearing, forest exclusion and random stream are retained.
- `NURSERY_INTERIOR_SCALE` = `0.8` (default) — room, furniture, collision and specimen glass
  scale together; `1` restores the earlier room size. Astronaut/airlock scale stays shared.
- `NURSERY_CONDITION` = `damaged` (default) | `restored` — eight cultivation repair
  combinations with dead/reseeded overlays, or the earlier intact room export for comparison.
  The runtime chooses repair combinations from `GameState.cultivation`.
- `TOOL_DESIGN` = `v1` | `v2` (default **v2**) — the multitool.
- `SOLAR_DESIGN` = `field` | `array` (default **field**) — the approved interactive field or the earlier baked panels.
- `SOLAR_FIELD_LAYOUT` = `v1` | `v2` (default **v2**) — earlier 4/5/4 ground field or the
  approved 3/3/4 terraced field. Use the same value when generating and running the game.
- `BOT_DESIGN` = `pod` | `lantern` | `orb` (default **pod**) — the bot; lantern and orb are the
  other two looks from the approved contact sheet (`docs/bot-mockups.png`), kept for rework.
- `TRAIL_LAMPS` = `0` | `1` (default **0**) — the lamps along the trails (and their light). Off,
  their spots still keep plants and the spawn clear, so the forest and spawn are unchanged.
- `TEST_PROPS` = `0` | `1` (default **0**) — `props_gen.py`'s ore/scrap/crate test set by the
  spawn. Its sprite sheets are always written: the interior reuses them.
- `MAP_OUT=<folder>` writes the map somewhere else, so you can preview a design without
  replacing the game's map.
- `MAP_VIEWS=0` (or `013`...) renders only those views (map and interior) - quick to check a
  change, but the game needs all four before it ships. The walk grid comes from view 0.

Running with a non-default design and `MAP_OUT` unset **replaces the game's assets**.

After regenerating, **re-import** (`godot --headless --path . --import`, or focus the editor)
before you run the game.
Map, prop and solar image/data exports replace completed files atomically, so Windows
editors and diff viewers can retain the previous version without blocking a truncating write.

### 6.3 Data contracts
The generators write the JSON keys that the scripts read. If you rename, remove or reshape a
key, update **every** reader in the same change (search `scripts/` for the key). Keys that are
waiting for a future feature are documented in §11. Don't remove them.

`audio.json` is the same kind of contract: `scripts/audio.gd` is the only reader, and every
field in it exists because something in the game asks for it (§4.8).

The views add: `views`, `view`, `game.heading`, `game.view_center` in every meta JSON;
`sprites_views` and `lamps[].head_px_views` in `red_planet_props.json`; `anchor` on every plant
sheet; `anchor` and `world` on every animated dome sprite (the turn stands them up).

`data/solar_field.json` owns canonical `bounds`, `collector`, `cable`, `beam_height`,
`mirror_span`, `reach`, `engine_room` and three `routes` (ID/label/color/ramp, source/direction/mirrors).
Optional `access_paths` contain canonical `points` and `half_width` for narrow approaches.
Points may include Z for graded ramps; two-coordinate points remain level at Z=0.
`terrain.peak_caps` contains `bounds`, `height`, `blend`; `terrain.plateaus` contains elliptical
`world`, `half`, `height`, `blend` tops. These shape only the authored solar sites.
Generated `solar_field.json` adds `sheets` (file/size/frames/anchor, mirror `shine_frames`,
feed `deploy_frames`/`yaw_offset`, the first source row's canonical angle) and four `views`
with receiver `indicator_px` and `receiver_mask`
(file/position/size; RGBA = normalized height/cell interior/local view depth/surface).
Mirror sheets add `depth` (file/frames/scale/offset/skin_depth_span), eight frames sharing the sprite's
size/anchor and silhouette. RG16 encodes local view depth as `(depth + 32) * 1024`, B
encodes the surface-to-optical-plane gap normalized by skin_depth_span (32), and A includes
the one-pixel outline. All parts, including faces, retain actual rendered SDF depth in RG.
Only camera-facing incident/reflected segment pairs may bridge the skin gap (UV.y = 1);
back-side contacts and other projected crossings keep solid surface depth. SolarReflectorLight clips identical world beam geometry
over each y-sorted prop so front light shows and behind light stays hidden. Beam UV.x
carries full float view depth; byte-packed vertex colors cannot preserve its precision.
`feed_visual` owns `crystal_offset`, `tip_closed`, `tip_open` and `emerge` for the sunlight
funnel's endpoint as a beacon opens. Closed beacons conceal the crystal under metal lids.
Its `stands` map contains reachable canonical approach points for captures and placement
checks, clear of the receiver's footprint; normal play can approach from any side.
The map generator owns small level equipment pads and solid footprints, preserving the
original landscape/plant random stream. `check_solar_field.py` verifies reachability,
original forest placement fingerprints, equipment clearance and view anchors.
Elevated routes add `source_elevation` and parallel `mirror_elevations` (default zero).
Legacy v1 elevated feeds retain their natural terrain; v2 uses authored level pads and ramps.
`mirror_half_height` defines finite vertical mirror extent. `SolarOptics` intersects
three-dimensional rays with mirror rectangles and the capped frustum. Every mirror's fixed
pitch and yaw offset derive from its actual incoming/outgoing elevations and authored route;
`special_mirrors` exports four view-specific sheets for nonzero mounting offsets.
F continues to control yaw only, in eight 22.5-degree steps.
Every interior/repair variant exports `solar_input`: a physical diagonal-wall inlet's
world/anchor/panel_id, housing/lights sprite paths, position/size and eight connection frames.
`interior_gen.py --solar-input-only` regenerates these without changing existing room art.

The bot adds (§4.1): `bulkheads`, `bot` and `game.reserve_png` in every interior meta JSON (incl.
the repaired variants; read by `Bulkhead`, `Bot`, `InteriorFX`), and `bot/bot.json` (read by
`Bot`). `data/bot_story.json` (read by `StoryState`) owns `names`, `name_entry`, the line groups (`wake`, `correction`, `named`, `reserve`,
`nursery_intro`, `nursery_remind`), ordered `guidance` (oxygen/glass/power/solar/done),
`objectives` (`id`, `label`, optional `machine`/`route`) and talk `lore` (`id`, `trigger`, `lines`).
Camera hints use `{TURN_LEFT}` / `{TURN_RIGHT}` resolved from InputMap. Nursery metadata
adds `bot.body`, `world`, `facing`, `radius`, and canonical `cleaning_spots` for its body.

The panes and the box add (§4.1): `window_cracks` in every interior meta JSON (incl. the
repaired variants; read by `WindowCracks`), and `top` / `half` / `yaw` / `contents` /
`drop_sound` on props objects (read by `Multitool.setup`; any prop with `top` is something to
stand on; `drop_sound` names the `audio.json` sound it makes when the tool sets it down, else
`lift_drop`).
`make interior` also runs `window_repair_gen.py`; `make windows` refreshes only inspection
assets. `interior_gen.py --props-only` refreshes prop sprites and ensures glass pickups have
clear floor while keeping existing scrap/box IDs. Baked glass debris is replaced by real pickups.
`windowglass` and `glassedge` register the existing SKYWIN and WHITE colours for those SDF props.

### 6.4 Recipes
- **A new prop or machine:**
  1. Model it in the generator with existing primitives and existing ramp names, in view 0's
     frame (inside `canonical()` in `mars_map_gen.py`), and render it `turned()` - then it is
     right in every view. Never place a model in a view's coordinates.
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
     Render it in four views, add a `ViewTurn` and an `_apply_view` like `interior.gd`'s.
  3. Add test hooks like `interior.gd`'s.
  4. Move between scenes through `GameState`.

---

## 7. Art bible (the look)

### 7.1 Projection and scale
- Everything is drawn through **the same camera**: 2:1 pixel isometric, orthographic, 30°
  pitch, which can face the world from four sides (quarter turns, §4.9). Every view keeps the
  2:1 look.
  The owner-approved Crack Repair inspection wall faces the orthographic camera directly
  for a flat UI view. Its default uses the owner's supplied panel images unchanged; legacy
  inspection versions use the same SDF renderer, machine materials and pixel shading.
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
  `KEYS` (`day_night.gd`), and keep it cozy. The night is **dark** - too dark to get about in
  without the suit lamp - but never black: the sky light leaves a deep blue-violet floor you can
  just read shapes in, and the things that glow carry it.

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
    spires, alien plants leaning in the wind (a slow gust rolls across a grove at a time, so
    the forest breathes rather than thrashes - `BiomeFX`'s `sway_rate` and `gust_*`, and the
    lean itself in the generator's `lantern_tree`);
  - **ice** around the comms dome: snowfields, frozen lakes, charcoal peaks and cliffs
    under snow.
  - The comms dome sits on a stepped charcoal massif reached by ramped trails.
  - Lands blend with soft, dithered, domain-warped edges, never hard lines.
- **Trails, not roads.** Nothing is drawn on the ground: a trail is the way through where
  nothing grows. Toward a trail the forest thins out gradually and unevenly, and tall plants keep
  out of the strip just in front of it (from this camera they would hide it). No lamps line
  the trails any more (owner, §12; `TRAIL_LAMPS=1` restores them).
  Trails wind; they are never straight. The map screen shows them as dotted routes.
- **The main base (v3):**
  - three smooth white rooms joined by corridors;
  - a ring of tinted, reflective honeycomb glass round each room, with straight borders
    between glass and metal and thin frame lines;
  - two smashed holes per room, each a different irregular shape.
- **The base is dead at the start** (`BASE_POWERED = False`): no lights, nothing turning.
  The nursery and the comms dome are powered.
  Once the generator and all solar routes are repaired, `BasePower` keeps the base lit
  at every hour. Interior surfaces and the existing strips stay steadily lit; outside,
  the existing glass emits teal and the white shell/corridors catch reflected light.
  `tools/base_power_gen.py` owns compact four-view RGB masks under `red_planet/power/`:
  R illumination, G glass emission with original damage, B emission on restored glass.
  Both emission channels include the same reflected window light on the ground. The pool
  falls off evenly around each dome over 100 world units, following the visible terrain
  height/depth with ordered dithering rather than a narrow ground-height slice.
  It uses the actual dome/band geometry and saved depth, preserving occlusion and holes.
  `make base-power` refreshes them; `make map` also regenerates them after the map.
  `DayNight.setup` takes the scene's `MapTerrain` as its optional fourth argument for
  base lighting. `bp_active`, `bp_indoor`, `bp_rect`, `bp_mask` are shader globals;
  all world shaders share the illumination, and camera reliefs take each view's mask.
  Neither the planet beyond the base nor the nursery takes this lighting override.
- **Inside:**
  - glossy white walls with a coral strip, a dark kick plate and a window band;
  - glossy diamond-tile floors;
  - the power is out, so daylight comes through the holes.
  - The power room has a smashed reactor with spilling wires and an open service cabinet
    with a circuit board.
  - The oxygen room has a broken oxygen generator, two O2 bottles and scrap.
  - In storage's south-west, the bot's charging cradle (dark steel plinth, coral ring), its
    cable run to a socket in the wall behind it.
  - Bulkheads in the corridors to the power and oxygen rooms: white posts with hazard feet, a
    lintel and a lamp; steel leaves that telescope into the posts.
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
- No HUD clutter (see §9). The objective line (under the time panel) and the bot's dialogue
  plate (above the hotbar, the speaker on a tab) reuse the time panel's plate.

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
godot --headless --path . res://tests/nursery_test.tscn                # both nursery airlocks, turns, collision and state
godot --headless --path . res://tests/cultivation_test.tscn            # seeds, repairs, growth, harvests, real F/X and views
python tools/check_cultivation.py                                   # all clearings, stable approaches and repair art
godot --path . res://scenes/overworld.tscn -- --spawn=-827,1440 --capture=shot.png --seconds=2
godot --path . res://scenes/interior.tscn -- --spawn=-236,492 --walk=0,-1 --capture=walk.png --seconds=3
godot --path . res://scenes/nursery.tscn -- --time=12 --capture=nursery.png
godot --path . res://scenes/overworld.tscn -- --door --capture=in.png   # through the airlock; the interior takes the shot
godot --path . res://scenes/overworld.tscn -- --no-intro --time=22 --capture=night.png   # check a change by night too
godot --headless --path . res://tests/inventory_test.tscn             # inventory integration suite
godot --headless --path . res://tests/repair_test.tscn                # circuits + real machine/input integration
godot --headless --path . res://tests/view_turn_test.tscn             # turning the camera, in both scenes
godot --headless --path . res://tests/window_crack_test.tscn          # the cargo box: jump on, lift, crack, break, rations
godot --headless --path . res://tests/window_glass_test.tscn          # live reach, real input, scans, cost, final collapse
godot --headless --path . res://tests/dev_panel_test.tscn            # master control panel: time, frozen needs, real keys
godot --headless --path . res://tests/suit_light_test.tscn           # the suit lamp: starts off, L, the beam, the turns
godot --headless --path . res://tests/window_restore_test.tscn       # sealed panes' art and light, every view and variant
godot --headless --path . res://tests/solar_field_test.tscn          # solar optics, routes, equipment and input
godot --headless --path . res://tests/survival_test.tscn             # survival needs, damage, rescue
godot --headless --path . res://tests/survival_hud_test.tscn         # the fixed compact survival panel
godot --headless --path . res://tests/bot_story_test.tscn            # bulkheads, waking the bot, its talk, your name, reserve power, following
godot --path . res://scenes/interior.tscn -- --bot-wake --name=ASTRO --story-auto=0.5 --capture=wake.png --seconds=1.4 --burst=10 --gap=0.45
godot --path . res://scenes/interior.tscn -- --window=gash --turn=2 --cargo-mended=2 --window-fit=6 --capture=break.png --seconds=2.4 --burst=6 --gap=0.3
godot --path . res://scenes/overworld.tscn -- --no-intro --turn-right --capture=turn.png --seconds=1.1 --burst=6 --gap=0.05
godot --path . res://tests/repair_gallery.tscn -- --out=ABSOLUTE_DIRECTORY  # all ten native boards + solved states
node tools/test_wire_repair.cjs                                     # browser circuit model checks
godot --path . -- --no-intro --inventory-demo --open-inventory --capture=bag.png
```

Useful hooks:
- `--spawn=X,Y`, `--walk=DX,DY[,run]`, `--capture=PATH`, `--seconds=S`, `--burst=N`, `--gap=S`
- `--quit=SECONDS`, `--audio-debug`, `--equip`, `--use`, `--face=DX,DY` (both scenes)
- `--perf` / `--perf-every=S`: texture memory, draw calls and mean/worst frame time, once a
  second. There is no screenshot for memory, so this is how a change to it is shown (both scenes)
- `--stream-debug`: every map window as it is stitched (both scenes, §4.10)
- `--turn=N`, `--turn-left` / `--turn-right`, `--turn-at=SECONDS` (when the turn fires, default 1)
- `--dev-panel` (open the master control panel), `--dev-freeze=hunger,thirst,oxygen` (both, debug builds)
- `--suit-light` (start with the suit's lamp lit; both scenes. It is off in an ordinary game)
- overworld only: `--door`, `--intro` / `--no-intro`, `--zoom=L`, `--open-map`, `--debug`,
  `--dome-mended=base|ROOM` (all main-base domes, or just that room, have whole glass)
- interior only: `--cargo=burst|crescent|gash` (box under that pane, you on it),
  `--cargo-mended=N` (the first N panes mended first), `--cargo-land` (land on the box),
  `--window=burst|crescent|gash` (six demo glass and native inspection), `--window-fit=N`,
  `--window-scan=P`, `--window-close=S` (scan/close capture hooks; normal games get no demo glass),
  `--arrive`, `--exit`, `--repair=power|oxygen`,
  `--repair-done=power|oxygen|both` (both tasks for screenshots),
  `--repair-circuit=power|oxygen` (circuit-only preview), `--repair-bars`
  (ignore ambient F input during progress-bar captures),
  `--bot-wake` (beside the bot, tool out, F held: it wakes), `--bot-talk` (talk to it),
  `--bot-follow` (awake and following, beside you from the start; implies `--story=awake`),
  `--story-auto=S` (lines move on S seconds after they finish), `--name=NAME` (the name entry
  types it and confirms; never saved)
- both: `--story=awake` (the bot awake and named, reserve power on, objectives handed out;
  inside, `--name=NAME` names you)
- repair panel: `--reduced-motion` disables turn and completion animation; receiving
  power activates immediately. The browser follows `prefers-reduced-motion`.
- both: `--time=HOUR` (e.g. `--time=22` for night), `--day=N`, `--day-speed=X` (time runs X
  times faster)
- both: `--turn=N` (start N quarter turns round), `--turn-left` / `--turn-right` (turn once
  after a second, for capturing the swing)

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
   **by day and by night** (`--time=12`, `--time=22`), and **from more than one side**
   (`--turn=1`, `--turn=2`).
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
- **Trails are not drawn on the ground**: they form where the plants thin out (no trail lamps
  since 2026-10-11, §12).
- The base starts dead and broken; it gets repaired through play.
- **Compact HUD only**; four survival meters, inventory stack counts, a six-slot hotbar,
  local machine repair progress, the time panel and the objective line under it are
  approved (§12).
- **A day/night cycle** with four parts of the day; lights stay lit at night. **The night is
  dark** (Don't Starve dark): nothing lights the astronaut for them, and the lamp on their suit
  starts off and is switched on with L / pad B.
- The multitool picks its job from the target. One button (F / gamepad X) uses it.
- **No zooming indoors.**
- **The map is stored as tiles and only a window of it is in memory** (§4.10). The art,
  the projection and the four pre-rendered views are unchanged: this is how the pictures
  are stored and loaded, not how they are drawn.
- **The camera turns in quarter turns** (G / H), indoors and out, in a short eased swing;
  the sun stays on the same side of the screen in every view.
- **Dome cracks keep their original look** (a thin bright rim, no heavy dark outline).
  Each room has two different irregular holes, kept as data so they can be traced later
  (inside, storage has a third on its far wall, §12).
- **No music.** Sound is the environment and the work, nothing else (§7.6).
- **Sound is data, not code**: every sound is declared in `sfx_gen.py` and read from
  `audio.json`. The alien tech is synthesised; the natural world is recorded, under an open
  licence, through one mastering chain (§4.8, §7.6).
  The player's master-volume preference is applied to the Master bus above that authored mix.

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
  - **The power room cabinet and battery feed** restore with the completed reactor:
    - `base_interior.json → fx.circuit_board` has `center`, `socket`, the 4 `corners`
      (map px) and `world`;
    - `interior_fx.gd` pulses the empty socket while broken; repaired power variants omit it.
    - `restore_power` closes the existing cabinet and reconnects the original battery cable
      route; broken and oxygen-only variants retain the damage.
  - **Reactor/O2 wiring is implemented:** F/X, five circuits each, timed replacement,
    session state, bolted wires and local progress bars. The native panel uses octagons,
    detailed PCB housings, a blue-green recess and neon green power (owner-approved).
    Crack repair runs first, earns 50%, and consumes three scraps only when all patches seal.
    Wiring earns the other 50%; generated repaired room variants replace the broken machines.
    `machines/machines.json -> repair_panel` exports the flat inspection image (`file`),
    logical `size`, three local task `sites`, `view: "flat"` and `design`. Reference panels add
    `source_rect` (wall crop), `baked_damage`, per-hole relative `damage_samples` and source
    `sha256`. The samples are measured from the original holes/rims for placement checks.
    `--repair-panels-only` refreshes this metadata without writing the supplied PNGs or
    rendering the rooms. Earlier model-projected
    `repair_sites` remain exported for reference; gameplay uses the flat panel sites.
    `REPAIR_PANEL_DESIGN=reference` is the default; `equipment`, `detailed` and `simple`
    retain earlier generated inspection designs.
    `base_interior.json -> repair_variants` maps completed-machine bitmasks (1 power, 2 oxygen,
    3 both) to generated room variants; `fixed_machines` declares their restored equipment.
    `interior_props.json` exports six gatherable scraps using existing prop sprites in four views.
  - **Dead path lamps** by the base can be fixed with the tool (the `fix` job).
  - **Storage's three smashed panes**: native glass jigsaws, collected glass and resumable
    multitool scans are built (§5). The box breaks only after all three repairs complete.
  - Storage has matching three-pane damage inside/outside. Habitat and garage glass is intact.
- **The bot is built** (§5): its cradle in storage, the bulkheads, reserve power, the name, the
  ordered repair guidance, the lore, and two independent maintenance bodies. Open:
  - every name is a placeholder (`data/bot_story.json → names`): the bot and the previous owner.
    The lines are drafts;
  - the bulkheads reuse the airlock's `door_unseal`; a sound of their own (recorded steel)
    needs `make sources` and `ffmpeg`;
  - outdoor companion behaviour remains unimplemented; solar repairs are tracked;
  - more for it to do is listed for the team in `docs/bot-design.md → Ideas for the team
    meeting` (none of it approved or built).
- **Nothing outdoors for the multitool yet**: the test props and dead trail lamps were removed
  (`TEST_PROPS=1` / `TRAIL_LAMPS=1` bring them back). Real ore deposits are not placed yet; the
  tool works on the base's scrap, glass, cargo box and rations. The tests bring their own props.
- **Inventory is implemented:** session backpack, resource stacks, quick access and slot
  swaps. Resources are gathered through the existing tool; ration/water consumption is
  implemented, and three scraps per successful crack repair are consumed atomically.
  Crafting and disk saving remain unimplemented.
- **Nursery restoration and cultivation are built:** three simple F/X repairs, dead beds
  replanted with wild seeds, Emberpod food racks and Dewpod water silos. Sixteen Cindercoils
  and sixteen night-opening Moonwells inhabit small forest clearings. Harvests restore
  hunger/thirst, beds regrow, and all progress uses the session clock/state. See docs/cultivation.md.
- **Sound is built** (§4.8, §7.6): ambience for the three lands and the dead base, positional
  pools / spires / wreck / powered domes / repaired lamps, footsteps per surface, the jump,
  the four multitool jobs, the airlock cutscene, the crash, the backpack, the circuit panel,
  the cargo box (`cargo_*`, `ration_land`, `pane_mend`) and the UI. What is missing:
  - Escape options now save master-volume and GUI-size preferences; gameplay saving is not built;
  - `CREDITS.md` is generated but nothing in the game shows it yet. It must be shown before
    the game is distributed (§10.2).
- **Not built yet:** nursery minigames, the comms interior, saving and loading (the clock
  would be saved with `GameState.clock`, the suit lamp with `GameState.suit_light`), sleep
  and night dangers, music (and there will not be any, §9).

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
- 2026-10-07 — The camera turns round the world in quarter turns, Don't Starve style: G / H
  (d-pad left / right), indoors and out. Every map is rendered from four sides; the turn is a
  0.42 s eased swing with the world stood up in 3D, the view left dissolving into the next.
  90° steps keep the 2:1 iso look in every view; the sun stays put on screen (owner chose 90°
  steps and turning indoors).
- 2026-10-07 — Integrate the approved three-hole scrap-welding draft before circuits on power
  and O2, using actual machine structure as the background. Untimed, 95% per seam, 3px torch,
  overheating/fast-stroke gaps, red cooling weld, sparks, one-second teal seal glow. Consume
  three scraps only after success; preserve attempts/materials on close. Restore the machines
  visually after both tasks, in all four views; provide enough gatherable interior salvage
  using existing props (owner, approved draft and explicitly requested game integration).
- 2026-10-07 — Crack Repair uses a full-screen, flat metal wall with three holes/fractures,
  following the owner's reference. Model the wall from each machine's casing: coral/gold
  for power, teal trim/cooling grille for O2. Use the existing renderer and materials for
  this front-facing inspection view; world machines keep their four isometric views.
- 2026-10-08 — Return Crack Repair to the approved draft's teal console, irregular scrap
  silhouettes and pale silver palette (#d5d8e5, #9a9bb6, #fbfbff). Enlarge the draft's holes
  and scraps 12%; detail each flat wall using its actual machine's collars, casing, leads,
  coolant cells, fan and vents. Keep the earlier plain wall as `REPAIR_PANEL_DESIGN=simple`;
  the requested detailed variant is the default (owner's three image references).
- 2026-10-08 — Simplify the owner's two equipment-panel references into bold flat modules:
  a red core, pressure gauge, gold pipes and vent for power; a round chamber, coolant pipes,
  status bay, fan and vent for O2. Keep the teal console, silver scraps and 12% enlargement.
  Omit the reference's extra labels, graphs and surface noise. `REPAIR_PANEL_DESIGN=equipment`
  becomes the default; previous `detailed` and `simple` designs remain available (owner).
- 2026-10-08 — Use the owner's exact Power/O2 panel PNGs, unchanged, for Crack Repair;
  this explicitly approves an exception to the generated-art rule for these two UI assets.
  `REPAIR_PANEL_DESIGN=reference` is the default; earlier generated designs remain available.
  Measure hole placement from their pixels and display only the wall crop. Restore the draft's
  red/gold torch and layered round filler with stroke-aligned crescent ridges. Reduce heat
  buildup from 1.1/s to 0.35/s, increase cooling, and shrink local melt damage (owner's
  explicit exact-image, draft-welding and reduced-overheating request).
- 2026-10-08 — Owner's explicit survival request approves health, oxygen, hunger and thirst,
  compact icon/bar telemetry above the existing hotbar, and ration/water consumables.
  GameState.survival owns session vitals (SurvivalState); data/survival.json owns all balance
  values. C/right-stick click consumes selected food/drink (focused slot in the backpack).
  Unsafe air in the damaged oxygen room spends suit reserve; wiring completion restores air.
  Head submersion and scene air callbacks are the integration points for future environments;
  scenery pools remain non-swimmable. Starvation/dehydration/suffocation cause timed damage.
  Death pauses play; Enter/A rescues at overworld spawn with full vitals and fresh supplies,
  preserving inventory resources, clock and world/repair progress. No disk save is added.
  Explicit --survival-debug enables F6-F10 test controls; details in docs/survival.md.
- 2026-10-08 — Owner's HUD-only redesign replaces rectangular survival bars with four
  twelve-segment pixel dials in one rounded top-right panel (red/pink health, cyan oxygen,
  amber food, blue water, matching the supplied reference). SurvivalMeter reads existing
  GameState values as clamped percentages, with prominent numbers and subtle /100 text.
  The left grip alone drags the panel; right-click grip, Home or left-stick click resets.
  SurvivalHUDLayout saves normalized placement to user://survival_hud.cfg on release/reset;
  this is a UI preference, not a gameplay save. Room/day toasts avoid the panel by moving
  below it when intersecting. Existing gameplay/balance/controls remain unchanged.
  Debug-only --hud-preview=H,O,F,W and F11/F12 preview quarter-values without touching vitals.
  Focused tests and restart-persistence probes are part of make check; see docs/survival-hud.md.
- 2026-10-08 — Owner's visual-polish request reduces the survival panel to 138x34 logical
  pixels, with 30x30 dials, thinner rings, refined shaded icons and tighter spacing. Main
  numbers use scale-1 PixelFont; /100 and ring contours use a finer hard-edged UI pixel grid.
  Existing segment/value bindings, gameplay, dragging and preference persistence are unchanged.
- 2026-10-09 — Owner's explicit request: storage's cargo box becomes a liftable prop you can
  jump onto (MapTerrain platforms), used to reach three smashed panes - the two in view plus a
  third ('gash') in the wall behind you, found by turning the camera. Inside only: the
  overworld dome keeps its two holes per room. The box cracks once per pane and not again until
  that pane is mended; after the third is mended with you on it, it gives way, you collapse
  (existing landing frames held, no new animation) and four rations spill to be gathered.
  Mending is a stand-in for now (landing under a pane mends it, `STAND_IN_FIX`); the real fix
  job comes later. Sounds reuse existing ones (rock_crack, door_close, land_soft, repair_done)
  until new ones can be made in sfx_gen.py (owner, requested).
- 2026-10-09 — The cargo box gets its own sounds (owner, requested): cargo_land (steel under the
  boots, over the landing thud), cargo_crack, cargo_groan, cargo_burst, cargo_drop (its
  drop_sound when the tool sets it down; crates keep lift_drop), ration_land and pane_mend.
  Recorded steel, cracking, squeak, impact and glass from the existing CC0 packs, with small
  synthesised layers (hollow shell, steel stress, groan, glass seal); no new packs. Baked with
  --only, so every existing sound is unchanged.
- 2026-10-09 — Approved compact window draft integrated for crescent, star and third gash
  (owner). Six world-collected glass per pane; placement and quarter turns; source SKYWIN/WHITE
  material with honeycomb and inside-facing orientation; damage clipped to the pane. Physics,
  clock and survival continue; falling out of reach closes it and retains progress. Stand only
  on the set-down box. The existing gauntlet scans top to bottom and restores glass progressively;
  all three completed scans, rather than three landings/placements, unlock box collapse and the
  existing four-ration spill. Modal ownership releases before collapse to preserve controls.
- 2026-10-09 — Owner requested small single glass chips like the original floor debris,
  with moving white glints instead of opaque outlined piles. They use the existing SDF renderer
  and teal/glass/WHITE ramps; only these thin fragments omit the heavy outer silhouette.
  Reflection sheets retain their selected variant across views and fade with the daylight.
  Remove storage's three teal/mustard barrels, including their baked collision, for the cargo route.
  Sealing a window now restores its entire appearance and removes its hole's baked shaft,
  floor light, halo and live beam/dust. Exact combined restoration states and matching masks
  preserve other holes' lighting across all views, machine variants and airlocks.
- 2026-10-09 — When all three storage panes are mended, the dome outside is mended too (owner,
  requested): the `command` room - storage's room on the overworld, where the airlocks are -
  shows whole glass over its burst and crescent holes in every view. DomeFX lays the patches the
  map generator already exported for mending (`cracks → patch`), lit like the map; no new art.
  The generator's patches now carry the glass band's glare and trim shade through the hole, so
  the mend has no seam. Habitat and garage keep their holes.
- 2026-10-10 — Owner approved the Sunthread web prototype for complete main-game integration
  on latest main: one large triangular-cell conical collector, 4/5/4 Amber/Jade/Coral mirror
  routes, distributed closed-by-default sun feeds, nearby F/X activation/rotation and Q/left
  shoulder reverse, a local three-channel bar and a ground cable into the base power conduit.
  Every assigned reflector is required; B4's 157.5-degree early ray misses the actual cone.
  No outdoor generator or prototype objective/navigation box. Canonical optics/session state
  are separate from generated four-view equipment/world adapters. Repaired reactor plus all
  three channels runs the engine; closing a feed removes its output. Existing DayNight shading,
  WorldProp depth/collision, PixelFont, sound palette and relief camera swing are reused.
- 2026-10-10 — Owner requested moving the complete solar field into the marked original
  array/red-dust clearing and restoring the removed forest/cliffs. Original terrain and flora
  placement rules are retained; only small hardware pads are levelled after scattering.
  Reflectors gain silver sweeps and pivots; sun feeds raise crystals through split lids,
  collecting daylight into beams. Three completed channels energize the receiver cells/crown
  with a rising wave and outward pulse. F/X alone rotates reflectors; Q reverse is removed
  and left shoulder again cycles inventory. Three colored lenses on physical power-room
  walls replace the intrusive floating solar bar, with generated art/anchors in all four views.
- 2026-10-10 — Owner encouraged a varied layout with a sun feed on a mountain sending light
  down to a reflector. Coral's feed uses the existing reachable 58.28-unit mountain ledge;
  its first mirror has fixed tilt. Optics now use actual 3D finite mirror planes and the
  capped receiver, while player controls remain F/X yaw rotation and source activation.
  Elevated feed terrain is preserved; the remaining mirrors use small level ground pads.
- 2026-10-10 — Owner requested a smaller receiver and an uncluttered, interleaved layout:
  receiver radius/height become 40/54 units; all three reflector colors span the field,
  including behind the receiver, with wide hardware clearance. Amber moves onto open ground
  with a narrow level access path. Feeds become sealed cylindrical beacons; split lids open
  before a short faceted crystal emerges and conceal it again on shutdown. The plate version
  is retained as `SOLAR_FEED_DESIGN=shield`. Fixed mirror mounting offsets permit routes to
  follow the landscape; finite optics and generated orientations share the same geometry.
  F/X controls, 4/5/4 counts, mountain feed, original forest and wall inlet lenses are retained.
- 2026-10-11 — Owner removed the outdoor test set (ore rocks, scrap, crates by the spawn) and
  every lamp outside: all trail lamps, lit and dead, with their light pools and posts. Kept as
  versions: `TEST_PROPS=1`, `TRAIL_LAMPS=1`. Lamp spots still keep plants and the spawn clear, so
  the forest is unchanged. Interior and in-dome lamps stay. The fix job remains, with no target.
- 2026-10-11 — Owner requested a master control panel; dev-only by owner's choice (editor and
  debug builds, F1 / Guide): set the time (half-hour steps or a part of the day) and freeze food,
  water and oxygen (`SurvivalState.frozen`). Not part of the shipped HUD. PixelFont gains `<` `>`.
- 2026-10-11 — Owner reported premature receiver strikes from Amber, B3 and C2, and asked
  to check untested angles too. Reflector positions/mounts are adjusted so incomplete paths
  physically miss the cone, while the full 4/5/4 paths, interleaved spacing, mountain feed
  and original vegetation remain. The solar regression suite now searches all reachable
  mirror-angle combinations with consistent orientations, including cross-channel bounces;
  any incomplete path within four world units of the receiver fails with a replayable
  angle assignment. This visual clearance is test-only; the physical cone remains unchanged.
  Generated capture stands now select level ground in the base spawn's walk component,
  with `solar_field_gen.py --stands-only` available to refresh anchors without rerendering art.
- 2026-10-11 — Owner requested keeping the solar wall display clear of the battery cabinets.
  Its paired mounts move along the wall to 30/210 degrees and up to 26 units, below the coral
  trim, with housing/lenses and anchors regenerated for all views and machine-repair variants.
- 2026-10-11 — Owner requested that the astronaut remain the camera's focal point at maximum
  zoom-out. Normal follow no longer selects a nearby dome; the existing zoom range, smoothing,
  torso offset, cutscene focus and indoor zoom lock remain. Real-scene camera tests cover walking
  at widest zoom, all four headings, swing endpoints and zooming back in.
- 2026-10-12 — Owner requested a less cluttered solar puzzle following the marked hills:
  receiver moves to (-715, 2015); Amber uses capped western peaks, Jade the right-hand hill,
  Coral the upper cliff. Reduce reflectors to three yellow, four red, three blue (A/B/C 3/3/4),
  with relays on hills and ground and shorter descending routes. Authored flat tops and graded
  access ramps are applied after scattering; original plant X/Y, variants and phases remain.
  Source/mirror elevations drive shared 3D optics and generated mounting pitch/yaw. Keep the
  previous field as `SOLAR_FIELD_LAYOUT=v1`; the approved terraced layout is v2/default.
- 2026-10-12 — Owner requested visible mirror bounces, no mid-air cutoffs or rays through
  surfaces, and slightly thicker light. Canonical `SolarWorldGeometry` intersects the existing
  bilinear ground grid before downstream optics; unblocked rays extend beyond every view's
  map/viewport rather than the placement bounds or an arbitrary Z ceiling. Empty-sky depth
  (65535) never occludes light. Mirror-owned y-sorted contact meshes draw the incoming/outgoing
  light over their faces without moving the whole beam layer above foreground actors. Core/halo
  widths become 2.25/6 pixels, with matching swing thickness; small ground glints mark physical
  impacts. MapTerrain shares explicit-view point/direction projection for the escape envelope.
  The beam suite covers individual
  and seeded mixed yaw settings, terrain/endpoints, native four-view contact pixels and shader
  sky/solid fixtures. No equipment placements, terrain or generated assets change.
- 2026-10-12 — Owner clarified that light must meet the reflective face while parts
  physically behind the reflector stay hidden, and requested other-angle checks. Replace
  short, always-overlaid contact strips with shared full beam geometry, clipped using
  generated per-pixel reflector depth/silhouette (including frame, pivots and post).
  The reflective skin matches the existing finite optical plane; hardware keeps its SDF
  depth. Float UV depth replaces byte-packed colors to avoid false occlusion and preserve
  unbounded escaped endpoints. Native front/behind pixel checks cover all ten reflectors,
  eight yaw settings and four views, with day/night world galleries. Layout and optics
  remain unchanged; generator-owned depth strips are committed with their source.
- 2026-10-12 — Owner reported isolated light dots inside every reflector. Keeping optical
  plane depth on both faces exposed the buried bounce vertex even from behind. RG now
  retains the actual SDF face depth; B stores the finite skin gap. Per-hit UV.y annotation
  permits that gap only for incident/reflected segments on the camera-visible side, including
  routes revisiting a mirror from opposite sides. Real back-side contact pixel checks extend
  the all-angle suite; the focused Jade reproduction fails before the fix. No routing,
  equipment or terrain changes.
- 2026-10-12 — Performance, against three reported issues (#7, #8, #11), measured with a new
  `--perf` hook rather than by feel, and with `--no-stream` so both map paths can be compared in
  one build. **What each change is actually worth, measured on an Intel UHD 620:**
  - *the map window* (§4.10): texture memory 1097 MB → 200 MB, VRAM 1122 MB → 232 MB. Frame
    rate unchanged (both 60), and **process RSS 306 MB → 295 MB**. Nearly all of its benefit is
    GPU memory, which on an integrated GPU is system memory but is not in the process's
    resident set - so it does **not** show in a task manager, and #11 is not answered by it.
  - *redrawing only what changed* (the clock dial, the four survival meters, the flora list):
    this is what took the frame rate from 30 to a locked 60.
  - *the turn* no longer freezes: it kept a press rather than forcing its view into memory on
    the frame of the press, which cost up to 1965 ms when one turn followed another.
  - *the forest*: trees lean about half as far (crown travel ±6.1 px → ±2.8 px) on a slow gust
    that rolls through a grove at a time; the screen changing between frames fell 27% → 6%.
  Of the ~300 MB a task manager shows, ~177 MB is an empty Godot window on the same machine,
  20 MB the walk grid and 8 MB the audio. **Say which memory you mean when you report a
  number**; the three in play here (process RSS, texture memory, VRAM) move independently.
  Also: the map's layers are stored as 512 px tiles, the depth map dropped its unused alpha
  channel, and the map JSONs are parsed once with one view's fx held at a time - parsed, 350 KB
  of JSON costs 4.2 MB of heap (agent, from the owner's three issues).
- 2026-10-12 — Merge performance main into the solar branch: streamed depth windows bind to
  world beams, reflector replays, impacts and receiver FX; initialize player occlusion after the
  first window publishes. Neighbor-window prediction keeps the astronaut centered at every zoom.
  Regenerate all four maps/tiles with the terraced field and calmer tree sway; forest clearance
  checks fingerprint canonical feet so narrower sprite boxes do not count as moved plants.
  Native contact comparisons wait for zoom to settle. Headless texture preloads run serially
  because the Godot dummy renderer races concurrent texture allocations; a preload/window
  upload stress regression guards the workaround. Displayed game preloads remain asynchronous.
- 2026-10-12 — The bot (team design; approved by the requester): a new maintenance bay south of
  storage, where the base's bot sleeps docked in a charging cradle. Woken with the multitool's fix
  job, it takes you for the previous owner, you give it your name, it switches on reserve power
  (the emergency lines light; bulkheads sealing the power and oxygen rooms open) and hands out
  two objectives, restore power and restore oxygen (either order; done when each machine's repair
  is complete), then drips lore as you progress. Look A (pod) from `docs/bot-mockups.png` is the
  default; B (lantern) and C (orb) are kept as `BOT_DESIGN`. It stays docked (no following).
  Every name is a placeholder in `data/bot_story.json`. Approved with it: the objective line
  under the time panel (a HUD element beyond §9's list), remembering the player's name in
  `user://profile.cfg`, and PixelFont's `.` `,` `?` `!` `'`. Sounds: bot_boot, bot_chirp and
  reserve_on are synthesised; the bulkheads reuse the airlock's door_unseal for now.
- 2026-10-12 — The bot reworked (requester, for the team): no room just for the bot - the
  maintenance bay and its corridor are removed, and the bot's cradle is in storage, the room the
  airlock opens into. Once the opening is over, the bot follows the astronaut round the base,
  inside only (it waits indoors and meets you at the airlock); it is never solid, and its talk
  prompt only shows when you face it, so F stays with the tool. Its sheet is eight facings drawn
  once (like the astronaut's) instead of one strip per view; a quiet synthesised `bot_hover`
  goes with it. Further bot features are listed for the team in `docs/bot-design.md`, not built.
- 2026-10-13 — Owner's explicit darkness request: the night is Don't Starve dark and the
  astronaut carries the only light. `KEYS`' night and dusk/dawn multipliers drop (full night
  0.30/0.34/0.60 -> 0.085/0.095/0.175, with a smaller sky-light floor); daylight, the golden
  evening and the four parts of the day are unchanged. The soft pool that used to follow the
  astronaut at night is gone: nothing is lit for you, and the dead base lights nothing either.
  In its place `SuitLight` (`scripts/suit_light.gd`), a lamp on the suit that **starts off**
  and is switched with L / gamepad B; it stays as you left it through the airlock
  (`GameState.suit_light`). It is a beam thrown along the ground the way the astronaut faces,
  with a small spill round their feet, and it lights them all over because they carry it. Built
  as two shader globals (`dn_lamp`, `dn_beam`) read by the existing day/night include, so no
  dynamic light is added and the camera's quarter turns keep it pointing the same way in the
  world. Its strength follows `DayNight.night`, so it does nothing in daylight. Two synthesised
  sounds (`suit_light_on` / `suit_light_off`) baked with `--only`, no new packs. No HUD was
  added (§9): the beam itself is the indicator. `tests/suit_light_test.tscn` covers it and is
  part of `make check`.
- 2026-10-17 — Completing power's crack and circuit repairs also automatically closes its
  service cabinet and reconnects the torn battery cable circled by the owner. Restore these
  parts in the existing repaired power/both variants, including depth/walk/light data and all
  four views; preserve damage before completion and when only oxygen is repaired (owner).
- 2026-10-19 — Merge main into the bot branch (requester): the suit lamp, the map window, the
  terraced solar field and the performance pass come in alongside the bot. The bot and the
  bulkheads now bind main's depth window (`MapStream.bind()`, re-bound on `_window_moved`), and
  the objective line, dialogue, name entry, bulkhead lamp and bot glow redraw only when what they
  show changes, as DayClock does. The interior, window, bot and the bot's sounds were regenerated
  on the merged code; 409 regenerated images were pixel-identical to main's and keep main's bytes.
  The suit lamp needed nothing: it ignores presses while the bot's dialogue or name entry pause
  the world. Under the dark night the following bot shows only its eye glow outside the lamp's
  beam; kept that way, as the darkness rule asks (requester).
- 2026-10-21 — Nursery exterior v2 (owner approved the larger-base/larger-pane mockup, then
  requested its in-game replacement and properly fitted doors): use the main base's reflective
  tinted honeycomb material over the hemisphere, a 10-degree lower wall boundary, approximately
  32-world-unit hex sides, a tiny round white cap and a broad white/coral footing. Stretching at
  the top is accepted. Both trail entrances use the existing white/coral portal frames and
  closed split doors. The older clear ribbed shell, rim LEDs and wind gauge remain available
  with `NURSERY_DESIGN=v1`; v2 is the default. No nursery interior or scene transition is added.
  In-game inspection also cleared the three mushroom trees whose canopies covered the door
  faces (105-world-unit trunk clearance from either outer door), with all other forest
  placements retained. The omitted placements still consume their original random draws and
  spacing, and contribute neither shadows, collision nor glow.
- 2026-10-22 — Implement the approved aligned_v12 nursery interior and functional doors
  (owner): three rear living walls, two hydroponic towers, one central specimen pod with its
  coaxial halo on straight supports, a shallow cyan propagation channel, bottom control panel
  and forward right oxygen tank. Remove the crossing boards, bench and extra cabinets/pods.
  `nursery_gen.py` owns all four native SDF views, collision, daylight/powered-light masks and
  animated portals. Stable exterior IDs 1 and 5 route into the room and either exit returns
  through its matching exterior door. `make nursery` and `make check` include regeneration
  and real keyboard/gamepad transition, collision, camera-turn and state-continuity checks.
  Nursery minigames remain future work.
- 2026-10-22 — Nursery QA corrections (owner): reduce the exterior radius by 25% and the
  interior room/furnishings by 20%, retaining the shared astronaut and usable door dimensions.
  Inlay the propagation ring flush with the floor and put matching screens on both monitor
  faces. Landing pads are static floor inlays, excluded from animated door sheets: the old
  y-sorted landing covered the astronaut's body during arrival. `check_nursery.py` checks the
  actual sheet's landing transparency plus native floor, monitor and scale geometry; the
  integration suite retains movement, both-door and four-view coverage at the smaller size.
  The compact exterior is applied after the original terrain/scatter pass, as with solar
  grading: only its plinth/material/light footprint changes, preserving the original flora.
- 2026-10-23 — Integrate the automatic power cabinet/cable restoration onto current main,
  preserving the bot, bulkheads, reserve lighting and nursery. Regenerate the interior and
  repair variants from merged sources before publishing to GitHub (owner, requested).
- 2026-10-23 — Full main-base power requires the O2 machine, power machine and all three
  solar paths complete (owner). Both machine tasks must be done. Light the base indoors
  and outdoors at every hour, preserving independent bot reserve power, the suit lamp,
  window damage/restoration and the dark planet outside. Generated compact masks follow
  all four views and streaming; camera swings carry their own view's lighting.
- 2026-10-23 — With full base power and storage glass still broken, remove all incoming
  sunlight at night, including the dark beam shapes left by scalar dimming (owner).
  Generate matching sunlight-free room/window pixels for every view and machine variant;
  retain daytime rays and physical glass damage. Carry the paired pixels through live and
  paused sealing scans, completed panes, camera swings and airlocks.
- 2026-10-26 — Owner requested F1 admin toggles for oxygen, power, glass cracks and solar
  reflection tasks. Complete their actual session state instantly without travel, materials
  or playing puzzles; toggle DONE back to reset that task. Preserve independent story and
  cargo-box state, refresh repaired/damaged art and lighting live, and retain debug-only access.
- 2026-10-26 — Owner requested completed storage glass repairs restore all three main-base
  domes, including habitat and garage. Use the existing generated glass patches in all four
  views and camera swings; retain damage until all three panes are complete. Broaden full-power
  window spill evenly around every dome, following actual visible ground with dithered falloff.
- 2026-10-26 — Owner reported the suit beam coming out of the ground while jumping. Anchor
  it to the sprite's existing pixel-snapped vertical offset during jumps, falls and platform
  standing, and share that origin with camera reliefs. Preserve the grounded beam and controls.
- 2026-10-26 — Owner requested Escape pause/options with a dark-grey backdrop leaving 15%
  of gameplay visible, a master-volume slider and Small/Medium/Large GUI controls. Large keeps
  the original UI; smaller choices resize hotbar, clock, stat panel and E backpack together,
  retaining placement and pointer geometry. Save these preferences separately from game state.
- 2026-10-25 — Implement the approved modest nursery damage and native crop/wild-plant
  mockups (owner). F/X taps repair the console, grow light and irrigation, then plant or
  harvest the three Emberpod food racks and two Dewpod water silos. Minigames remain future
  work. Crops begin dead and need wilderness seeds; one handful covers a crop type's beds.
  Cindercoil is woody curled scrub with dry seed cases, without edible-looking wild fruit.
  Moonwell opens at NIGHT (20:00–05:00), exposing glowing Dewpod seeds for F/X collection.
  Sixteen of each, roughly astronaut height, occupy small reachable forest clearings; only
  filler undergrowth is removed, preserving trees and the original scatter stream.
  Native four-view crop/depth/glow sheets, eight nursery repair combinations, inventory fruit
  and game-clock regrowth use existing controls, survival and GameState ownership. Retain the
  earlier intact room with `NURSERY_CONDITION=restored`. Balance/data/test hooks are documented
  in docs/cultivation.md; seeds/fruit are not granted at the start.
- 2026-10-25 — Nursery repairs require the equipped multitool (owner). Hold F/X for the
  existing 2.4-second cyan scanner fix job, including the astronaut's use pose and tool beam
  sound. T/Y equips it. Unfinished `repair_progress` survives release, unequipping, camera
  turns and airlocks; completion requires a release before another action. Planting,
  harvesting and wild seed gathering retain taps. The nursery generator owns `scan_height`
  per system; `make nursery-metadata` refreshes anchors across all repair variants/views.
- 2026-10-25 — Nursery visual cleanup (owner screenshots): floor feeds remain intact;
  the dry propagation channel is grey steel. Remove console/grower hanging wire bundles.
  The console instead has a chipped monitor bezel and screen fractures. The centre rear
  growing rack has one sagging middle shelf and a damaged support, restored by the same
  multitool scanner. `rack` replaces `irrigation` as repair bit 4, retaining three quick
  repairs. Its dead crop overlay follows the bent shelf until repaired; all three systems
  restore circulation and normal growing. All eight combinations retain four native views.
- 2026-10-25 — Crop pacing (owner): Emberpods and Dewpods take a full in-game day
  (24 game hours) from planting to ripeness, and another full day after each harvest.
  `data/cultivation.json` owns both delays. At the normal clock speed this is 12 real
  minutes per growth cycle; pauses still stop growth and time away still counts.

- 2026-10-26 — Owner: compact inventory/stats/clock/objective HUD, fixed top-left stats,
  no dragging or saved placement. UNIT patrols/cleans instead of following; an initially
  dormant nursery body must be repaired before its systems. Same-mind introduction explains
  both crops, night Moonwell seeds and day-long growth. Independent body positions and partial
  repair progress live in StoryState; bot_gen.py owns native clean frames, nursery metadata
  owns its body and cleaning floor anchors.
- 2026-10-26 — Owner: ordered UNIT advice O2 → three storage panes (rear-pane hint resolves
  current turn keys) → generator → solar; seven tracked tasks and an unread exclamation.
  FacilityAir in GameState makes outdoors/unpressurized rooms drain suit O2 at 0.1/s (a full
  tank lasts 16m40s). Refill is 20/s only in sealed facilities with O2 supply. Full O2 repair
  starts 24 game hours of reserve (12 real minutes); the repaired generator and three solar
  routes sustain it. The nursery tank shares that supply. Reserve uses the game clock,
  survives airlocks/rescue and resets with explicit world reset. Compact notices explain it.
- 2026-10-26 — Owner: exterior command/storage rear gash added; habitat/garage holes removed.
  All three command panes restore together through the existing dome_mended patches.

- 2026-10-26 — Owner: reserve is O2-only, with a persistent battery/status indicator. Maintenance
  access is `StoryState.access_opened`, mechanically opening bulkheads without restoring light.
  `DayNight.facility`, `darkness`, `fixture_power` and shader `dn_power` keep unpowered interiors
  dim at every hour; generator + all solar routes restore proper lighting day and night. The
  suit lamp works indoors at noon. Empty reserve stops indoor O2/refill and resumes suit drain.
- 2026-10-26 — Owner: remove broken exterior glare. Opaque band domes clear stale emission from
  their earlier interior render; native ray/depth masking and light-only regeneration cover
  all four views without changing terrain, vegetation or colour. Add dome-light regression QA.
- 2026-10-26 — Owner: nursery checklist and actual cleanup. Six native dirt/leaf/tray-chip
  overlays shrink as UNIT reaches and vacuums them. Extend the approved bot with a deployable
  native intake, sweep/stow frames and generated nozzle anchors. Cleaned-pile fractions persist
  in StoryState; successful first food/water harvests persist in CultivationState. No extra inputs
  or minigames. `make nursery` generates cleanup art; native cleanup/power tests join `make check`.

- 2026-10-26 — Owner: hide the reserve HUD until O2 is repaired, and hide it again on full
  generator/solar mains. Add a compact physical RESERVES side-wall gauge. The revised native
  housing contains its own 3x5 lettering and ten charge segments; the label is never a floating
  UI plate. `tools/reserve_meter_gen.py` owns housing/eleven levels and `reserve_meter` metadata
  across four views/all machine variants. Authored wall repeaters are selected against every
  variant's final depth so tanks cannot cover the face. `clear_fraction` exports this check.
  `make reserve-meter` or `interior_gen.py --meter-only` refreshes only that overlay. Before O2
  repair and on mains the physical readout is dark; the wall hardware remains in place.
- 2026-10-26 — Owner: UNIT cleans occasionally, with a quieter local vacuum. Both bodies now
  remove six real litter overlays instead of vacuuming empty patrol stops. Random roaming and
  brief idle intervals are data-owned; partial dirt progress remains session state. The new
  `bot_vacuum` recipe in sfx_gen.py uses filtered lift-fan synthesis at -27 dB gain, 120 px reach
  and 0.3 s fades, independently of multitool gathering. Release it on pause/talk/turn/stroll.

- 2026-10-26 — Owner requested merging main (PR #25) into the nursery branch. Keep Escape
  options, volume, GUI preferences, admin task toggles, raised suit-lamp anchor and exact
  nighttime sunlight removal. One shared GUI factor replaces the duplicate compact scaling;
  Small defaults to the compact HUD, with Medium/Large available. Stats stay fixed top-left;
  nursery/base checklists and reserve counter scale with the clock and inventory. Preserve
  O2-only reserves, generator/solar mains in both facilities, real UNIT cleanup and the three
  storage exterior holes (other domes intact). Options release guards also cover cultivation.

- 2026-10-26 — Owner: give the nursery the same nighttime exterior glow as the main base.
  Extend the existing generator/solar mains masks with four compact nursery crops, using
  identical teal glass emission, shell illumination and 100-world-unit ground spill. Keep
  the original base masks pixel-identical. Both live shaders and camera reliefs sample the
  extra crop, gated by the existing mains state; O2-only reserves leave it dark.

- 2026-10-26 — Owner: nursery console screen must be repaired before nursery power comes on.
  `GameState.nursery_powered()` derives from the existing console repair bit. DayNight uses
  the nursery power callback; exterior masks use independent `bp_nursery_active`, including
  camera turns. Screen repair lights nursery immediately even before base generator/solar;
  base mains cannot bypass the broken screen. O2 remains piped from FacilityAir and still
  requires main-base O2 repair, supply and seals. Remove UNIT cleaning from the eight player
  checklist tasks; autonomous cleanup/progress continues without blocking checklist completion.

- 2026-10-26 — Owner: add nursery repairs to Master Control. Extend the existing Complete/Reset
  rows with nursery UNIT, screen, grow light and food rack. Toggle real session repair state,
  clear the selected scan on reset, and refresh live art/power/body behaviour. UNIT completion
  bypasses only its nursery introduction for immediate patrol; reset restores its dormant
  repair job. Preserve main story, inventory, crops, harvests and cleaned dirt. Keep all eight
  task rows visible on the native 384x216 panel; keyboard, pad and pointer input retain one list.
