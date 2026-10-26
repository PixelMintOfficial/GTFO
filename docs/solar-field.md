# Solar field

The approved Sunthread web study is now a world interaction beside the main base.
Three closed hilltop beacons feed Amber/Jade/Coral routes with 3/3/4 reflectors
(three yellow, three blue/teal, four red). Walk up
and use F/X to open or close a feed, or turn a mirror clockwise 22.5 degrees.
Q does not operate solar equipment; left shoulder retains hotbar cycling.
Walking, survival and the clock continue. The web study's
objective/navigation box is deliberately absent.

A single 54-unit conical receiver has triangular blue cells and a large local
three-channel bar. Its ground cable enters the main base's power conduit. All
three complete routes supply the interior reactor. The reactor must also have its cracks
and wiring repaired before `GameState.base_powered()` is true. O2 repair is independent.
Full power immediately lights the main base indoors and outdoors, at every hour. The
O2-only reserve never lights the base. Day/night does not interrupt electrical output;
closing a solar feed removes facility lighting while O2 uses any remaining reserve.
`BasePower` supplies shared world-shader lighting from compact four-view masks exported
by `tools/base_power_gen.py` (`make base-power`, also part of `make map`). Their R channel
lights the existing shell, corridors and local ground spill; G adds teal glass emission
while preserving damage; B is the intact emission used by existing glass restoration
patches. Both emission channels add the same reflected window colour to nearby ground.
The pool fades evenly over 100 world units outside each footing and follows terrain height;
saved depth prevents it painting over foreground geometry. Completing all three storage glass
repairs restores the three storage/command exterior breaks; habitat and garage glass stay intact.
The masks follow the actual band geometry and saved depth, use map pixels rather
than streamed-window UVs, and travel with both views during camera swings. Inside, normal
room lighting and the existing emergency strips remain steady. The nursery uses the same
glass emission and ground spill in an independent compact crop: `power/catalog.json` keeps
base masks in `views` and nursery masks in `nursery_views`, each with `file` and map-pixel
`rect`. Both follow live rendering, streaming and camera swings; the surrounding forest
retains its normal night lighting outside the pool. The nursery's repaired console controls
its own indoor lighting and exterior glow independently; main-base mains loss affects base
lighting and O2 supply, while the nursery screen's local lighting circuit stays on.
The engine room has small Amber/Jade/Coral wall lenses and plays the existing powered-machine
ambience only while running. Closing a feed removes that beam/output immediately.
Routing progress does not decay with the day/night cycle; sunlight visuals fade
with the existing DayNight daylight value. No new time-based power balance is added.

## Ownership

- `data/solar_field.json`: authored canonical world positions, bounds, hardware
  dimensions, cable, three channel identities and optical routes.
- `SolarOptics`: finite ray/plane and ray/cone intersections, reflection, escape
  and cycle termination. No nodes, rendering, input or view state.
- `SolarWorldGeometry`: canonical terrain intersections using MapTerrain's bilinear
  ground heights. It solves each crossed grid cell's quadratic clearance rather than
  skipping thin ridges, and extends escaped light past all four maps plus their viewports.
- `SolarFieldState`: feed/angle mutations and cached optical results, owned by
  `GameState.solar_field` through turns, airlocks and rescue.
- `SolarField`: proximity/input ownership, generated WorldProp equipment, optical
  meshes and the local bar. Its independent `Multitool.solar_suppressed` flag and
  release guard prevent overlapping jobs. Inventory retains modal priority and normal hotbar input.
  Prompts sit by the equipment's feet; local plates reuse SurvivalHUD's canvas-aware
  avoidance helper so the fixed HUD cannot hide solar controls or channel status.
- `SolarFieldFX`: generated mirror glints, crystal deployment, incoming sunlight funnels,
  receiver charge waves, crown light and completion pulse. View changes preserve animation
  phase. Re-entering an already powered field retains its charge without replaying completion.
- `SolarBeamVisuals`: shared world-space, depth-carrying mesh construction.
- `SolarReflectorLight`: identical beam geometry replayed over a reflector, clipped by
  its generated silhouette and optical/body depth, within the prop's normal y sorting.
- `SolarPowerInput`: wall inlet lenses and engine sound, reading generated wall metadata.

Physical hits always stop at the cone. A hit earns a channel only after visiting
every assigned reflector, so neither an early hit nor another channel's mirror
can substitute for a missing reflector. Receiver radius derives from the actual
frustum section at beam height. The authored layout physically keeps every incomplete
path away from the receiver, including cross-channel bounces; completion gating is a
second guard. Placement checks cover all reachable orientations, including cross-channel bounces.

## Generated art and four views

The receiver occupies the former array clearing at (-715, 2015), farther right/down from
the previous site. Amber's feed sits on the capped western plateau at (-1130, 2000), height
54; Jade's feed sits on the right-hand hill at (-470, 1915), height 34; Coral's feed sits on
the upper cliff at (-715, 2410), height 60. Ten relays spread between hilltops and the
clearing, following shorter descending routes. Equipment centers stay at least 80 units
apart and clear of the receiver footprint. Optical bounds never clear landscape.

`mars_map_gen.py` retains the original terrain/random-placement stream, then shapes the
authored peak caps, flat plateau tops, equipment pads and graded access paths. Original
plants retain their X/Y, variants and phases and settle onto the new ground. Four placement
fingerprints verify the forest remains intact. `terrain.peak_caps` owns rectangular cap
regions; `terrain.plateaus` owns elliptical tops; each has a target height and blend width.
`access_paths.points` may include Z for a graded ramp; older X/Y points stay at ground level.

Routes declare `source_elevation` and a parallel `mirror_elevations` list. The source aims
at the first mirror's actual 3D center. Each mirror's fixed pitch and yaw offset derive
from the incoming and outgoing elevation changes. F still controls only yaw in eight
22.5-degree steps. Finite mirror rectangles and the capped receiver are intersected in
3D. Elevation and mounting math are shared with generated art; offset/tilted mirrors have
one sheet per view to preserve their actual orientation through camera turns.

`tools/solar_field_gen.py` uses the existing SDF renderer, camera and ramps for eight
mirror orientations with four reflection frames, and four feed directions with nine
crystal deployment frames. Terraced beacon sheets face the actual outgoing ray; generated
`yaw_offset` identifies the first row's world angle. Sprite frame selection subtracts the
current camera heading while retaining that mounting angle.
Each mirror sheet also exports `depth` (`file`, `frames`, `scale`, `offset`, `skin_depth_span`): eight
orientation frames aligned with the color sheet's size and anchor. RG16 stores local
surface depth as `(depth + 32) * 1024`, B encodes the visible face's gap to its finite
optical plane (normalized by `skin_depth_span = 32`) and A matches the sprite silhouette,
including its one-pixel outline. RG retains actual SDF depth on every part, including the
face. Only incident/reflected segments striking the camera-visible side can bridge the
skin gap; a back-side bounce cannot expose a buried vertex as a dot. Shine frames share
geometry and therefore share one depth frame.
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
The previous approved layout is retained in `data/solar_field_v1.json` with
`SOLAR_FIELD_LAYOUT=v1`; v2 is the default. Use the same layout for generation and runtime.

`interior_gen.py --solar-input-only` renders two physical inlet repeaters on opposite
diagonal power-room walls, exporting the standing wall's housing/lens sprite and anchors
for each view and repair variant. Cutaway walls do not leave floating panels. Three lenses
show connected channels independently of reactor repair; the engine hum remains at the
machine. No solar telemetry bar floats over the reactor.

Optics always run in view 0's world coordinates. MapTerrain projects beam endpoints
and equipment into the current view. Float mesh UV.x carries per-endpoint view
depth into `solar_beam.gdshader`, allowing the baked receiver and scenery to occlude
rays. Equipment reuses WorldProp's depth shader and y sorting. The camera's existing
relief swing includes mirror/feed billboards and the beams' actual height changes.
Using a float attribute avoids ArrayMesh's byte-packed color precision loss and retains
correct interpolation even when an escaped endpoint lies beyond the map's depth range.

On entering the overworld, `SolarFieldState.bind_world` supplies the terrain geometry
before evaluating routes. The first terrain hit stops the ray and its downstream
reflections; depth shading only handles foreground occlusion. An unblocked ray continues
off-screen instead of stopping at the puzzle's placement bounds or an arbitrary height.
Depth value 65535 is empty sky and cannot block light. Closed feeds still emit nothing.
A tiny terrain-following glint marks physical impacts, including stops on flat soil.
Cached routes describe their endpoint with `termination`: `closed`, `terrain`, `collector`,
`escape`, `cycle` or `bounce_limit`; only a complete assigned route energizes a channel.
Beam cores are 2.25 map pixels wide with a six-pixel low-opacity halo, and the camera
swing derives its cylinder radius from the same core width. Each reflector replays the
exact same geometry above its sprite, clipped to the full silhouette and depth.
Light in front appears on the face or post; light physically behind stays hidden. There
are no short overdraw patches, extra endpoints or changes of line direction at their edges.
These preserve the originating beam's color, deployment/daylight fade, terrain occlusion
and foreground actor order, including projected crossings that do not hit the mirror.
UV.y annotates the front-side incident/reflected segment pair per hit without changing
vertices, widths or endpoints. Other segments use the solid panel surface. Revisited
mirrors can therefore show a front-side hit while hiding a back-side hit in the same route.

All depth materials sample `MapTerrain.window` through `MapStream.bind`, including
reflector replays, terrain impacts, receiver effects and the cable. The scene refreshes
these bindings when a window moves as well as when the view turns. Pixel fixtures cover
nonzero window origins; the map streaming suite checks every world depth material after
spawn, movement, zoom and turns. Streamed neighboring views follow the astronaut's focus
at every zoom, preserving the solar branch's camera behavior.

Use `make map` to regenerate map/props/solar together, `make solar` for equipment
changes alone, then `make import`. No generated PNG or JSON is hand edited.

## Verification

`make check` includes `tests/solar_field_test.tscn`: closed feeds, complete routes,
every mirror angle, bypass guards, real keyboard/gamepad controls, modal priority,
physical reach/blocking, four native camera turns and cross-scene engine power.
`tests/solar_route_search.gd` explores every physically reachable path with the actual
finite optics, retaining consistent angle domains for all ten mirrors. It branches
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
Every solved segment is checked against the actual elevated mirror center and must not
climb. The live player walks all authored access ramps without jumping, and elevated
controls are checked against the baked terrain height. Solved beams must clear that terrain,
and each beacon's drawn outlet must face its actual optical ray through all four turns.

Overworld capture hooks, after `--`:

- `--solar-at="A SUN"` (also B SUN/C SUN/A1..C4): stand in interaction reach.
- `--solar-active`: open all feeds, retaining the starting mirror orientations.
- `--solar-solved`: open and align the three routes for verification captures.
- Existing `--turn=0..3`, `--time=12|22`, `--zoom=2|3`, `--capture`, `--seconds`
  and `--turn-right` exercise the same running game.

Normal play never applies these developer hooks and starts with all feeds closed.

`make check` also runs `tests/solar_beam_test.tscn`: all ten mirrors' individual yaw
settings, 64 seeded mixed configurations, exact reported terrain/cutoff fixtures and
narrow/grazing height-patch intersections and actual uploaded mesh-depth precision,
including distant/negative endpoints. Native runs compare reflector-face pixels in the
real world and exercise the production reflector layer in all 320 poses (ten mirrors,
eight settings, four views). Front/behind ray fixtures cross the face, collar and post;
every covered pixel must respect the hardware depth. Actual routes also check back-side
contacts for isolated face pixels, including the reported Jade dot. `--contact-probe`
runs that focused native reproduction alone. Empty sky and opaque-depth fixtures
exercise the actual shader. Append `-- --gallery=shots/beams --time=12|22` for four-view
Coral/Jade/Amber contacts, cliff impacts and escaping-ray evidence.
