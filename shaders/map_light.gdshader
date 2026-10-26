shader_type canvas_item;

// The pre-rendered map, lit for the time of day. The light mask (from the map generator) says
// how much of each pixel is its own light: lamps, lit windows, glowing plants and pools, the
// light pooling round them, the stars. That part keeps its colour at night (and stands out a
// touch more against the dark). Indoors, the sun mask marks daylight coming in through the
// windows (shafts, sunlit patches); it fades away at night.
// BasePower adds geometry-matched glass emission and shared full-power illumination.
// An optional no_sun_map removes the actual baked daylight, avoiding dark shafts at night.

#include "res://shaders/day_night.gdshaderinc"

uniform sampler2D light_mask : hint_default_black;
uniform sampler2D sun_mask : hint_default_black;
uniform sampler2D no_sun_map : filter_nearest, hint_default_black;
uniform bool has_no_sun = false;

varying vec2 map_pos;

void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	c.rgb = base_power_emission(c.rgb, base_power_at(map_pos).g);
	float own = texture(light_mask, UV).r;
	float sun = texture(sun_mask, UV).r;
	vec3 day = map_daylight(c.rgb, texture(no_sun_map, UV).rgb, sun, has_no_sun);
	vec3 glow = (has_no_sun ? day : c.rgb) * (1.0 + 0.12 * dn_night);
	COLOR = vec4(mix(day_night(day, map_pos), glow, own), c.a);
}
