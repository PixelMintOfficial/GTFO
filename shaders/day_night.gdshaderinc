// Day and night, shared by every shader that draws the world.
// DayNight (scripts/day_night.gd) sets these global uniforms every frame (declared in
// project.godot under [shader_globals]). Sunlit colours take the time of day: a warm morning,
// a clear noon, a golden evening, a night dark enough to need a lamp. Things that glow on
// their own are kept out of it by the shaders that know about them (the map's light mask, the
// plants' glow row). The lamp on the astronaut's suit (SuitLight) is the other two: it is not
// a light node, it is a shape these shaders lay on the ground.
// Interior map/scan/turn shaders share map_daylight to remove baked sunlight exactly at night.

global uniform vec3 dn_mul;      // the daylight's colour: multiplies everything the sun lights
global uniform vec3 dn_add;      // sky light lifting the shadows a little
global uniform float dn_sat;     // colour saturation (the night greys things out a little)
global uniform float dn_night;   // 0 by day .. 1 in the deep of night
// Full base lighting uses a cropped map-space mask (R illumination, G/B glass emission).
// G preserves damage; B is intact glass, used only on the existing restoration patches.
global uniform float bp_active;
global uniform float bp_indoor;
global uniform vec4 bp_rect;
global uniform sampler2D bp_mask : filter_nearest, hint_default_black;
global uniform vec4 dn_lamp;     // the suit lamp: map px x, y, how far it throws (px), strength
global uniform vec4 dn_beam;     // the way it points (x, y, in the flattened ground below), the
                                 // cosine of its half width, how much of the throw the spill
                                 // round the astronaut's feet fills

// How far the camera flattens the ground: a circle on it is this much shorter up the screen.
const float DN_GROUND = 0.55;
// The spill round the feet, as a share of the beam's own brightness.
const float DN_SPILL = 0.55;
// The colour the lamp puts back: a shade over full daylight, and warm, like every other light here.
const vec3 DN_LAMP_TINT = vec3(1.06, 1.00, 0.90);

float dn_bayer(vec2 p) {
	const float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
	                              3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	ivec2 q = ivec2(mod(floor(p), 4.0));
	return (m[q.x + q.y * 4] + 0.5) / 16.0;
}

// Sunlight, as the time of day colours it.
vec3 dn_sky(vec3 c) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	return mix(vec3(l), c, dn_sat) * dn_mul + dn_add;
}

vec3 map_daylight(vec3 c, vec3 no_sun, float sun, bool has_no_sun) {
	return has_no_sun ? mix(c, no_sun, dn_night) : c * (1.0 - 0.4 * sun * dn_night);
}

vec3 base_power_sample(vec2 p, sampler2D mask, vec4 rect, float indoor) {
	vec2 uv = (floor(p) + 0.5 - rect.xy) / rect.zw;
	if (indoor > 0.5) { return vec3(1.0, 0.0, 0.0); }
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) { return vec3(0.0); }
	return texture(mask, uv).rgb;
}

vec3 base_power_at(vec2 p) {
	if (bp_active < 0.5) { return vec3(0.0); }
	return base_power_sample(p, bp_mask, bp_rect, bp_indoor) * bp_active;
}

vec3 base_power_emission(vec3 c, float emission) {
	return c + vec3(0.38, 0.72, 0.60) * emission;
}

// How much of the suit lamp reaches a map pixel: a beam thrown along the ground the way the
// astronaut faces, with a small pool spilling round their feet, in three dithered steps so it
// stays pixel art. `at` is the lamp and `dir` the way it points, both in this view's map pixels
// (the camera's turn hands its own view's pair in; everything else takes dn_lamp / dn_beam).
float dn_lamp_shape(vec2 map_px, vec2 at, vec2 dir) {
	if (dn_lamp.w <= 0.0) {
		return 0.0;
	}
	vec2 p = floor(map_px) + 0.5;
	vec2 q = (p - at) / vec2(dn_lamp.z, dn_lamp.z * DN_GROUND);
	float r = length(q);
	if (r >= 1.0) {
		return 0.0;
	}
	float cone = clamp((dot(q, dir) / max(r, 0.001) - dn_beam.z) / (1.0 - dn_beam.z), 0.0, 1.0);
	float lit = max((1.0 - r * r) * sqrt(cone), DN_SPILL * (1.0 - min(r / max(dn_beam.w, 0.001), 1.0)));
	return floor(lit * 3.0 + dn_bayer(p) * 0.95) / 3.0 * dn_lamp.w;
}

float dn_lamp_at(vec2 map_px) {
	return dn_lamp_shape(map_px, dn_lamp.xy, dn_beam.xy);
}

// A sunlit colour at a map pixel, at this time of day, with at least `lamp` of the suit lamp on
// it: whoever carries the lamp is lit by it all over, not only where the beam crosses the ground.
vec3 day_night_lit(vec3 c, vec2 map_px, float lamp) {
	vec3 lit = mix(dn_sky(c), c, base_power_at(map_px).r);
	return mix(lit, c * DN_LAMP_TINT, max(dn_lamp_at(map_px), lamp));
}

// A sunlit colour at a map pixel, at this time of day (with the suit lamp on it).
vec3 day_night(vec3 c, vec2 map_px) {
	return day_night_lit(c, map_px, 0.0);
}
