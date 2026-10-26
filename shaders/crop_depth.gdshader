shader_type canvas_item;
// Native crop pixels and their matching RG16 local view depth. B is biological
// emission. Samples the same streamed map window as the player/props, with glass
// tint and day/night/suit light, so high rack leaves are occluded at their real depth.
#include "res://shaders/day_night.gdshaderinc"
uniform sampler2D depth_map : filter_nearest, repeat_disable;
uniform sampler2D sprite_data : filter_nearest, repeat_disable;
uniform vec4 map_win = vec4(0.0, 0.0, 1.0, 1.0);
uniform float depth_scale = 20.0;
uniform float sprite_depth = 0.0;
uniform float local_depth_scale = 512.0;
uniform float depth_offset = 64.0;
varying vec2 map_pos;
void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}
void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	vec4 data = texture(sprite_data, UV);
	float local_depth = (round(data.r * 255.0) * 256.0 + round(data.g * 255.0)) / local_depth_scale - depth_offset;
	ivec2 pixel = ivec2(floor(map_pos) - map_win.xy);
	bool inside = all(greaterThanEqual(pixel, ivec2(0))) && all(lessThan(pixel, ivec2(map_win.zw)));
	vec4 d = inside ? texelFetch(depth_map, pixel, 0) : vec4(1.0, 1.0, 0.0, 1.0);
	float map_depth = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	c.rgb = mix(day_night(c.rgb, map_pos), c.rgb, data.b);
	if (inside && map_depth < sprite_depth + local_depth - 0.8) {
		if (d.b > 0.75) {
			c.rgb = mix(c.rgb, vec3(0.81, 0.94, 0.94), 0.35);
		} else {
			discard;
		}
	}
	COLOR = c;
}
