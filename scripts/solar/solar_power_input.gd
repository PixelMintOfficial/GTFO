class_name SolarPowerInput
extends Node2D
## Physical solar inlet repeaters on opposite power-room walls. The interior generator
## exports the standing wall's SDF housing/lenses for all views and repair variants.
## Amber/Jade/Coral lenses indicate live channels. The machine sound stays at the engine.

const ART := "res://assets/maps/base_interior/"
const LENSES := preload("res://shaders/solar_indicator.gdshader")
var _anchor := Vector2.ZERO
var _engine := Vector2.ZERO
var _housing: Sprite2D
var _lights: Sprite2D
var _terrain: MapTerrain


func setup(meta: Dictionary, terrain: MapTerrain) -> void:
	_terrain = terrain
	get_parent().move_child(self, get_parent().get_node("Map").get_index() + 1)
	_housing = Sprite2D.new()
	_lights = Sprite2D.new()
	_housing.centered = false
	_lights.centered = false
	_lights.hframes = 8
	_lights.set_meta("dn_unlit", true)
	for sprite in [_housing, _lights]:
		var material := ShaderMaterial.new()
		material.shader = LENSES if sprite == _lights else WorldProp.SHADER
		sprite.material = material
		add_child(sprite)
	GameState.solar_field.changed.connect(_changed)
	load_view(meta)


func load_view(meta: Dictionary) -> void:
	var panel: Dictionary = meta["solar_input"]
	_anchor = SolarOptics.point(panel["anchor"])
	_housing.texture = load(ART.path_join(panel["housing"]))
	_lights.texture = load(ART.path_join(panel["lights"]))
	for sprite in [_housing, _lights]:
		sprite.position = SolarOptics.point(panel["position"])
		var material := sprite.material as ShaderMaterial
		material.set_shader_parameter("depth_map", _terrain.depth_map)
		material.set_shader_parameter("map_size", _terrain.map_size)
		material.set_shader_parameter("depth_scale", _terrain.depth_scale)
		material.set_shader_parameter("sprite_depth", _terrain.view_depth(SolarOptics.point(panel["world"])))
		material.set_shader_parameter("tolerance", 6.0)
	for machine in meta["repair_machines"]:
		if machine["id"] == GameState.solar_field.field["engine_room"]:
			_engine = SolarOptics.point(machine["progress_px"])
	_changed()


func _changed() -> void:
	var mask := 0
	for group in 3:
		if GameState.solar_field.routes[group]["connected"]:
			mask |= 1 << group
	_lights.frame = mask


func _process(_delta: float) -> void:
	if GameState.base_powered():
		Audio.loop("amb_dome", "solar:engine", _engine)
	else:
		Audio.release("solar:engine")


func _exit_tree() -> void:
	Audio.release("solar:engine")
