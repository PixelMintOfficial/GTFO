# Compact survival HUD

Four native radial meters stay fixed in the top-left corner. The 128×34 panel shares the
GUI preference scale with bottom-centred inventory, clock and checklist (Small by default,
with a 60% target snapped to the physical pixel grid). The clock sits below the stats; tasks sit below it. All use the
existing palette, PixelFont and meter geometry. No generated image assets were resized.

Mouse input cannot move the panel. There is no grip, drag/reset action or preference read;
old user://survival_hud.cfg files are ignored. Resize/aspect changes retain the same anchor.
Meter normalization, warning segments, C/right-stick consumption and developer previews
remain intact. Modals hide the stats; the rescue overlay fills the viewport.

The O2 reserve counter appears beside the clock only after full O2 repair while mains
are off. It shows reserve percent/segments or empty, plus AIR LEAK/AIR OK/NO O2. It disappears
on generator + solar mains. It follows the same compact scale and hides in modals. Supply changes also show brief notices above quick access; notices wait during paused
modals. Nursery player tasks replace base tasks indoors, with planting counts; UNIT's cleaning
stays off the checklist. See survival.md.

Run tests/survival_hud_test.tscn for fixed placement, resize, four live meter bindings,
UI-only previews and modal visibility. Inventory tests cover the scaled slot hitboxes.

The physical O2-room wall gauge uses native SDF art with contained RESERVES lettering and
charge segments. Clear wall repeaters are selected against the actual room depth in all four
views/repair variants. The display is reserve-powered; before repair/on mains its readout is
dark. `make reserve-meter` refreshes it without regenerating the room.

Escape opens the shared options. Small/Medium/Large resize the stats, clock, task list, reserve
counter and inventory together; Small is the default. Stats stay fixed at the top left for
every choice. The backpack stays centred and the hotbar stays bottom-centred, with matching
pointer hitboxes. Legacy saved HUD positions remain ignored.
