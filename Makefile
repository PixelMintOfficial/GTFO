# GTFO — one entry point for the pipeline (see AGENTS.md).
#
# Everything generated lives in assets/ and is written by a tool in tools/. Never edit a
# generated file by hand: change the generator and run its target here.
#
#   make env            build .venv with the generators' Python packages (uv)
#   make sources        download + checksum the open-licence recordings (~100 MB, once)
#   make sfx            regenerate all sound     (fast; needs make sources first)
#   make props          regenerate the test props (fast, needs the map's data)
#   make interior       regenerate the base interior (seconds)
#   make astronaut      regenerate the astronaut + SpriteFrames (slow, ~1000 frames)
#   make map            regenerate the overworld (~3 min, several GB of RAM)
#   make import         re-import assets into Godot (always after a regeneration)
#   make check          both scenes + the test suites; fails on any error or warning
#   make shot           screenshot a scene: make shot ARGS="--spawn=-827,1440"
#   make sounds         open assets/audio/viewer.html to listen to every sound
#   make verify         import + check (what "done" needs, minus looking at it)
#
# Override the tools if yours are named differently:
#   make check GODOT=godot4

GODOT ?= godot
PY    ?= .venv/bin/python
UV    ?= uv
SHOTS ?= shots
SCENE ?= res://scenes/overworld.tscn

.PHONY: help env sources sfx props interior astronaut astronaut-quick map all import check \
        check-overworld check-interior check-tests shot sounds verify clean-shots

help:
	@sed -n '2,/^$$/p' $(MAKEFILE_LIST) | sed 's/^# \{0,1\}//'

# ---------------------------------------------------------------- the Python environment
env:
	$(UV) venv .venv
	$(UV) pip install --python $(PY) -r tools/requirements.txt
	$(PY) -c "import numpy, PIL, scipy; print('generators ready')"

$(PY):
	@echo "No .venv yet — run: make env" >&2; exit 1

# ---------------------------------------------------------------- generators
# Each target writes only its own folder under assets/, so they never fight.
# The recordings behind the sampled layer. Git-ignored (they are large, and they are other
# people's work): the repo keeps the baked wav, not the raw packs. Checksums are verified.
sources: $(PY)
	$(PY) tools/sfx_gen.py --fetch

sfx: $(PY)
	$(PY) tools/sfx_gen.py

props: $(PY)
	$(PY) tools/props_gen.py

interior: $(PY)
	$(PY) tools/interior_gen.py

astronaut: $(PY)
	$(PY) tools/astronaut_sprite_gen.py
	$(PY) tools/godot_spriteframes.py

astronaut-quick: $(PY)
	$(PY) tools/astronaut_sprite_gen.py --quick

# The overworld. props depends on the map's data, so it always follows.
map: $(PY)
	$(PY) tools/mars_map_gen.py
	$(PY) tools/props_gen.py

all: astronaut map interior sfx import

# ---------------------------------------------------------------- Godot
import:
	$(GODOT) --headless --path . --import

# Headless runs print errors and warnings to stderr; any of either fails the check.
check: check-overworld check-interior check-tests

# --quit=S (not --quit-after) lets the scene shut the sound down before it quits: a playback
# still running at teardown is reported as leaked. --quit-after counts FRAMES, and a headless
# frame can take under a millisecond, so it is only a backstop for a scene that hangs - it is
# set high enough that it can never win the race and quit behind the scene's back.
check-overworld:
	@echo "== overworld"
	@$(GODOT) --headless --path . res://scenes/overworld.tscn --quit-after 20000 -- --no-intro --quit=4 \
		2>&1 | tee /tmp/gtfo-overworld.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|SCRIPT ERROR|WARNING|Parse Error' /tmp/gtfo-overworld.log \
		|| { echo "overworld: errors above" >&2; exit 1; }

check-interior:
	@echo "== interior"
	@$(GODOT) --headless --path . res://scenes/interior.tscn --quit-after 20000 -- --quit=4 \
		2>&1 | tee /tmp/gtfo-interior.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|SCRIPT ERROR|WARNING|Parse Error' /tmp/gtfo-interior.log \
		|| { echo "interior: errors above" >&2; exit 1; }

# The regression suites: the inventory's real input events, the circuit repair model over a
# thousand shuffled boards, the camera's turn, and the cargo box under storage's smashed panes.
# They report their own pass/fail and exit nonzero.
check-tests:
	@echo "== tests"
	@$(GODOT) --headless --path . res://tests/survival_test.tscn 2>&1 | tee /tmp/gtfo-survival.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-survival.log
	@$(GODOT) --headless --path . res://tests/survival_hud_test.tscn 2>&1 | tee /tmp/gtfo-hud.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/survival_hud_test.tscn -- --save-layout-probe 2>&1 | tee -a /tmp/gtfo-hud.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/survival_hud_test.tscn -- --load-layout-probe 2>&1 | tee -a /tmp/gtfo-hud.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-hud.log
	@$(GODOT) --headless --path . res://tests/inventory_test.tscn 2>&1 | tee /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/repair_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/view_turn_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/window_crack_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|SCRIPT ERROR|WARNING|Parse Error|[1-9][0-9]* failures' /tmp/gtfo-tests.log \
		|| { echo "tests: failures above" >&2; exit 1; }

verify: import check

# Screenshot a scene. The hooks are listed in the headers of overworld.gd / interior.gd:
#   make shot ARGS="--spawn=-827,1440 --equip --use --seconds=2"
#   make shot SCENE=res://scenes/interior.tscn ARGS="--arrive"
shot:
	@mkdir -p $(SHOTS)
	$(GODOT) --path . $(SCENE) -- --capture=$(SHOTS)/shot.png $(ARGS)
	@echo "wrote $(SHOTS)/shot.png"

# ---------------------------------------------------------------- sound
# There is no screenshot for sound: listen to it. The viewer plays every generated
# sound and draws its waveform.
sounds:
	@echo "open file://$(CURDIR)/assets/audio/viewer.html"
	@command -v xdg-open >/dev/null && xdg-open assets/audio/viewer.html >/dev/null 2>&1 || true

clean-shots:
	rm -rf $(SHOTS)
