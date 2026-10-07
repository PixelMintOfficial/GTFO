#!/usr/bin/env bash
# Runs after an agent writes a file (PostToolUse). Two of this project's rules are easy to
# forget halfway through a task, so they are repeated here at the moment they are broken:
#
#   * assets/ is generated. Editing it by hand is pointless: the next generator run wipes it.
#   * The generators share code, so changing one can mean re-running several (AGENTS.md 6.2).
#
# Advisory only: it never blocks a write. Prints nothing for files it has nothing to say about.
set -uo pipefail

note() { jq -cn --arg c "$1" \
	'{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'; exit 0; }

command -v jq >/dev/null 2>&1 || exit 0
path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$path" ] || exit 0
rel=${path#"${CLAUDE_PROJECT_DIR:-$PWD}/"}

case "$rel" in
assets/*.png|assets/*.json|assets/*.tres|assets/*.wav)
	note "$rel is a GENERATED asset (AGENTS.md 1.2): hand edits are overwritten by the next
generator run. Change the tool in tools/ that writes it and regenerate (make help)." ;;
tools/astronaut_sprite_gen.py)
	note "tools/astronaut_sprite_gen.py holds the SDF primitives, ray-marcher and base palette
that mars_map_gen.py, props_gen.py and interior_gen.py all import. If you touched shared code,
re-run every generator and check all their outputs (AGENTS.md 6.2):
  make astronaut   (slow)   then  make map && make interior && make import" ;;
tools/mars_map_gen.py)
	note "tools/mars_map_gen.py is imported by props_gen.py and interior_gen.py.
  make map   (~3 min, also re-runs props)   then  make interior && make import" ;;
tools/props_gen.py)    note "Regenerate: make props && make import" ;;
tools/interior_gen.py) note "Regenerate: make interior && make import" ;;
tools/sfx_gen.py)      note "Regenerate: make sfx && make import — then listen: make sounds" ;;
tools/godot_spriteframes.py)
	note "Rewrite the SpriteFrames resource: .venv/bin/python tools/godot_spriteframes.py && make import" ;;
esac
exit 0
