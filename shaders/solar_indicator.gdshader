shader_type canvas_item;
render_mode unshaded;
// SDF wall lenses retain their color at night; the housing is a separate graded sprite.
uniform sampler2D depth_map : filter_nearest, repeat_disable;
// The depth map holds only the part of the view that is in memory (MapStream): x, y where the
// window starts in map pixels, z, w how big it is. Outside it counts as sky, so nothing hides.
uniform vec4 map_win = vec4(0.0, 0.0, 1.0, 1.0);
uniform float depth_scale;
uniform float sprite_depth;
uniform float tolerance = 3.0;
varying vec2 map_pos;
void vertex() { map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy; }
void fragment() {
	ivec2 dp = ivec2(floor(map_pos) - map_win.xy);
	bool inside = all(greaterThanEqual(dp, ivec2(0))) && all(lessThan(dp, ivec2(map_win.zw)));
	vec4 d = inside ? texelFetch(depth_map, dp, 0) : vec4(1.0, 1.0, 0.0, 1.0);
	float depth = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	if (inside && depth < sprite_depth - tolerance && d.b < .5) discard;
	COLOR = texture(TEXTURE, UV) * COLOR;
}
