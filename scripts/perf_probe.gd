class_name PerfProbe
extends Node
## What the game costs, printed as it runs: texture memory, draw calls, frame times. There is no
## screenshot for memory, so this is how a change to it is proved, the way --audio-debug proves a
## sound fired.
##
## Both scenes add one when --perf is passed. It prints a line every `every` seconds:
##   [perf] t=4.0s fps=60 frame=16.7/17.9ms tex=944.2MB vram=947.1MB draws=118 objs=1631 static=61.4MB rss=1402.3MB
## `frame` is mean/worst since the last line: the worst is what a camera turn's hitch shows up in
## (issue #8), and `tex` is what the resident map views cost (issue #11).
##
## Test hooks (after "--"): --perf, --perf-every=SECONDS (default 1.0).

## How often a line is printed, seconds.
@export var every := 1.0

var _t := 0.0
var _since := 0.0
var _frames := 0
var _worst := 0.0
var _peak_tex := 0.0


## Start a probe if --perf was passed; returns it, or null.
static func attach(scene: Node, args: Dictionary) -> PerfProbe:
	if not args.has("perf"):
		return null
	var probe := PerfProbe.new()
	probe.every = float(args.get("perf-every", "1.0"))
	scene.add_child(probe)
	return probe


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS          # keep measuring while the map screen pauses
	print("[perf] %s, %d x %d window, %s" % [ProjectSettings.get_setting("application/config/name"),
			get_window().size.x, get_window().size.y, OS.get_name()])


func _process(delta: float) -> void:
	_t += delta
	_since += delta
	_frames += 1
	_worst = maxf(_worst, delta)
	_peak_tex = maxf(_peak_tex, _mb(Performance.RENDER_TEXTURE_MEM_USED))
	if _since < every:
		return
	print("[perf] t=%.1fs fps=%d frame=%.1f/%.1fms tex=%.1fMB vram=%.1fMB draws=%d objs=%d static=%.1fMB%s"
			% [_t, Engine.get_frames_per_second(), _since / _frames * 1000.0, _worst * 1000.0,
			_mb(Performance.RENDER_TEXTURE_MEM_USED), _mb(Performance.RENDER_VIDEO_MEM_USED),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			OS.get_static_memory_usage() / 1048576.0, _rss()])
	_since = 0.0
	_frames = 0
	_worst = 0.0


## The peak texture memory seen, for the one-line summary a test run ends with.
func report() -> void:
	print("[perf] peak tex=%.1fMB over %.1fs" % [_peak_tex, _t])


func _mb(monitor: int) -> float:
	return Performance.get_monitor(monitor) / 1048576.0


## This process's resident set, which is what "RAM usage" means to a player. Linux only; the
## engine has no portable call for it.
func _rss() -> String:
	if not FileAccess.file_exists("/proc/self/statm"):
		return ""
	var f := FileAccess.open("/proc/self/statm", FileAccess.READ)
	if f == null:
		return ""
	var fields := f.get_line().split(" ")
	if fields.size() < 2:
		return ""
	return " rss=%.1fMB" % (float(fields[1]) * 4096.0 / 1048576.0)
