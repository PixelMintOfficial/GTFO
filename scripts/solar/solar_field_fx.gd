class_name SolarFieldFX
extends Node2D
## Solar presentation only: generated mirror sweeps, rising feed crystals, incoming sunlight
## funnels and the cone's energizing wave. No input or optical/state mutations live here.
## Deployment/charge phases survive view changes; entering a powered field does not replay
## completion. SDF receiver masks and all positions are regenerated for each of four views.
## Source sheets use generated yaw_offset so the beacon outlet faces its actual world ray.

const RECEIVER := preload("res://shaders/solar_receiver.gdshader")
const BEAM := preload("res://shaders/solar_beam.gdshader")
var deployment: Array[float] = []
var energy := 0.0
var startup := 10.0
var _clock := 0.0
var _powered := false
var _state: SolarFieldState
var _terrain: MapTerrain
var _art: Dictionary
var _equipment: Dictionary
var _receiver: Sprite2D
var _funnels: Array[MeshInstance2D] = []
var _crown: MeshInstance2D
var _pulse: MeshInstance2D

func setup(state: SolarFieldState, terrain: MapTerrain, art: Dictionary, equipment: Dictionary) -> void:
	_state = state
	_terrain = terrain
	_art = art
	_equipment = equipment
	set_meta("dn_unlit", true)
	_powered = state.supplies_power()
	energy = 1.0 if _powered else 0.0
	for feed in state.feeds:
		deployment.append(1.0 if feed else 0.0)
	_receiver = Sprite2D.new()
	_receiver.centered = false
	var material := ShaderMaterial.new()
	material.shader = RECEIVER
	_receiver.material = material
	add_child(_receiver)
	for group in 3:
		var funnel := MeshInstance2D.new()
		var shader := ShaderMaterial.new()
		shader.shader = BEAM
		shader.set_shader_parameter("beam_color", Color("#fbfbff", .38))
		funnel.material = shader
		add_child(funnel)
		_funnels.append(funnel)
	_crown = _energy_mesh(Color("#7fe6cf", .85))
	_pulse = _energy_mesh(Color("#7fe6cf", .45))
	load_view()

func _energy_mesh(color: Color) -> MeshInstance2D:
	var node := MeshInstance2D.new()
	var shader := ShaderMaterial.new()
	shader.shader = BEAM
	shader.set_shader_parameter("beam_color", color)
	node.material = shader
	add_child(node)
	return node

func load_view() -> void:
	var view: Dictionary = _art["views"][_terrain.heading]
	_receiver.texture = load("res://assets/maps/red_planet/".path_join(view["receiver_mask"]["file"]))
	_receiver.position = SolarOptics.point(view["receiver_mask"]["position"])
	var material := _receiver.material as ShaderMaterial
	material.set_shader_parameter("receiver_depth", _terrain.view_depth(SolarOptics.point(_state.field["collector"]["world"])))
	material.set_shader_parameter("radius", _state.field["collector"]["radius"])
	for node in [_receiver, _crown, _pulse] + _funnels:
		var shader := node.material as ShaderMaterial
		shader.set_shader_parameter("depth_map", _terrain.depth_map)
		shader.set_shader_parameter("map_size", _terrain.map_size)
		shader.set_shader_parameter("depth_scale", _terrain.depth_scale)
	_crown.mesh = SolarBeamVisuals.mesh(_terrain, _ring(float(_state.field["collector"]["top_radius"]) + .5, float(_state.field["collector"]["height"]) + 2), 2.0)
	refresh()

func _ring(radius: float, height: float) -> Array:
	var world := SolarOptics.point(_state.field["collector"]["world"])
	var segments := []
	for side in 40:
		var a := world + Vector2.from_angle(side * TAU / 40) * radius
		var b := world + Vector2.from_angle((side + 1) * TAU / 40) * radius
		segments.append([Vector3(a.x, a.y, height), Vector3(b.x, b.y, height)])
	return segments

func _process(delta: float) -> void:
	_clock += delta
	var powered := _state.supplies_power()
	if powered and not _powered:
		startup = 0.0
	_powered = powered
	startup += delta
	energy = move_toward(energy, 1.0 if powered else 0.0, delta * 1.6)
	for group in 3:
		deployment[group] = move_toward(deployment[group], 1.0 if _state.feeds[group] else 0.0, delta / .8)
	refresh()
	var material := _receiver.material as ShaderMaterial
	material.set_shader_parameter("clock", _clock)
	material.set_shader_parameter("daylight", DayNight.daylight)
	material.set_shader_parameter("energy", energy)
	material.set_shader_parameter("startup", startup)
	(_crown.material as ShaderMaterial).set_shader_parameter("daylight", energy * (.8 + .2 * sin(_clock * 2.0)))
	_pulse.visible = powered and startup < 2.5
	if _pulse.visible:
		_pulse.mesh = SolarBeamVisuals.mesh(_terrain, _ring(float(_state.field["collector"]["radius"]) + 3 + startup * 22, 2.5), 2.0)
		(_pulse.material as ShaderMaterial).set_shader_parameter("daylight", energy * (1.0 - startup / 2.5))
	for group in 3:
		var route: Dictionary = _state.field["routes"][group]
		var world := SolarOptics.point(route["source"])
		var direction := SolarOptics.point(route["direction"]).normalized()
		var visual: Dictionary = _art["feed_visual"]
		var local := SolarOptics.point(visual["crystal_offset"])
		var crystal := world + direction * local.x + direction.orthogonal() * local.y
		var growth := clampf((deployment[group] - float(visual["emerge"])) / (1.0 - float(visual["emerge"])), 0.0, 1.0)
		var height := lerpf(float(visual["tip_closed"]), float(visual["tip_open"]), growth) + float(route.get("source_elevation", 0.0))
		var tip := Vector3(crystal.x, crystal.y, height)
		var offset := _terrain.world_dir(Vector2(-28, -14))
		var side := _terrain.world_dir(Vector2(0, 9))
		var rays := []
		for lane in [-1, 0, 1]:
			var xy: Vector2 = crystal + offset + side * lane
			rays.append([Vector3(xy.x, xy.y, tip.z + 40), tip])
		_funnels[group].mesh = SolarBeamVisuals.mesh(_terrain, rays, 1.2)
		(_funnels[group].material as ShaderMaterial).set_shader_parameter("daylight", DayNight.daylight * smoothstep(.5, 1.0, deployment[group]))

func refresh() -> void:
	for id in _equipment:
		var entry: Dictionary = _equipment[id]
		var group: int = entry["group"]
		var sheets: Dictionary = _art["sheets"][_state.field["routes"][group]["id"]]
		var prop := entry["prop"] as WorldProp
		if entry["source"]:
			var direction := _terrain.view_dir(SolarOptics.point(_state.field["routes"][group]["direction"]))
			var quadrant := posmod(roundi((direction.angle() - float(sheets["source"].get("yaw_offset", 0.0))) / (PI / 2)), 4)
			var count: int = sheets["source"]["deploy_frames"]
			prop.sprite.frame = quadrant * count + roundi(deployment[group] * (count - 1))
		else:
			var count: int = sheets["mirror"]["shine_frames"]
			var phase := fposmod(_clock + entry["world"].x * .011, 4.0)
			var glint := clampi(ceili(phase * 5.0), 0, count - 1) if phase < .7 and DayNight.daylight > .05 else 0
			var orientation: int = _state.orientations[id] if _art.get("special_mirrors", {}).has(id) else posmod(int(_state.orientations[id]) - _terrain.heading * 4, 8)
			prop.sprite.frame = orientation * count + glint
