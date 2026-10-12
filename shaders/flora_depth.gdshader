shader_type canvas_item;

// Swaying plant sprites over the pre-rendered map.
// Each sheet holds its colour frames on top and the same frames' depth below it: grey
// (d + 64) * 2, where d is the world Y of that pixel relative to the plant's foot. The draw
// call's colour carries the plant's own depth (world Y * 16, high byte in R, low in G).
// Wherever the map has scenery nearer than the plant (a cliff, a rock, a prop), that part of
// the plant is hidden. Map pixels tagged as plants (blue 96) are left to the drawing order.
// Plants standing in front of the astronaut thin out (a dithered screen door) around them.
// The depth rows' green marks the parts that glow on their own: they stay lit at night.

#include "res://shaders/day_night.gdshaderinc"

uniform sampler2D depth_map : filter_nearest, repeat_disable;
// The depth map only holds the part of the view that is in memory (MapStream): x, y where that
// window starts in map pixels, z, w how big it is. A pixel outside it is treated as sky, so a
// sprite there draws whole rather than being wrongly hidden.
uniform vec4 map_win = vec4(0.0, 0.0, 1.0, 1.0);
uniform float depth_scale = 25.0;
uniform float tolerance = 2.0;
uniform vec2 player_px = vec2(-99999.0);   // the astronaut's feet, map px
uniform float player_depth = 0.0;          // and their world Y
uniform vec2 fade_radius = vec2(24.0, 30.0);

varying vec2 map_pos;
varying flat vec4 inst;

float bayer4(vec2 p) {
	const float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
	                              3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	ivec2 q = ivec2(mod(floor(p), 4.0));
	return (m[q.x + q.y * 4] + 0.5) / 16.0;
}

void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	inst = COLOR;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a < 0.5) {
		discard;
	}
	vec4 under = texture(TEXTURE, UV + vec2(0.0, 0.5));
	float rel = under.r * 255.0 / 2.0 - 64.0;
	float base = (round(inst.r * 255.0) * 256.0 + round(inst.g * 255.0)) / 16.0;
	ivec2 dp = ivec2(floor(map_pos) - map_win.xy);
	bool inside = all(greaterThanEqual(dp, ivec2(0))) && all(lessThan(dp, ivec2(map_win.zw)));
	vec4 d = inside ? texelFetch(depth_map, dp, 0) : vec4(1.0, 1.0, 0.0, 1.0);
	float scene = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	bool plant = abs(d.b * 255.0 - 96.0) < 12.0;
	if (inside && !plant && scene < base + rel - tolerance) {
		discard;
	}
	vec2 q = (floor(map_pos) + 0.5 - (player_px - vec2(0.0, 20.0))) / fade_radius;
	float r2 = dot(q, q);
	if (r2 < 1.0 && base < player_depth - 1.0 && bayer4(floor(map_pos)) < 0.7 * smoothstep(1.0, 0.55, r2)) {
		discard;
	}
	vec3 lit = under.g > 0.5 ? c.rgb * (1.0 + 0.15 * dn_night) : day_night(c.rgb, map_pos);
	COLOR = vec4(lit, 1.0);
}
