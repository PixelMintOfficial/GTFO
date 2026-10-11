---
name: verify
description: "How to prove a GTFO change works: run both scenes headless for errors, drive the astronaut with the scenes' test hooks, capture and look at screenshots, check walkability, and hear the sound events. Use before reporting any change done, and when asked to test, check, run, screenshot, reproduce or debug the game. Triggers: definition of done, headless, --capture, --spawn, --walk, test hook, screenshot, audio-debug, no errors or warnings."
---

# Verifying a change in GTFO

`AGENTS.md` §8 defines done. This skill is how to get there. Never report a change as working
on the strength of reading the code: run it, capture it, and look at what came out.

## Definition of done

1. Both scenes run headless with **no errors and no warnings**.
2. You captured screenshots of what you changed and **looked at them**, at 1:1 and zoomed in.
3. Walk tests show the astronaut can reach everything they should and nothing else.
4. Sound events you added actually fire, and you listened to them (`sound-pipeline` skill).
5. Generator previews and viewers still look right, if your change wrote any.

## The commands

```bash
make import                  # after ANY regeneration, before running
make check                   # both scenes headless; fails on any error or warning
make verify                  # import + check
make shot ARGS="--spawn=-827,1440 --seconds=2"
make shot SCENE=res://scenes/interior.tscn ARGS="--arrive"
```

Raw form, when you need an option `make shot` does not pass:

```bash
godot --headless --path . res://scenes/overworld.tscn --quit-after 300 -- --no-intro
godot --path . res://scenes/overworld.tscn -- --spawn=-827,1440 --capture=shots/a.png --seconds=2
```

Everything after `--` goes to the scene. The authoritative lists are the header comments of
`scripts/overworld.gd` and `scripts/interior.gd` — read them, they grow.

| Hook | What it does |
|---|---|
| `--spawn=X,Y` | start at this world position (also skips the intro) |
| `--walk=DX,DY[,run]` | hold this stick direction (screen space, y down) |
| `--face=DX,DY` | turn to face a screen direction before working |
| `--capture=PATH` `--seconds=S` | save a PNG after S seconds (default 1.5), then quit |
| `--burst=N` `--gap=S` | save N frames, S apart; PATH gets `_0`, `_1`, … |
| `--equip` `--use` | take the multitool out; keep the use button held |
| `--door` | walk to the airlock and go in (the whole cutscene; the interior takes the shot) |
| `--intro` / `--no-intro` | force or skip the crash scene |
| `--zoom=L` `--open-map` `--debug` | zoom level; open the map screen; print position/height/depth |
| `--jump-every=S` | jump on a timer |
| `--audio-debug` | print every sound event as it plays (`[audio] name …`) |
| `--perf` `--perf-every=S` | texture memory, draw calls, mean/worst frame time once a second |
| `--stream-debug` | every map window as MapStream stitches it (§4.10) |
| `--turn-at=S` | when `--turn-left` / `--turn-right` fires (default 1 s) |
| `--turn=N` | start with the camera turned N quarter turns round (both scenes) |
| `--turn-left` / `--turn-right` | turn once after a second; burst-capture the swing |
| `--time=H` | the time of day (`--time=22` for night) |
| interior: `--arrive` `--exit` | play coming in through the door; use the door to leave |

## Reading the results

- **Errors**: `make check` greps the log for `ERROR`, `SCRIPT ERROR`, `WARNING` and
  `Parse Error`. A warning counts. Fix it, do not explain it away.
- **Screenshots**: open the PNG with the Read tool and describe what you see. The viewport is
  384×216 and pixel-snapped, so look for: half-pixel jitter, y-sort swaps (things drawing in
  front of what they should be behind), additive glow vanishing on the white interior walls,
  and anything that broke the 1 px `#22182c` outline.
- **Walkability**: `--walk` into the thing and see whether the astronaut stops, glides, skids
  or climbs. `--debug` prints ground height and map depth at the feet.
- **Views**: the camera turns (G / H), so check a visual change from more than one side
  (`--turn=1`, `--turn=2`), and run `res://tests/view_turn_test.tscn` if you touched anything
  that places things on the map.
- **Sound**: nothing is visible. Use `--audio-debug` to prove the triggers fire, then
  `make sounds` and listen. See the `sound-pipeline` skill.

## Capturing a cutscene or an animation

One frame is not enough for anything that moves. Take a burst and look at the sequence:

```bash
godot --path . res://scenes/overworld.tscn -- --spawn=-690,1340 --equip --use \
      --face=1,0 --capture=shots/mine.png --burst=8 --gap=0.2
```

## When it will not run

- Textures missing or stale → `make import` (the first import of the map is slow).
- `.godot/` is local and git-ignored; deleting it forces a full re-import.
- Do not kill a Godot editor the user has open, and do not run two generators that write the
  same folder at once.
