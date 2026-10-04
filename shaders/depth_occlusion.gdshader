shader_type canvas_item;

// Hides the parts of a sprite that stand behind pre-rendered scenery.
// The map's depth image stores, for every map pixel, the camera depth (world Y) of the
// surface drawn there, packed into R (high byte) and G (low byte); B marks dome glass.
// Scenery nearer than the sprite turns the covered pixels into a soft silhouette,
// or a tinted see-through look when the scenery is glass.

uniform sampler2D depth_map : filter_nearest, repeat_disable;
uniform vec2 map_size = vec2(3100.0, 1880.0);
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
	vec4 d = texture(depth_map, map_pos / map_size);
	float depth = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	if (depth < sprite_depth - tolerance) {
		if (d.b > 0.5) {
			c.rgb = mix(c.rgb, glass_tint.rgb, 0.35);
			c.a *= 0.55;
		} else {
			c = vec4(silhouette.rgb, silhouette.a * c.a);
		}
	}
	COLOR = c;
}
