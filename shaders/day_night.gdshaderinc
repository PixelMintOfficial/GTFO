// Day and night, shared by every shader that draws the world.
// DayNight (scripts/day_night.gd) sets these global uniforms every frame (declared in
// project.godot under [shader_globals]). Sunlit colours take the time of day: a warm morning,
// a clear noon, a golden evening, a blue night. Things that glow on their own are kept out of
// it by the shaders that know about them (the map's light mask, the plants' glow row).

global uniform vec3 dn_mul;      // the daylight's colour: multiplies everything the sun lights
global uniform vec3 dn_add;      // sky light lifting the shadows a little
global uniform float dn_sat;     // colour saturation (the night greys things out a little)
global uniform float dn_night;   // 0 by day .. 1 in the deep of night
global uniform vec4 dn_lamp;     // the astronaut's light: map px x, y, radius (px across), strength

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

// How much of the astronaut's light reaches a map pixel: a pool flattened like the ground,
// in three dithered steps so it stays pixel art.
float dn_lamp_at(vec2 map_px) {
	if (dn_lamp.w <= 0.0) {
		return 0.0;
	}
	vec2 p = floor(map_px) + 0.5;
	vec2 q = (p - dn_lamp.xy) / vec2(dn_lamp.z, dn_lamp.z * 0.55);
	float f = clamp(1.0 - dot(q, q), 0.0, 1.0);
	return floor(f * f * 3.0 + dn_bayer(p) * 0.95) / 3.0 * dn_lamp.w;
}

// A sunlit colour at a map pixel, at this time of day (with the astronaut's light on it).
vec3 day_night(vec3 c, vec2 map_px) {
	return mix(dn_sky(c), c * vec3(1.0, 0.95, 0.86), dn_lamp_at(map_px));
}
