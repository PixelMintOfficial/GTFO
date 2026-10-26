class_name ReserveMeter
extends Node2D
## The physical O2-room side-wall reserve gauge. Native generated housing/readout metadata
## follows the standing wall in every view and repair variant, like SolarPowerInput.
## Its own O2 reserve powers the bars; before repair/after mains the readout is dark.
const ART := "res://assets/maps/base_interior"
const DISPLAY := preload("res://shaders/solar_indicator.gdshader")
var housing: Sprite2D
var readout: Sprite2D
var _terrain: MapTerrain

func setup(meta: Dictionary, terrain: MapTerrain) -> void:
	_terrain = terrain
	get_parent().move_child(self, get_parent().get_node("Map").get_index()+1)
	housing = Sprite2D.new()
	readout = Sprite2D.new()
	for sprite in [housing, readout]:
		sprite.centered = false
		var material := ShaderMaterial.new()
		material.shader = DISPLAY if sprite == readout else WorldProp.SHADER
		sprite.material = material
		add_child(sprite)
	readout.set_meta("dn_unlit", true)
	load_view(meta)

func load_view(meta: Dictionary) -> void:
	var panel: Dictionary = meta["reserve_meter"]
	housing.texture = load(ART.path_join(panel["housing"]))
	readout.texture = load(ART.path_join(panel["levels"]))
	readout.hframes = int(panel["frames"])
	for sprite in [housing,readout]:
		sprite.position = Vector2(panel["position"][0],panel["position"][1])
		var material := sprite.material as ShaderMaterial
		MapStream.bind(material,_terrain)
		material.set_shader_parameter("depth_scale",_terrain.depth_scale)
		material.set_shader_parameter("sprite_depth",_terrain.view_depth(Vector2(panel["world"][0],panel["world"][1])))
		material.set_shader_parameter("tolerance",10.)
	_process(0.)

func _process(_delta: float) -> void:
	var air := GameState.facility_air
	readout.visible = air.status() in ["reserve","empty"]
	readout.frame = clampi(ceili(air.reserve_fraction()*10.),0,10)
