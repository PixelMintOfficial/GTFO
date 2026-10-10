shader_type canvas_item;
render_mode unshaded;
// Mesh vertex red carries canonical ray depth in this view, interpolated along each
// segment. Baked cone/cliffs therefore occlude the beam at their actual surfaces.
uniform sampler2D depth_map : filter_nearest, repeat_disable;
uniform vec2 map_size;
uniform float depth_scale = 20.0;
uniform vec4 beam_color : source_color;
uniform float daylight = 1.0;
varying vec2 map_pos;
varying float ray_depth;
void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	ray_depth = COLOR.r * 4096.0;
}
void fragment() {
	vec4 d = texture(depth_map, (floor(map_pos) + 0.5) / map_size);
	float depth = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	bool plant = abs(d.b * 255.0 - 96.0) < 12.0;
	if (!plant && d.b < 0.5 && depth < ray_depth - 1.0) discard;
	COLOR = vec4(beam_color.rgb, beam_color.a * daylight);
}
