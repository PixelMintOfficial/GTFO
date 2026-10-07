---
name: art-pipeline
description: "How to change anything visual in GTFO: the astronaut, the multitool, the overworld map, biomes, props, the base interior, terrain/walk/depth data, or any PNG or JSON under assets/. Use before editing a file in tools/, before touching an image, and whenever a change needs regenerating, re-importing or a new ramp, primitive, prop or data key. Triggers: generated asset, regenerate, sprite sheet, SDF, palette ramp, walk grid, depth map, map JSON, MAP_OUT, BASE_DESIGN, TOOL_DESIGN."
---

# The GTFO art pipeline

Every image and data file under `assets/` is **rendered by code** by a tool in `tools/`.
Hand edits are overwritten on the next run. To change what the game looks like, change the
generator and regenerate.

Read `AGENTS.md` §6 (the pipeline) and §7 (the art bible) before the first change of a task.
This skill is the procedure; AGENTS.md is the law. §9's locked decisions need owner approval.

## 1. Find the owner of what you want to change

```bash
grep -rln "<thing you want to change>" tools/          # which generator draws it
jq 'keys' assets/maps/red_planet/red_planet_map.json   # which data key feeds it
grep -rn "<json key>" scripts/                         # every reader of that key
```

| You want to change | Generator | Target | Cost |
|---|---|---|---|
| the astronaut, the multitool, an animation | `astronaut_sprite_gen.py` + `godot_spriteframes.py` | `make astronaut` | slow (~1000 frames) |
| overworld terrain, biomes, domes, roads, lamps, plants, crash site | `mars_map_gen.py` | `make map` | ~3 min, several GB RAM |
| the loose props the multitool works on, dead lamps | `props_gen.py` | `make props` | fast |
| the base interior, its rooms and machines | `interior_gen.py` | `make interior` | seconds |
| any sound | `sfx_gen.py` | `make sfx` | fast — see the `sound-pipeline` skill |

**Shared code.** `mars_map_gen.py` imports `astronaut_sprite_gen.py`; `props_gen.py` and
`interior_gen.py` import both. If you change an SDF primitive, the ray-marcher, a ramp, the
outline or `hole_shape`, **every** generator that imports it must be re-run and all of their
outputs checked. `make all` does the lot (slow). `make map` also re-runs props, because props
are placed from the map's data.

## 2. Make the change in the generator

- Model with the existing primitives (`Sphere`, `Ellipsoid`, `RoundBox`, `RoundCone`, `Torus`,
  `Disc`, plus the interior's `Cut` / `Either`) and render with `render_groups` / `render_sprite`.
  Do not import or hand-draw art, and do not invent a second way to draw things.
- Use an existing palette ramp (`A.RAMPS`, `T_RAMPS*`, `STRATA*`, `O_RAMPS`). A new ramp needs
  4 colours hue-shifted like the others (darks → violet, lights → warm), registration in the
  ramp dict, `EMISSIVE` only if it emits light, and a line in AGENTS.md §12.
- Scale new objects against the references in §7.1 (astronaut 44 px = 22 world units, path lamp
  ≈ astronaut, airlock ≈ 1.6×, `DOME_SCALE = 2.5`).
- Export every position a script needs into the JSON (door, lamp, LED, crack, emitter…).
  **Scripts must never hard-code a map pixel** (§4.1). If you add or rename a key, update every
  reader in `scripts/` in the same change.

## 3. Preview without replacing the game's assets

```bash
MAP_OUT=/tmp/try .venv/bin/python tools/mars_map_gen.py      # write the map elsewhere
BASE_DESIGN=v2 MAP_OUT=/tmp/try .venv/bin/python tools/mars_map_gen.py
```

`BASE_DESIGN` (`v1|hex|v2|v3`, default `v3`) and `TOOL_DESIGN` (`v1|v2`, default `v2`) keep
earlier approved designs alive. **Never delete an approved design** — add `v<n+1>`, leave the
default alone, and only switch the default once the owner approves (§10.1).

Running a non-default design with `MAP_OUT` unset **replaces the game's assets**.

## 4. Regenerate, re-import, look

```bash
make map && make import            # always re-import after regenerating
make check                         # both scenes headless, no errors or warnings
make shot ARGS="--spawn=-827,1440 --seconds=2"
```

Then **look at the screenshot**, at 1:1 and zoomed in, and say what you saw. A change that has
not been seen is not done. The `verify` skill has the full list of test hooks.

Also check the generator's own previews if it writes them:
`assets/maps/red_planet/preview/`, `assets/characters/astronaut/preview/`, `tools/*_viewer.html`.

## 5. Commit

Generator change and its regenerated outputs go in **one** commit, so the repo always matches
its tools. Generated PNG/JSON cannot be merged: on a conflict take either side, re-run the
generator on the merged code, commit the result. Say which generator you are on before you
start — one person at a time per generator.
