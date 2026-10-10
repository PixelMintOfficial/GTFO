shader_type canvas_item;
render_mode unshaded;
// SDF-generated receiver mask: R height, G cell interior, B local view depth, A surface.
// Sweeping silver reflections follow daylight; connected cells retain their own energy.
uniform sampler2D depth_map : filter_nearest, repeat_disable;
uniform vec2 map_size;
uniform float depth_scale = 20.0;
uniform float receiver_depth;
uniform float radius = 62.0;
uniform float daylight = 1.0;
uniform float clock = 0.0;
uniform float energy = 0.0;
uniform float startup = 10.0;
varying vec2 map_pos;
void vertex() { map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy; }
void fragment() {
	vec4 mask = texture(TEXTURE, UV);
	vec4 depth_tex = texture(depth_map, (floor(map_pos) + .5) / map_size);
	float depth = (round(depth_tex.r * 255.0) * 256.0 + round(depth_tex.g * 255.0)) / depth_scale;
	float surface = receiver_depth + (mask.b * 2.0 - 1.0) * radius;
	if (depth < surface - 1.5 && depth_tex.b < .5) discard;
	float sheen = step(abs(fract(UV.x * .7 + mask.r * .3 - clock * .08) - .5), .018) * daylight;
	float rise = max(0.0, 1.0 - abs(mask.r - startup * .5) * 12.0) * step(startup, 2.4);
	float circuit = step(abs(fract(mask.r * 4.0 - clock * .35) - .5), .055);
	float charged = energy * (.14 + .15 * circuit + .65 * rise);
	vec3 color = mix(vec3(.49, .90, .81), vec3(.98, .98, 1.0), max(sheen, rise));
	COLOR = vec4(color, mask.a * mask.g * clamp(sheen * .48 + charged, 0.0, .9));
}
