shader_type canvas_item;

// Loose things on the map (rocks, scrap, crates): hidden wherever the pre-rendered scenery is
// nearer than they are, seen tinted through dome glass. Like the astronaut, but they vanish
// behind a cliff instead of showing as a silhouette.

#include "res://shaders/day_night.gdshaderinc"

uniform sampler2D depth_map : filter_nearest, repeat_disable;
uniform vec2 map_size = vec2(1.0);
uniform float depth_scale = 25.0;
uniform float sprite_depth = 0.0;   // world Y of the thing's foot
uniform float tolerance = 6.0;      // its own depth, world units
uniform vec4 glass_tint : source_color = vec4(0.81, 0.94, 0.94, 1.0);

varying vec2 map_pos;

void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	c.rgb = day_night(c.rgb, map_pos);
	vec4 d = texture(depth_map, (floor(map_pos) + 0.5) / map_size);
	float depth = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	bool plant = abs(d.b * 255.0 - 96.0) < 12.0;
	if (!plant && depth < sprite_depth - tolerance) {
		if (d.b > 0.5) {
			c.rgb = mix(c.rgb, glass_tint.rgb, 0.35);
		} else {
			discard;
		}
	}
	COLOR = c;
}
