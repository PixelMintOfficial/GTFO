shader_type canvas_item;
// Generated restored window pixels, revealed by their actual world height. Match the map's
// day/night and masks, so a scan can continue across closes without making glass emissive.
// Paired no_sun pixels remove nighttime rays; mains gate fixture light during a partial scan.
#include "res://shaders/day_night.gdshaderinc"
uniform sampler2D height_map : filter_nearest;
uniform sampler2D sun_mask : filter_nearest;
uniform sampler2D light_mask : filter_nearest;
uniform sampler2D no_sun_map : filter_nearest, hint_default_black;
uniform bool has_no_sun = false;
uniform vec2 map_size;
uniform vec2 map_position;
uniform vec2 patch_size;
uniform float scan = 0.0;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float height = texture(height_map, UV).r;
	vec2 p = map_position + UV * patch_size;
	// These masks belong to the pristine patch, not the former hole's room masks.
	float sun = texture(sun_mask, UV).r;
	float own = texture(light_mask, UV).r * dn_power;
	vec3 day = map_daylight(c.rgb, texture(no_sun_map, UV).rgb, sun, has_no_sun);
	vec3 glow = (has_no_sun ? day : c.rgb) * (1.0 + .12 * dn_night);
	COLOR = vec4(mix(day_night(day, p), glow, own), c.a * step(height, scan));
}
