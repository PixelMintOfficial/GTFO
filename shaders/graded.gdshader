shader_type canvas_item;

// Anything in the world that the sun lights (smoke, dust, gas, snow, the door, the dome's
// moving parts...) takes the time of day. DayNight gives this material to every world node
// that has none of its own; lights and glows keep theirs and stay bright.

#include "res://shaders/day_night.gdshaderinc"

varying vec2 map_pos;

void vertex() {
	map_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	COLOR = vec4(day_night(c.rgb, map_pos), c.a);
}
