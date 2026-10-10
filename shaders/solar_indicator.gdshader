shader_type canvas_item;
render_mode unshaded;
// SDF wall lenses retain their color at night; the housing is a separate graded sprite.
uniform sampler2D depth_map : filter_nearest, repeat_disable;
uniform vec2 map_size;
uniform float depth_scale;
uniform float sprite_depth;
uniform float tolerance = 3.0;
varying vec2 map_pos;
void vertex() { map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy; }
void fragment() {
	vec4 d = texture(depth_map, (floor(map_pos) + .5) / map_size);
	float depth = (round(d.r * 255.0) * 256.0 + round(d.g * 255.0)) / depth_scale;
	if (depth < sprite_depth - tolerance && d.b < .5) discard;
	COLOR = texture(TEXTURE, UV) * COLOR;
}
