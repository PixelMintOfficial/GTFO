shader_type canvas_item;

// Hides the parts of a sprite that stand behind pre-rendered scenery.
// The map's depth image stores, for every map pixel, the camera depth (world Y) of the
// surface drawn there, packed into R (high byte) and G (low byte); B marks dome glass.
// Scenery nearer than the sprite turns the covered pixels into a soft silhouette,
// or a tinted see-through look when the scenery is glass. Swaying plants (B = 96) never
// cover the sprite: they thin out around it instead (flora_depth.gdshader).

#include "res://shaders/day_night.gdshaderinc"

uniform sampler2D depth_map : filter_nearest, repeat_disable;
// The depth map only holds the part of the view that is in memory (MapStream): x, y where that
// window starts in map pixels, z, w how big it is. A pixel outside it is treated as sky, so a
// sprite there draws whole rather than being wrongly hidden.
uniform vec4 map_win = vec4(0.0, 0.0, 1.0, 1.0);
uniform float depth_scale = 25.0;
uniform float sprite_depth = 0.0;   // world Y of the sprite's feet
uniform float tolerance = 6.0;      // the sprite's own thickness, in world units
uniform vec4 silhouette : source_color = vec4(0.36, 0.30, 0.50, 0.55);
uniform vec4 glass_tint : source_color = vec4(0.81, 0.94, 0.94, 1.0);

varying vec2 map_pos;

void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	c.rgb = day_night(c.rgb, map_pos);
	ivec2 dp = ivec2(floor(map_pos) - map_win.xy);
	bool inside = all(greaterThanEqual(dp, ivec2(0))) && all(lessThan(dp, ivec2(map_win.zw)));
	vec4 d = inside ? texelFetch(depth_map, dp, 0) : vec4(1.0, 1.0, 0.0, 1.0);
	float depth = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	bool plant = abs(d.b * 255.0 - 96.0) < 12.0;
	if (inside && !plant && depth < sprite_depth - tolerance) {
		if (d.b > 0.5) {
			c.rgb = mix(c.rgb, glass_tint.rgb, 0.35);
			c.a *= 0.55;
		} else {
			c = vec4(silhouette.rgb, silhouette.a * c.a);
		}
	}
	COLOR = c;
}
