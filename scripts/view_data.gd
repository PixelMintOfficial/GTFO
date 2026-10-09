class_name ViewData
extends RefCounted
## The map JSONs, parsed once.
##
## Every system that draws at map pixels reads the current view's meta JSON, and most of them
## read its fx JSON too (§4.9). A camera turn calls all of their load_view()s in one frame, so
## the same files were being parsed six and four times over respectively - and the overworld's
## fx JSON is 350 KB, which is most of a turn's hitch. Parsing is pure: the same path always
## gives the same data, and no reader modifies what it gets back (checked), so one parse is
## enough for the life of the process.
##
## Hand the dictionaries out read-only. If you ever need to change one, copy it first -
## everyone else is holding the same reference.

static var _cache := {}
static var _parses := 0


## A JSON file's parsed contents, parsed on first ask.
static func get_json(path: String) -> Dictionary:
	if _cache.has(path):
		return _cache[path]
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("ViewData: could not read %s" % path)
		return {}
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("ViewData: %s is not a JSON object" % path)
		return {}
	_cache[path] = parsed
	_parses += 1
	return parsed


## A view's fx data. The overworld's `fx` names a file beside the meta (it is 350 KB of plants
## and glows); the interior's is small enough that the generator writes it inline. Both come
## back the same way.
static func fx_of(meta_path: String, meta: Dictionary) -> Dictionary:
	var fx = meta.get("fx")
	if fx is Dictionary:
		return fx
	if fx is String:
		return get_json(meta_path.get_base_dir().path_join(fx))
	return {}


## How many files have actually been parsed (the turn tests assert a turn adds none).
static func parse_count() -> int:
	return _parses
