# AGENTS.md — working on GTFO

GTFO is a cozy isometric pixel-art game set on a red planet. You are an astronaut on a broken
outpost: three domes linked by winding roads across three lands (red dust, an alien forest,
ice). The main base is dead when the game starts. You get into it, find it wrecked, and bring
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
| Python | 3.14 | Only for the art generators in `tools/`. |
| Python packages | NumPy 2.4, Pillow 12.3, SciPy 1.17 | `pip install numpy pillow scipy` |
| RAM | several GB free | `mars_map_gen.py` renders a 7751×4350 map. Close other heavy apps. |

1. Clone, then open `project.godot` in Godot 4.7.2. The first open imports every texture,
   which takes a while (the map is big). `.godot/` is rebuilt locally and is git-ignored.
2. Press Play: `scenes/overworld.tscn` is the main scene. On a fresh run the satellite crash
   intro plays first; any button skips it.
3. You only need Python if you change art, maps or data (§6).

---

## 3. Project map

```
project.godot          viewport 384x216, integer scaling, nearest filtering, pixel snapping
scenes/
  overworld.tscn       main scene: the red planet
  interior.tscn        inside the main base (storage / power room / oxygen room)
  player.tscn          the astronaut: Shadow, AnimatedSprite2D (depth-occlusion shader), GameCamera
scripts/
  game_state.gd        autoload GameState: the only state carried between scenes
  inventory_ui.gd      six-slot hotbar and paused backpack; draws existing sprites and PixelFont
  map_terrain.gd       MapTerrain: walkability, ground height, biome, world<->pixel projection
  player.gd            Player: movement, low-gravity jump, slopes, multitool states, cutscene puppet
  game_camera.gd       GameCamera: pixel-snapped follow, zoom levels, cutscene focus, shake, zoom lock
  multitool.gd         Multitool: equip, job picking (mine/gather/lift/fix) and their effects
  world_prop.gd        WorldProp: a loose thing the tool works on (rock, chunk, scrap, crate)
  airlock_door.gd      AirlockDoor: "[F] ENTER/EXIT" prompt and the door cutscene, both ways
  overworld.gd         builds the overworld, doors, intro, test hooks
  interior.gd          builds the interior, exit door, test hooks
  crash_site.gd        the satellite crash intro and the smouldering wreck
  biome_fx.gd          live plants, bioluminescence, pools, ice glints, embers
  dome_fx.gd           dome rim lights, airlock blinkers, comms beacon, animated dome parts
  wind_fx.gd           weather per land: dust gusts, spores, snow
  interior_fx.gd       sun shafts and dust, sparks, leaking gas, fault LEDs, room-name toast
  map_screen.gd        M: full map overview (pauses the game)
  pixel_font.gd        PixelFont: the 3x5 pixel font for every bit of in-game text
shaders/
  depth_occlusion      the astronaut behind scenery: silhouette, or tinted behind glass
  prop_depth           props behind scenery: hidden, or tinted behind glass
  flora_depth          live plants hide behind cliffs and thin out round the astronaut
  crash_reveal         uncovers the untouched ground behind the crashing satellite
  dust_gusts           dithered wind-gust overlay
tools/                 the art pipeline (Python): generates everything in assets/
  astronaut_sprite_gen.py   the astronaut and the multitool: SDF model, rig, every animation
  godot_spriteframes.py     astronaut.json -> astronaut_frames.tres (SpriteFrames)
  mars_map_gen.py           the overworld: terrain, biomes, domes, props, plants, all map data
  props_gen.py              test props for the multitool and the list of dead lamps
  interior_gen.py           the base interior: rooms, machines, data
  *_viewer.html             browser previews of the sprites and the map
assets/                (lowercase, always)
  characters/astronaut/     generated sprite sheets, astronaut.json, astronaut_frames.tres, previews
  characters/Astronaut_in_his_space_suit/   OLD reference art, not used by the game; don't build on it
  maps/red_planet/          generated overworld: map, depth, walk, biome, fx, props, flora, anim, previews
  maps/base_interior/       generated interior: map, depth, walk, json, anim (door), preview
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
| `*_map.json` / `base_interior.json` | projection constants (`game`), spawn, domes, zoom frames, door, fx |
| `red_planet_fx.json` | plants, glows, halos, crash scene, dome cracks, airlock doors |
| `red_planet_props.json` | sprite sheets and placements of the multitool test props, dead lamps |

Scripts must **read positions from this data** (door positions, LED pixels, crack outlines and
so on). Never hard-code a map pixel position in a script. If you need one, the generator
exports it.

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
- **Interior nodes, in draw order:** `Map` → `InteriorFX` → `Actors` → `Multitool`.
- Anything that moves in front of or behind the pre-rendered scenery must use a depth shader
  with `sprite_depth` = world Y of its feet:
  - `depth_occlusion` for characters (they show as a silhouette behind things);
  - `prop_depth` for props (they hide behind things).
  Both tint through glass.
- `snap_2d_transforms_to_pixel` is on, so **y-sort keys and offsets must differ by whole
  pixels**. Half-pixel offsets tie and swap draw order at random.

### 4.4 Input
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

### 4.5 Scenes and state
- Cross-scene state lives **only** in the `GameState` autoload:
  - `intro_done`: the crash plays once;
  - `arrive` and `door_id`: where to appear next;
  - `tool_out`: the multitool stays out across the airlock.
  - `inventory`, `selected_slot`: 24 slot dictionaries (`kind`, `count`), first six are
    quick access. Empty slots are `{}`. Item kinds are `multitool`, `ore_chunk`, `scrap`;
    resources stack to 99. Use `store_item`, `swap_slots`, `select_slot` and listen to
    `inventory_changed`. A full bag leaves gathered props in the world.
  - `removed_props`, `spawned_props`: session ledger for gathered props/mined rocks and
    their loose chunks. IDs derive from props JSON path/index, with `/chunk/N` for mined
    chunks. Generated JSON is unchanged. Saving to disk is not implemented.
- Going in: an overworld door emits `entered`, then `overworld.gd` sets `GameState` and
  changes to `interior.tscn`, which plays `door.arrive()`. Going out works the same way in
  reverse. Both base airlocks lead into the same storage room. You come back out of the one
  you went in by.

### 4.6 Effects pattern
FX scripts draw procedurally in `_draw()`:
- Positions come from the fx JSON. Draw only what the camera sees, and round every
  position to whole pixels.
- Glow goes in a child `Node2D` using `CanvasItemMaterial.BLEND_MODE_ADD`.
- Soft shapes come from cached `ImageTexture`s: the `_halo(r)` (dithered) and `_disc(r)`
  pattern.
- **Additive light disappears on white surfaces.** Anything that must read on the white
  machines (sparks, for example) is drawn as solid pixels in the normal layer, with only
  the halo additive.

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
- **Doors** (`airlock_door.gd`):
  - Within 30 units, a `[F] ENTER` / `[F] EXIT` prompt shows.
  - Pressing F starts a cutscene: the camera moves behind the astronaut, the warning lamp
    blinks, the door unseals and vents gas, the astronaut walks in, the door closes, and
    the screen fades.
- **Intro** (`crash_site.gd`): the satellite crash-lands near the base, once per run, and any
  button skips it. Afterwards the wreck keeps smouldering.
- **Map screen**: M toggles it. It pauses the game and shows where you are and what the camera
  sees.

---

## 6. The art pipeline

### 6.1 How art is made
All art is **rendered by code**. Signed-distance-field (SDF) models are ray-marched straight
at pixel resolution through the game's exact camera, then cel-shaded from hand-picked colour
ramps, dithered, inner-lined and outlined. This is why everything matches. Do not import
hand-drawn, AI-generated, downloaded or upscaled art into the game. If something new is needed,
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
- **A new scene:**
  1. Copy the interior's structure: a generator for the picture and data, a `MapTerrain`
     from its JSON, the player's `setup`, and a scene FX script.
  2. Add test hooks like `interior.gd`'s.
  3. Move between scenes through `GameState`.

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
  - The comms dome sits on a stepped charcoal massif reached by ramped roads.
  - Lands blend with soft, dithered, domain-warped edges, never hard lines.
- **Roads wind; they are never straight.**
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
- No HUD clutter (see §9).

---

## 8. Testing and verification

`godot` below means your Godot 4.7.2 executable (on Windows, the `_console.exe` build prints
errors to the terminal). The scenes take test hooks after `--`; the full lists are in the
headers of `overworld.gd` and `interior.gd`:

```
godot --headless --path . --import                                   # re-import after regenerating
godot --headless --path . res://scenes/overworld.tscn --quit-after 300 -- --no-intro   # errors?
godot --headless --path . res://scenes/interior.tscn --quit-after 300
godot --path . res://scenes/overworld.tscn -- --spawn=-827,1440 --capture=shot.png --seconds=2
godot --path . res://scenes/interior.tscn -- --spawn=-236,492 --walk=0,-1 --capture=walk.png --seconds=3
godot --path . res://scenes/overworld.tscn -- --door --capture=in.png   # through the airlock; the interior takes the shot
godot --headless --path . res://tests/inventory_test.tscn             # inventory integration suite
godot --path . -- --no-intro --inventory-demo --open-inventory --capture=bag.png
```

Useful hooks:
- `--spawn=X,Y`, `--walk=DX,DY[,run]`, `--capture=PATH`, `--seconds=S`, `--burst=N`, `--gap=S`
- overworld only: `--equip`, `--use`, `--face=DX,DY`, `--door`, `--intro` / `--no-intro`,
  `--zoom=L`, `--open-map`, `--debug`
- interior only: `--arrive`, `--exit`

**Definition of done:**
1. Both scenes run headless with **no errors or warnings**.
2. You captured screenshots of what you changed and **looked at them**, at 1:1 and zoomed in.
3. Walk tests show the astronaut can reach everything they should, and nothing else.
4. Previews and viewers (`assets/maps/red_planet/preview/`, `tools/*_viewer.html`) still look
   right if your generator writes them.

---

## 9. Locked decisions (owner approval needed to change)
- The camera, projection, scale, sun direction, outline colour, dithering and palette
  family (§7).
- The astronaut's proportions and animation set; multitool design **v2** (red and gold
  gauntlet) is the default.
- Main base design **v3** is the default. The old designs stay available as versions.
- The three lands and where they are; winding roads; the comms massif.
- The base starts dead and broken; it gets repaired through play.
- **No HUD bars**; inventory stack counts and a six-slot hotbar are approved (§12).
- The multitool picks its job from the target. One button (F / gamepad X) uses it.
- **No zooming indoors.**
- **Dome cracks keep their original look** (a thin bright rim, no heavy dark outline).
  Each room has two different irregular holes, kept as data so they can be traced later.

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
- Move or rename resources in Godot's FileSystem dock so references update, or update every
  `res://` path by hand.
- Line endings are normalised by git. Don't reformat or convert whole files; keep diffs to
  what you changed.

### 10.3 For AI agents specifically
- Follow this file over your own habits. Match the surrounding code: its naming, comment
  density, typing and idioms.
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
- **The repair loop is not built yet.** The pieces are in place, waiting for it:
  - **Dome cracks to trace and fix:**
    - `red_planet_fx.json → cracks` has, per hole: room, id, shape, outline polygon, crack
      strokes, centre, world position, and patch image and position;
    - the images are in `assets/maps/red_planet/anim/cracks/`.
  - **The power room circuit board** (shown but not interactive yet):
    - `base_interior.json → fx.circuit_board` has `center`, `socket`, the 4 `corners`
      (map px) and `world`;
    - `interior_fx.gd` pulses the empty socket.
  - **The reactor and the oxygen generator** are broken. How they get repaired is not
    designed yet (§10.1).
  - **Dead path lamps** by the base can be fixed with the tool (the `fix` job).
- **The multitool works on test props only** (ore rocks, chunks, scrap and crates near the
  spawn, from `props_gen.py`). Real ore deposits are not placed yet.
- **Inventory is implemented:** session backpack, resource stacks, quick access and slot
  swaps. Resources are gathered through the existing tool; crafting/consumption is not
  implemented. No new generated item art or map data keys.
- **Not built yet:** interiors for the nursery and comms domes, saving and loading, sound
  and music.

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
- 2026-10-07 — Inventory feature request approves a visible six-slot hotbar, 24-slot
  backpack and resource stack counts. E opens/closes inventory; existing world interactions
  move to F (gamepad X unchanged). PixelFont/palette/generated sprites are reused; inventory
  pauses gameplay. Ore/scrap are stored in GameState, persist through scenes, and can be
  rearranged; no crafting or new resource-use jobs (owner's explicit inventory request).
