shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// One view of the map, stood up in 3D for the camera's turn (TurnOverlay). A grid of vertices is
// laid over part of the picture; each one is lifted to where its pixel is in the world, from the
// depth map: x from the column, depth from the depth map, height from the row. Seen through the
// game's own orthographic camera it lands exactly on its pixel; turn the camera and the picture
// turns as the world would. Where the grid would stretch across a gap (a cliff edge in front of
// far ground) the stretched part is cut out.
// Optional sunlight-free pixels remove baked shafts during nighttime interior swings too.
// Independent base/nursery masks retain facility window glow through the turn.
// Each view is drawn twice. The front copy, nudged towards the camera, keeps only its share of a
// dither that hands the screen from the view left to the view arrived at, a map pixel at a time.
// The back copy is whole and sits far behind both fronts: where the view whose turn it is has
// nothing (the ground its own cliffs hid), the other view shows there instead of the empty sky.

#include "res://shaders/day_night.gdshaderinc"

uniform sampler2D map_tex : filter_nearest;
uniform sampler2D depth_tex : filter_nearest;
uniform sampler2D light_tex : filter_nearest, hint_default_black;
uniform sampler2D sun_tex : filter_nearest, hint_default_black;
uniform sampler2D no_sun_tex : filter_nearest, hint_default_black;
uniform bool has_no_sun = false;
uniform sampler2D power_tex : filter_nearest, hint_default_black;
uniform vec4 power_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float power_indoor = 0.0;
uniform sampler2D power_nursery_tex : filter_nearest, hint_default_black;
uniform vec4 power_nursery_rect = vec4(0.0, 0.0, 1.0, 1.0);
// This view's textures hold only the window MapStream has in memory, not the whole picture:
// x, y where it starts in map pixels, z, w how big it is. Outside it there is nothing to draw.
uniform vec4 win = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 origin = vec2(0.0);       // the view's origin_px
uniform float upp = 0.433;             // world units per map px
uniform float dtp = 0.577;             // depth_to_px
uniform float ppu = 2.0;               // map px per world unit of height
uniform float depth_scale = 25.0;
uniform int heading = 0;               // the view's quarter turns
uniform vec2 view_center = vec2(0.0);
uniform vec4 rect = vec4(0.0, 0.0, 1.0, 1.0);   // the part of the picture laid out (map px)
uniform float dissolve = 0.0;          // how much of the screen the view arrived at has (0..1)
uniform bool first = true;             // the view left (else the view arrived at)
uniform bool front = true;             // the dithered copy in front (else the whole one behind)
uniform vec3 toward = vec3(0.0, 0.5, 0.866);   // towards the camera (Godot space)
uniform float block = 1.0;             // screen px per map px (the dither's grain)
uniform vec2 lamp_px = vec2(-99999.0); // the suit lamp, in this view's map px
uniform vec2 lamp_dir = vec2(1.0, 0.0);  // and the way it points, in this view
uniform bool linear_out = false;       // write linear colour (if the 3D output is sRGB-encoded)

varying vec2 px;
varying float yv;
varying float hole;

vec2 to_world(vec2 v) {
	vec2 d = v - view_center;
	if (heading == 1) {
		return vec2(-d.y, d.x) + view_center;
	} else if (heading == 2) {
		return -d + view_center;
	} else if (heading == 3) {
		return vec2(d.y, -d.x) + view_center;
	}
	return v;
}

float raw_depth(vec2 p) {
	ivec2 ip = ivec2(floor(p) - win.xy);
	if (any(lessThan(ip, ivec2(0))) || any(greaterThanEqual(ip, ivec2(win.zw)))) {
		return 65535.0;                        // past the window: the same as sky, so it is cut away
	}
	vec4 d = texelFetch(depth_tex, ip, 0);
	return round(d.r * 255.0) * 256.0 + round(d.g * 255.0);
}

void vertex() {
	px = rect.xy + UV * rect.zw;
	float raw = raw_depth(px);
	hole = raw > 65534.5 ? 1.0 : 0.0;                 // 65535: nothing there (the sky)
	yv = raw / depth_scale;
	float xv = (px.x - origin.x) * upp;
	float z = (origin.y - px.y) / ppu - dtp * yv;
	vec2 w = to_world(vec2(xv, yv));
	// The camera is orthographic, so a push along its axis moves nothing on screen, only behind:
	// the back copies sit far behind both fronts and can only ever fill a gap, never cover
	// anything (indoors each view cuts away different walls; one view's tall wall must not
	// stand in front of the other's room). Of the two, the view with more screen comes first.
	bool ahead = first == (dissolve < 0.5);
	float nudge = front ? 8.0 : (ahead ? -2000.0 : -4000.0);
	VERTEX = vec3(w.x, z, -w.y) + toward * nudge;      // world (X, Y, Z up) -> Godot
}

void fragment() {
	if (hole > 0.001) {
		discard;
	}
	float b = dn_bayer(floor(FRAGCOORD.xy / block));
	if (front && (first ? b < dissolve : b >= dissolve)) {
		discard;                               // the other view's share of the dither
	}
	float raw = raw_depth(px);
	if (raw > 65534.5 || abs(raw / depth_scale - yv) > (front ? 4.0 : 14.0)) {   // the back copy fills generously
		discard;                               // a stretched curtain across a gap
	}
	ivec2 ip = ivec2(floor(px) - win.xy);
	if (any(lessThan(ip, ivec2(0))) || any(greaterThanEqual(ip, ivec2(win.zw)))) {
		discard;                               // never clamp: that smears the window's edge pixels
	}
	vec3 c = texelFetch(map_tex, ip, 0).rgb;
	vec3 power = max(base_power_sample(px, power_tex, power_rect, power_indoor) * bp_active,
			base_power_sample(px, power_nursery_tex, power_nursery_rect, 0.0) * bp_nursery_active);
	c = base_power_emission(c, power.g);
	float own = texelFetch(light_tex, ip, 0).r * dn_power;
	float sun = texelFetch(sun_tex, ip, 0).r;
	vec3 day = map_daylight(c, texelFetch(no_sun_tex, ip, 0).rgb, sun, has_no_sun);
	float lamp = dn_lamp_shape(px, lamp_px, lamp_dir);
	vec3 ambient = mix(dn_sky(day), day, power.r);
	vec3 glow = (has_no_sun ? day : c) * (1.0 + 0.12 * dn_night);
	vec3 lit = mix(mix(ambient, day * DN_LAMP_TINT, lamp), glow, own);
	ALBEDO = linear_out ? pow(clamp(lit, 0.0, 1.0), vec3(2.2)) : clamp(lit, 0.0, 1.0);
}
