shader_type canvas_item;
render_mode unshaded;
// Mesh vertex red carries canonical ray depth in this view, interpolated along each
// segment. Baked cone/cliffs therefore occlude the beam at their actual surfaces.
uniform sampler2D depth_map : filter_nearest, repeat_disable;
// The depth map holds only the part of the view that is in memory (MapStream): x, y where the
// window starts in map pixels, z, w how big it is. Outside it counts as sky, so nothing hides.
uniform vec4 map_win = vec4(0.0, 0.0, 1.0, 1.0);
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
	ivec2 dp = ivec2(floor(map_pos) - map_win.xy);
	bool inside = all(greaterThanEqual(dp, ivec2(0))) && all(lessThan(dp, ivec2(map_win.zw)));
	vec4 d = inside ? texelFetch(depth_map, dp, 0) : vec4(1.0, 1.0, 0.0, 1.0);
	float depth = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	bool plant = abs(d.b * 255.0 - 96.0) < 12.0;
	if (inside && !plant && d.b < 0.5 && depth < ray_depth - 1.0) discard;
	COLOR = vec4(beam_color.rgb, beam_color.a * daylight);
}
