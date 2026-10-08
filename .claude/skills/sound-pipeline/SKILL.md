---
name: sound-pipeline
description: "How to add, change, retune or debug any sound in GTFO: ambience beds for the three lands, footsteps, the multitool's beams, the airlock, the crash, UI ticks, positional emitters, buses and mixing. Use before editing tools/sfx_gen.py, scripts/audio.gd or anything that calls Audio.play/loop/bed, and whenever a sound is missing, too loud, clicking, not looping, or needs a new open-licence recording. Triggers: sfx, audio, ambience, sound effect, footstep, loop, bus, mix, gain, CC0, CC BY, attribution, audio.json, --audio-debug, sfx_gen."
---

# The GTFO sound pipeline

All sound is built by `tools/sfx_gen.py` into `assets/audio/`, and played by the `Audio`
autoload (`scripts/audio.gd`) from the `audio.json` it writes. **No sound is decided in
GDScript**: which file, which bus, how loud, how far it carries, how much its pitch wanders,
whether it loops — all of it is data. Retuning the mix is a generator change.

There is no music, by decision. The job is the environment and the feel of working in it.

## The two layers

| | What | Where it comes from |
|---|---|---|
| **recorded** | wind, snow underfoot, fire, water, stone, sheet metal, switches | open-licence packs in `assets/audio/sources/` (git-ignored), declared in `PACKS` |
| **synthesised** | the multitool's beams, the lens, lamps, crystal spires, beacons, UI | code in `sfx_gen.py` (`syn_*` functions) |

Alien tech is synthesised on purpose: a recording of Earth hardware sounds like Earth
hardware. Physical, natural things are recorded, because nothing synthesised beats real snow.
Both go through the **same mastering chain**, which is what makes them sit together.

## Adding or changing a sound

1. **Pick the source.** For something physical, look for a recording you already have:
   ```bash
   ls assets/audio/sources/                       # the packs (make sources to fetch them)
   .venv/bin/python tools/sfx_gen.py --probe 'assets/audio/sources/kenney_impacts/Audio/impact*.ogg'
   ```
   `--probe` prints duration, loudness, spectral centroid, low/mid/high split, onset rate,
   stationarity and flatness. **Use it.** It is how you tell a steady wind bed (low centroid,
   stationarity ~0.8, 0 onsets/s) from one full of birdsong (1–4 onsets/s in 2–8 kHz, which is
   wrong for this planet), without listening to 550 files. Put the numbers that decided it in
   the recipe's `note` — it ends up in `audio.json` for whoever changes it next.

2. **Write the recipe** in `RECIPES`. `take` is the recording (each glob match becomes a
   variant the game picks at random), `layer` mixes things under it, `synth` generates it,
   `chain` is the mastering:
   ```python
   'step_snow': dict(
       bus='sfx', gain_db=-10.0, dist=260.0, pitch=(0.95, 1.06),
       take=('oga_corsica_snow', '...gravel_0[1-6].flac'),
       chain=[trim(), hp(130), lp(9000), fade(0.003, 0.05), rms_to(-20.0), declick()],
       note='why this source, with the --probe numbers'),
   ```
   Ops available: `trim cut head delay pitch hp lp bp tilt gain norm rms_to fade env space
   loopify declick limit dc` (`delay` lands a layer at its moment inside the sound). Layers are
   mixed at their raw level, so put `rms_to` in a layer's chain to set it by number. Match loudness with `rms_to`, not `norm`: peak matching makes a
   transient-heavy footstep far quieter than a wind bed. Every sound gets a peak ceiling
   automatically, so a recipe cannot clip.

3. **Loops** need `loop=True` and `loopify(seconds, xfade)` in the chain, which crossfades the
   tail into the head. The generator writes the loop points into the WAV's `smpl` chunk, which
   Godot's importer reads, so no `.import` editing and no runtime guessing.
   Synthesised loops must be built from rates that divide the loop length — `loop_noise`,
   `loop_lfo` and `pulse_train` all guarantee this, which is why they exist.

4. **Regenerate, import, listen.**
   ```bash
   make sfx                        # or: --only step  to rebake just those
   make import
   make sounds                     # opens assets/audio/viewer.html
   ```
   The viewer plays every variant, draws its waveform, and applies the real gains and bus
   levels, so what is too loud there is too loud in the game. Looping sounds latch, so you can
   stack a land's bed with what lives in it.

## Playing a sound from GDScript

```gdscript
Audio.play("rock_burst", screen_px)            # one-shot, positional (map pixels)
Audio.play("ui_map_open")                      # one-shot, flat
Audio.loop("beam_mine", "beam:mine", tip_px)   # held; release("beam:mine") stops it
Audio.bed("amb_ice", weight)                   # ambience, crossfaded 0..1
```

Rules that keep it consistent:

- **Put the call where the event already is.** The thing that owns the state owns its sound:
  `interior_fx.gd` fires `spark` where it spawns the sparks; `dome_fx.gd` ticks the beacon in
  step with the strobe it draws; the rock's crack sound goes where its frame changes. Never
  add a second timer that re-derives when something happens — it will drift out of step.
- **Positions are map pixels** (the 2D listener is the active camera). Sounds further away
  than their `dist` are never started at all.
- **Loops are keyed**, and anything that starts one must release it on every exit path.
- Voices are limited (20 positional, 10 flat). When they run out the longest-running one is
  stolen rather than the new sound dropped, because a busy moment is exactly when the
  important sound would go missing. If something never fires, check it is not being stolen
  immediately by a burst of ticks.
- **Scene changes**: `Audio.enter_scene()` at the top of the scene's `_ready`, or a beam will
  follow the astronaut through the airlock.
- Footsteps come from the drawn gait (frame 0 and the middle frame of the walk/run cycle), not
  a timer, so they stay on the feet at any speed. The surface comes from `player.step_source`,
  which the scene sets — the overworld from the biome image, the interior from its floor.

## Verifying

Sound has no screenshot, so prove it two ways:

```bash
godot --headless --path . res://scenes/overworld.tscn --quit-after 4000 \
      -- --spawn=-638,1390 --equip --use --quit=7 --audio-debug
```
`--audio-debug` prints every event (`[audio] rock_crack at (…) pitch=1.10`), which shows the
trigger fired, in the right order, at the right place. Then `make sounds` and actually listen.

The existing test suites are the best audio check there is, because they drive real input
through every system:

```bash
godot --headless --path . res://tests/inventory_test.tscn -- --audio-debug \
  | grep '^\[audio\]' | sed 's/ at (.*//; s/ pitch=.*//' | sort | uniq -c | sort -rn
```
That one run exercises all four tool jobs, the airlock, the map, the backpack and the beds,
and the count per sound tells you what is firing far too often as well as what is silent.

Anything that ends the process must call **`Audio.quit(code)`** rather than
`get_tree().quit(code)`, so the sound is stopped first.

**`--quit=SECONDS`, not `--quit-after`.** Anything still playing when the engine tears down is
reported as a leaked playback: the mixer only drops a stopped playback when it next mixes, and
during shutdown there is no next mix. `--quit` awaits `Audio.quiet()`, which fades everything
out through the ordinary path and gives the mixer real time, so a check run stays clean.
`make check` does this. If you see `ObjectDB instances were leaked` plus
`resources still in use`, that is this, and something quit without going through `Audio.quiet()`.

## Licences — do not get this wrong

`PACKS` records every source's author, licence, URL and SHA-256. `make sources` downloads and
**verifies** them; a checksum mismatch stops the build, because a pack whose contents changed
is a pack whose licence you have not read.

`assets/audio/CREDITS.md` is generated from that table and lists the **CC BY** packs, which the
licence requires be credited wherever the game ships. It is not optional and it is not
decoration: if you add a CC BY source, the credit follows automatically, but the game still
has to show it. CC0 sources need no credit and are listed anyway.

Adding a source: find it, check the licence is CC0 or CC BY, add it to `PACKS` with its real
author and page, `make sources`, `--probe` it, then write the recipe.
