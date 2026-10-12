shader_type canvas_item;
render_mode unshaded;
// Float UV.x carries ray depth; byte-packed colors would quantize it, and RG16
// clamping would distort interpolation for escaped endpoints beyond the map.
// Baked cone/cliffs occlude light; 65535 means sky. Optional generated reflector
// depth clips a replay of the identical mesh above its y-sorted hardware silhouette.
uniform sampler2D depth_map : filter_nearest, repeat_disable;
uniform vec2 map_size;
uniform float depth_scale = 20.0;
uniform vec4 beam_color : source_color;
uniform float daylight = 1.0;
uniform bool reflector_clip = false;
uniform sampler2D reflector_map : filter_nearest, repeat_disable;
uniform vec2 reflector_position;
uniform vec2 reflector_size;
uniform float reflector_frames = 8.0;
uniform float reflector_frame = 0.0;
uniform float reflector_scale = 1024.0;
uniform float reflector_offset = 32.0;
uniform float reflector_depth = 0.0;
varying vec2 map_pos;
varying float ray_depth;
void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	ray_depth = UV.x;
}
void fragment() {
	vec4 d = texture(depth_map, (floor(map_pos) + 0.5) / map_size);
	float encoded = round(d.r * 255.0) * 256.0 + round(d.g * 255.0);
	float depth = encoded / depth_scale;
	bool in_map = all(greaterThanEqual(map_pos, vec2(0.0))) && all(lessThan(map_pos, map_size));
	bool plant = abs(d.b * 255.0 - 96.0) < 12.0;
	if (in_map && encoded < 65534.5 && !plant && d.b < 0.5 && depth < ray_depth - 1.0) discard;
	if (reflector_clip) {
		vec2 local = floor(map_pos) + 0.5 - reflector_position;
		if (any(lessThan(local, vec2(0.0))) || any(greaterThanEqual(local, reflector_size))) discard;
		vec2 uv = vec2((local.x + reflector_frame * reflector_size.x) / (reflector_size.x * reflector_frames), local.y / reflector_size.y);
		vec4 surface = texture(reflector_map, uv);
		float body_depth = (round(surface.r * 255.0) * 256.0 + round(surface.g * 255.0)) / reflector_scale - reflector_offset + reflector_depth;
		// A sub-pixel tolerance accommodates the core's radius and snapped sprite anchor.
		if (surface.a < 0.5 || body_depth < ray_depth - 0.6) discard;
	}
	COLOR = vec4(beam_color.rgb, beam_color.a * daylight);
}
