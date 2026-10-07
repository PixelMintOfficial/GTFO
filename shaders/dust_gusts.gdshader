shader_type canvas_item;

// Full-screen dust gusts. Two layers of stretched noise blow across the view; they are
// anchored to the world (not the screen), so they parallax with the camera. The result
// is quantised and Bayer-dithered so it stays pixel art at the game's resolution.

#include "res://shaders/day_night.gdshaderinc"

uniform sampler2D noise_tex : repeat_enable, filter_linear;
uniform vec2 view_origin = vec2(0.0);    // world position of the view's top-left pixel
uniform float view_scale = 1.0;          // world pixels per screen pixel (camera zoom-out)
uniform vec2 wind = vec2(34.0, 7.0);     // px per second
uniform vec4 dust_color : source_color = vec4(0.88, 0.62, 0.48, 1.0);
uniform float strength = 0.2;
uniform float coverage = 0.55;           // higher = more of the screen is dusty

varying vec2 local_px;

float bayer4(vec2 p) {
	const float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
	                              3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	ivec2 q = ivec2(mod(floor(p), 4.0));
	return (m[q.x + q.y * 4] + 0.5) / 16.0;
}

void vertex() {
	local_px = VERTEX;   // overlay pixels, top-left origin
}

void fragment() {
	vec2 screen_px = floor(local_px);
	vec2 px = floor(view_origin + screen_px * view_scale);
	vec2 a = (px - wind * TIME) * vec2(0.0016, 0.0042);
	vec2 b = (px - wind * TIME * 1.7) * vec2(0.0032, 0.009) + vec2(0.37, 0.71);
	float n = texture(noise_tex, a).r * 0.65 + texture(noise_tex, b).r * 0.35;
	float gust = smoothstep(1.0 - coverage, 1.0 - coverage + 0.32, n);
	float level = floor(gust * 3.0 + bayer4(screen_px) * 0.999) / 3.0;
	COLOR = vec4(dn_sky(dust_color.rgb), level * strength);
}
