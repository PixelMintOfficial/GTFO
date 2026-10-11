shader_type canvas_item;

// Mended dome glass: the map generator's patch of a room's glass band as it was before the hole
// (red_planet_fx.json -> cracks -> patch), laid back over the map where the hole and its cracks
// were. Lit for the time of day exactly as map_light lights the glass round it (none of it is
// its own light), so the seam never shows.

#include "res://shaders/day_night.gdshaderinc"

varying vec2 map_pos;

void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a < 0.5) {
		discard;
	}
	COLOR = vec4(day_night(c.rgb, map_pos), 1.0);
}
