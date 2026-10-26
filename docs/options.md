# Pause and options

Escape opens options in the overworld, base and nursery. Escape or gamepad B resumes.
An 85%-opaque dark-grey overlay leaves 15% of the frozen game visible. Existing backpack,
map, repair, F1 and dialogue screens receive Escape first; cutscenes retain input ownership.
Share/Misc 1 also opens options on controllers that have that button; Start retains inventory.

The horizontal **Volume** slider controls the existing Master bus, including ambience,
effects and interface sounds. Zero mutes the bus. Individual authored bus levels and every
sound's generated mix remain unchanged. Drag/click the slider or use left/right while focused.

**GUI Scale** offers **Small**, **Medium** and **Large**. Small is the compact default; Large retains the original UI size.
Small and Medium shrink the day/night clock, stat panel, task checklist, O2 reserve counter, six-slot hotbar and E backpack.
The hotbar stays bottom-centred, the backpack stays centred, and the stat panel retains its
fixed top-left position. Mouse hitboxes use the same transforms as drawing. The options
screen keeps a fixed size so its controls remain stable while changing GUI size.

Target relative sizes are 60%, 80% and 100%, rounded to distinct whole display-pixel scales
when the window allows it. For a four-display-pixel UI grid these become 2/3/4 pixels.
At very small windows the targets are used directly. World projection and camera zoom do
not change. Keyboard arrows/d-pad navigate; Enter/A selects a size.

`GameState.settings` owns `GameSettings` across scenes. Changes apply immediately and save
on resume (or scene/window exit while options are open) to `user://settings.cfg`:
`audio.master_volume` (0–1) and `interface.gui_size`
(`small`, `medium`, `large`). Missing/invalid entries default to full volume and Small.
This is a preference file, separate from inventory and world progress.

`PauseMenu` owns tree pause while open and consumes input before world handlers. Its
independent `Multitool.options_suppressed` guard waits for F/X release after resuming.
Backpack, repair and dialogue ownership remain independent. No generated art is modified.

Verification: `tests/pause_menu_test.tscn` drives Escape, mouse and controller input, checks
simulation freeze, actual master-bus gain/mute, all three UI sizes and scaled hitboxes,
modal priority, scene continuity and restart persistence. Native captures use
`-- --gallery=shots/options`; separate `--save-options-probe` / `--load-options-probe`
processes verify disk persistence. Tests use files in `.godot`, not player preferences.
`--pause-menu` opens options after a second for scene captures. `--settings-path=PATH`
isolates preferences for regression runs.
