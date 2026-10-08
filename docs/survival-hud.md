# Radial survival HUD review

Branch: `feature/survival-status`, continuing the existing survival feature, submitted through
a pull request for review. Not merged. This follow-up changes presentation and HUD placement
preferences only. All pre-existing gameplay changes remain intact.

## Design and bindings

One 138x34 logical-pixel rounded dark parent panel defaults to the top-right with a 6-pixel
margin. Four separate 30x30 SurvivalMeter children retain fixed horizontal spacing: heart
(red/pink), lungs (cyan), drumstick (amber), droplet (blue). Pixel-rasterized rings have twelve
segments, visible dark inactive segments, a recessed face and discrete cel-shaded edges.
Numbers use PixelFont at scale 1; the subdued `/100` uses a half-sized, hard-edged UI pixel grid.
Thin 2.5-pixel rings also use that finer grid, retaining all twelve discrete segments.
No external image, blur,
antialiasing or smooth gradient is used. The reference sheet guided composition and colors.

Every meter reads `GameState.survival.values[kind]` and `maximum(kind)` directly. The existing
`changed` signal redraws all meters immediately. The displayed percentage is
`clamp(round(current / maximum * 100), 0, 100)`; invalid/zero maxima safely display 0.
The same integer percentage drives `round(percentage * 12 / 100)` active segments:
0/25/50/75/100 displays 0/3/6/9/12 active segments. Other values round to the nearest segment.
Inactive geometry remains visible at every value, including zero. Filling starts at noon
and proceeds clockwise. There is no delayed ring animation that could contradict the number.

Room/day announcements move below the panel only when intersecting it. Backpack/map/repair
modals hide the panel and disable drag/reset input; existing modal controls remain untouched.
The death overlay remains above all UI and retains its existing rescue behavior.

## Dragging, reset and persistence

- Hold **left mouse** on the six-dot grip on the panel's left side and move the mouse.
  Only that grip starts a drag; clicks on meters pass through without moving them.
- Release the button to save. All four meters move together, never independently.
- **Right-click the grip**, **Home**, or **gamepad left-stick click** resets to top-right
  and saves the default immediately. Grip hover shows a compact hint.
- Placement clamps the full container to the visible viewport with a margin. It uses the
  inventory's logical scaling while accounting for additional viewport area. Resize,
  aspect ratio and fullscreen transitions recompute the panel from normalized placement.
- Dragging does not pause gameplay, alter movement input or suppress the multitool. Modals,
  camera turns and focus loss stop an active drag safely.

There was no suitable settings system. The minimal `SurvivalHUDLayout` uses one ConfigFile:
`user://survival_hud.cfg`, section `layout`, key `position` (a Vector2 with components 0–1).
This stores relative available screen travel, rather than brittle absolute screen pixels.
Normal Windows location: `%APPDATA%\Godot\app_userdata\GTFO\survival_hud.cfg`.
Missing/invalid settings use the top-right default. Only release/reset/focus-loss cancellation
writes the file. No gameplay saving architecture or duplicate player state was introduced.

## Exact local launch and visual testing

PowerShell:

```powershell
Set-Location F:\PlayMint\GTFO
$godot = 'C:\Users\KT\.codex\visualizations\2026\10\07\01a1149e-a64a-7a51-bf4a-639f3f916204\godot\Godot_v4.7.2-stable_win64_console.exe'
& $godot --path .
# Reference values: display only; gameplay vitals stay unchanged.
& $godot --path . -- --no-intro --survival-debug --hud-preview=75,60,40,90
# Small window
& $godot --path . --resolution 384x216 -- --no-intro
# Unsafe oxygen room, night, another camera view
& $godot --path . res://scenes/interior.tscn -- --spawn=-236,492 --time=22 --turn=2
```

In explicit `--survival-debug` mode, **F11** cycles all four preview numbers through
0, 25, 50, 75 and 100. **F12** restores live values. Preview mode is labeled HUD PREVIEW
and affects only UI presentation; zero health in a preview never triggers death. Real gameplay
continues ticking normally beneath the preview. `--hud-preview=H,O,F,W` accepts individual
percentages. It is ignored in normal play and release exports. Existing F6–F10 and
`--vitals=H,O,F,W` controls still modify real vitals for mechanics testing, as before.

To inspect persistence manually: move the grip to the center, release, close the game,
launch again and check the location. Right-click the grip to reset; restart and check top-right.
Resize after dragging to every corner, then attempt to move past each edge. Click-and-drag
directly on a ring to confirm it does not move. Verify E/Start inventory, slot swaps, C/right
stick consumption, WASD movement, Shift sprinting, F interactions and G/H turns still work.

## Verification

```powershell
& $godot --headless --path . res://tests/survival_hud_test.tscn
& $godot --headless --path . res://tests/survival_hud_test.tscn -- --save-layout-probe
& $godot --headless --path . res://tests/survival_hud_test.tscn -- --load-layout-probe
& $godot --headless --path . res://tests/survival_test.tscn
& $godot --headless --path . res://tests/inventory_test.tscn
& $godot --headless --path . res://tests/repair_test.tscn
& $godot --headless --path . res://tests/view_turn_test.tscn
& $godot --headless --path . res://scenes/overworld.tscn -- --no-intro --quit=4
& $godot --headless --path . res://scenes/interior.tscn -- --quit=4
```

The HUD test uses dedicated preference files and never replaces the player's layout.
`make check` includes HUD tests and separate engine-process save/load/reset probes.
Since make is unavailable on this Windows machine, its Godot commands were run directly.
Sandbox runs set `$env:APPDATA = 'F:/PlayMint/GTFO/.godot/test-user'` to keep temporary user
data in the workspace. Normal local launches do not need that override.

Godot 4.7.2 results: 135 focused HUD checks; 48 survival; 98 inventory; 9677 repair;
283 camera-turn checks, all zero failures. Separate restart-persistence probes passed.
Both scenes run without errors/warnings. Graphical captures were inspected at 0,25,50,75,100,
mixed reference values, day/night and multiple views, at 384x216, 768x432, 1152x648,
1920x1080, and a 1024x768 backpack capture. Automated resize also covered 900x300.

Gameplay files were hashed before this refactor and remain identical: survival_state.gd,
survival.json, game_state.gd, player.gd, inventory_ui.gd, overworld.gd and interior.gd.
Health/damage/death, oxygen/recovery/consequences, hunger/thirst rates, sprint multipliers,
consumables, inventory, movement and controls retain the existing implementation and balance.

## Files in this HUD follow-up

Created:
- `scripts/survival_meter.gd` — one dial's rendering/normalization.
- `scripts/survival_hud_layout.gd` — minimal preference persistence.
- `tests/survival_hud_test.gd` and `.tscn` — input/layout/render-model/persistence tests.
- Script `.uid` files, and this guide.

Modified:
- `scripts/survival_hud.gd` — reusable parent, dragging, anchoring, binding and debug preview.
- `scripts/pixel_font.gd` — slash glyph for `/100`.
- `scripts/interior_fx.gd`, `scripts/day_clock.gd` — one presentation hook each for toast overlap.
- `Makefile` — focused UI/restart tests in the existing check target.
- `AGENTS.md`, `docs/survival.md` — current design, preference key and documentation.

Ignored graphical artifacts in `shots/`: `radial-reference.png`, `radial-0.png`,
`radial-25.png`, `radial-50.png`, `radial-75.png`, `radial-100.png`, `radial-night.png`,
`radial-small.png`, `radial-backpack.png`.
