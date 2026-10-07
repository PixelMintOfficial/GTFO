shader_type canvas_item;

// The ground as it was before the satellite came down, laid over the map during the crash
// scene. Alpha holds when each pixel gets uncovered: (a * 255 - 1) / 254 is how far along the
// trench it lies (1 where the satellite touched down, 0 where it stopped; the wreck and its
// crater are 0). Everything the satellite has already passed is cut away, with a dithered edge.

#include "res://shaders/day_night.gdshaderinc"

uniform float front = 1.0;   // where the satellite is now, along the trench (1 -> 0; below 0 shows it all)

float bayer4(vec2 p) {
	const float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
	                              3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	ivec2 q = ivec2(mod(floor(p), 4.0));
	return (m[q.x + q.y * 4] + 0.5) / 16.0;
}

varying vec2 map_pos;

void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a < 0.5 / 255.0) {
		discard;
	}
	float r = (c.a * 255.0 - 1.0) / 254.0;
	if (r < 0.002) {
		// the wreck and its crater appear only at the impact
		if (front < 0.0) {
			discard;
		}
	} else if (r + (bayer4(FRAGCOORD.xy / 5.0) - 0.5) * 0.04 > front) {
		discard;
	}
	COLOR = vec4(day_night(c.rgb, map_pos), 1.0);
}
