# Solar field

The approved Sunthread web study is now a world interaction beside the main base.
Three closed beacons feed Amber/Jade/Coral routes with 4/5/4 reflectors. Walk up
and use F/X to open or close a feed, or turn a mirror clockwise 22.5 degrees.
Q does not operate solar equipment; left shoulder retains hotbar cycling.
Walking, survival and the clock continue. The web study's
objective/navigation box is deliberately absent.

A single 54-unit conical receiver has triangular blue cells and a large local
three-channel bar. Its ground cable enters the main base's power conduit. All
three complete routes supply the interior reactor; the reactor must also have its
existing cracks and wiring repaired before `GameState.base_powered()` is true.
The engine room has small Amber/Jade/Coral wall lenses and plays the existing powered-machine
ambience only while running. Closing a feed removes that beam/output immediately.
Routing progress does not decay with the day/night cycle; sunlight visuals fade
with the existing DayNight daylight value. No new time-based power balance is added.

## Ownership

- `data/solar_field.json`: authored canonical world positions, bounds, hardware
  dimensions, cable, three channel identities and optical routes.
- `SolarOptics`: finite ray/plane and ray/cone intersections, reflection, bounds
  and cycle termination. No nodes, rendering, input or view state.
- `SolarFieldState`: feed/angle mutations and cached optical results, owned by
  `GameState.solar_field` through turns, airlocks and rescue.
- `SolarField`: proximity/input ownership, generated WorldProp equipment, optical
  meshes and the local bar. Its independent `Multitool.solar_suppressed` flag and
  release guard prevent overlapping jobs. Inventory retains modal priority and normal hotbar input.
  Prompts sit by the equipment's feet; local plates reuse SurvivalHUD's canvas-aware
  avoidance helper so dragging that HUD cannot hide solar controls or channel status.
- `SolarFieldFX`: generated mirror glints, crystal deployment, incoming sunlight funnels,
  receiver charge waves, crown light and completion pulse. View changes preserve animation
  phase. Re-entering an already powered field retains its charge without replaying completion.
- `SolarBeamVisuals`: shared world-space, depth-carrying mesh construction.
- `SolarPowerInput`: wall inlet lenses and engine sound, reading generated wall metadata.

Physical hits always stop at the cone. A hit earns a channel only after visiting
every assigned reflector, so neither an early hit nor another channel's mirror
can substitute for a missing reflector. Receiver radius derives from the actual
frustum section at beam height. The authored layout physically keeps every incomplete
path away from the receiver, including cross-channel bounces; completion gating is a
second guard. Mirror placements/mounts prevent the reported Amber, B3 and C2 shortcuts.

## Generated art and four views

The receiver occupies the former array clearing at (-880, 2070), with reflectors and
feeds around the existing red-dust terrain north of the base. Optical bounds never clear
landscape. `mars_map_gen.py` preserves the original terrain/random-placement rules, then
levels small equipment pads and the narrow authored Amber access path after plant placement.
Each color's reflectors cross several parts of the clearing, including behind the receiver;
equipment centers stay at least 80 units apart and clear of the receiver footprint.
All original forest instances
remain in the same positions, verified by four baseline fingerprints.

The Coral feed sits on the existing reachable mountain ledge at (-640, 2180), elevation
58.28. Its natural ground is retained. It sends sunlight down to C1; C1 has a fixed tilt
that reflects the descending beam horizontally into the remaining route. F still controls
yaw only. Fixed mounting offsets let mirror positions follow the landscape without limiting
the paths to a square grid; player rotation remains eight 22.5-degree steps. Finite mirror
rectangles and the capped receiver are intersected in 3D. Source elevation and mirror mount
math are shared with generated art; offset/tilted mirrors have one sheet per view to preserve
their actual orientation through camera turns.

`tools/solar_field_gen.py` uses the existing SDF renderer, camera and ramps for eight
mirror orientations with four reflection frames, and four feed directions with nine
crystal deployment frames. Sprite frame selection subtracts the current camera heading.
Inactive beacons have sealed metal lids. The lids open before a short faceted crystal rises
from its socket; shutting down conceals it again. Generated `feed_visual` metadata owns the
crystal offset, closed/open tip heights and emergence phase used by the sunlight funnels.
Receiver masks encode surface height, cell interiors and local depth; the shader animates
shine and energizing waves on the actual triangular cells. Each view's masks and indicator
are exported into `assets/maps/red_planet/solar_field.json`.
Its `stands` map exports level canonical approach points in the base spawn's walk component for capture and placement
verification, avoiding the receiver's footprint while retaining free approaches in play.
`solar_field_gen.py --stands-only` refreshes these anchors against the current walk grid
without rerendering equipment; a placement with no reachable approach fails generation.
The prior baked array remains available for art comparisons with `SOLAR_DESIGN=array`.
The earlier plate feed remains available with `SOLAR_FEED_DESIGN=shield`.

`interior_gen.py --solar-input-only` renders two physical inlet repeaters on opposite
diagonal power-room walls, exporting the standing wall's housing/lens sprite and anchors
for each view and repair variant. Cutaway walls do not leave floating panels. Three lenses
show connected channels independently of reactor repair; the engine hum remains at the
machine. No solar telemetry bar floats over the reactor.

Optics always run in view 0's world coordinates. MapTerrain projects beam endpoints
and equipment into the current view. Mesh vertex colors carry per-endpoint view
depth into `solar_beam.gdshader`, allowing the baked receiver and scenery to occlude
rays. Equipment reuses WorldProp's depth shader and y sorting. The camera's existing
relief swing includes mirror/feed billboards and the beams' actual height changes.

Use `make map` to regenerate map/props/solar together, `make solar` for equipment
changes alone, then `make import`. No generated PNG or JSON is hand edited.

## Verification

`make check` includes `tests/solar_field_test.tscn`: closed feeds, complete routes,
every B4 angle, bypass guards, real keyboard/gamepad controls, modal priority,
physical reach/blocking, four native camera turns and cross-scene engine power.
`tests/solar_route_search.gd` explores every physically reachable path with the actual
finite optics, retaining consistent angle domains for all thirteen mirrors. It branches
only at possible hits and rejects any receiver strike missing an assigned reflector,
covering all eight-angle combinations, cross-channel detours and revisited mirrors.
The test pads the cone by four world units to keep unfinished rays visibly clear of its edge.
Every failure returns a concrete orientation assignment replayed through `SolarOptics.trace`.
This is test-only search; it adds no work to normal play.
Native event tests flush each synthetic press/release and wait for both idle and physics
frames before moving to another target, so accumulated events stay on the intended target.
State-observer checks also wait for idle processing after physics, because a rendered
frame can contain several physics ticks before proximity and audio update.
For rendered evidence, run that scene without `--headless` and append
`-- --gallery=shots/solar --audio-debug`. It captures closed/open feeds, the solved
field through four native turns, and the engine before repair, online and losing input.
Crystal deployment/retraction, charge/loss, Q doing nothing, normal shoulder cycling and
individual wall-lens states are also checked. `--model-only` runs the fast optical suite.
The mountain route also checks the descending first segment and horizontal reflected path.

Overworld capture hooks, after `--`:

- `--solar-at="A SUN"` (also B SUN/C SUN/A1..C4): stand in interaction reach.
- `--solar-active`: open all feeds, retaining the starting mirror orientations.
- `--solar-solved`: open and align the three routes for verification captures.
- Existing `--turn=0..3`, `--time=12|22`, `--zoom=2|3`, `--capture`, `--seconds`
  and `--turn-right` exercise the same running game.

Normal play never applies these developer hooks and starts with all feeds closed.
