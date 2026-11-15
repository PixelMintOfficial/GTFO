# GTFO — one entry point for the pipeline (see AGENTS.md).
#
# Everything generated lives in assets/ and is written by a tool in tools/. Never edit a
# generated file by hand: change the generator and run its target here.
#
#   make env            build .venv with the generators' Python packages (uv)
#   make sources        download + checksum the open-licence recordings (~100 MB, once)
#   make sfx            regenerate all sound     (fast; needs make sources first)
#   make props          regenerate the test props (fast, needs the map's data)
#   make solar          regenerate solar mirror/feed sheets and four-view anchors
#   make base-power     regenerate four-view base/nursery lighting masks from map geometry
#   make interior       regenerate the base interior and its bot (about a minute)
#   make nursery        regenerate the nursery interior and overworld airlock routes
#   make nursery-metadata refresh nursery repair/scanner anchors without rendering
#   make nursery-cleanup regenerate removable native litter sheets
#   make reserve-meter  regenerate the physical O2 side-wall reserve meter
#   make dome-light     refresh opaque-dome light occlusion without rerendering the map
#   make cultivation    regenerate wild seed plants and inventory icons
#   make windows        regenerate only glass inspection assets
#   make astronaut      regenerate the astronaut + SpriteFrames (slow, ~1000 frames)
#   make map            regenerate the overworld (~35 min for four views, several GB of RAM)
#   make intro          regenerate the opening cutscene's art: cockpit, planet, ship (seconds)
#   make tiles          re-cut the map's tiles from the pictures on disk (fast)
#   make import         re-import assets into Godot (always after a regeneration)
#   make check          all rooms + the test suites; fails on any error or warning
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

.PHONY: help env sources sfx props solar base-power interior nursery cultivation windows astronaut astronaut-quick map intro tiles all import check \
        check-overworld check-interior check-nursery check-tests shot sounds verify clean-shots nursery-metadata nursery-cleanup dome-light reserve-meter

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

solar: $(PY)
	$(PY) tools/solar_field_gen.py

base-power: $(PY)
	$(PY) tools/base_power_gen.py
	$(PY) tests/test_base_power_art.py

interior: $(PY)
	$(PY) tools/interior_gen.py
	$(PY) tests/test_power_restore.py
	$(PY) tests/test_night_sunlight.py
	$(PY) tools/window_repair_gen.py
	$(PY) tools/bot_gen.py
	$(PY) tools/nursery_cleanup_gen.py

nursery: $(PY)
	$(PY) tools/nursery_gen.py
	$(PY) tools/nursery_cleanup_gen.py
	$(PY) tools/mars_map_gen.py --doors-only

nursery-metadata: $(PY)
	$(PY) tools/nursery_gen.py --repair-metadata-only

nursery-cleanup: $(PY)
	$(PY) tools/nursery_cleanup_gen.py

reserve-meter: $(PY)
	$(PY) tools/reserve_meter_gen.py

dome-light: $(PY)
	$(PY) tools/mars_map_gen.py --dome-light-only

cultivation: $(PY)
	$(PY) tools/cultivation_gen.py

windows: $(PY)
	$(PY) tools/window_repair_gen.py

astronaut: $(PY)
	$(PY) tools/astronaut_sprite_gen.py
	$(PY) tools/godot_spriteframes.py

astronaut-quick: $(PY)
	$(PY) tools/astronaut_sprite_gen.py --quick

# The overworld. props depends on the map's data, so it always follows.
map: $(PY)
	$(PY) tools/mars_map_gen.py
	$(PY) tools/intro_gen.py
	$(PY) tools/base_power_gen.py
	$(PY) tests/test_base_power_art.py
	$(PY) tools/props_gen.py
	$(PY) tools/solar_field_gen.py
	$(PY) tools/cultivation_gen.py
	$(PY) tools/check_solar_field.py

# The opening cutscene: the cockpit, Araxys from orbit and the ship (whose model is the wreck's,
# in mars_map_gen.py, so map runs this too).
intro: $(PY)
	$(PY) tools/intro_gen.py

# Tiling is a pure function of the pictures, so it does not need the planet rendered again.
tiles: $(PY)
	$(PY) tools/mars_map_gen.py --tiles-only

all: astronaut map interior nursery sfx import

# ---------------------------------------------------------------- Godot
import:
	$(GODOT) --headless --path . --import

# Headless runs print errors and warnings to stderr; any of either fails the check.
check: check-overworld check-interior check-nursery check-tests

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

check-nursery:
	$(PY) tools/check_nursery.py
	@$(GODOT) --headless --path . res://tests/nursery_test.tscn 2>&1 | tee /tmp/gtfo-nursery.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-nursery.log

# The regression suites: the inventory's real input events, the circuit repair model over a
# thousand shuffled boards, the camera's turn, the cargo box under storage's smashed panes, and the bot.
# They report their own pass/fail and exit nonzero.
check-tests:
	@echo "== tests"
	@$(GODOT) --headless --path . res://tests/pause_menu_test.tscn 2>&1 | tee /tmp/gtfo-options.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/pause_menu_test.tscn -- --save-options-probe 2>&1 | tee -a /tmp/gtfo-options.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/pause_menu_test.tscn -- --load-options-probe 2>&1 | tee -a /tmp/gtfo-options.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-options.log
	@$(GODOT) --headless --path . res://tests/base_power_test.tscn 2>&1 | tee /tmp/gtfo-base-power.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-base-power.log
	@$(GODOT) --headless --path . res://tests/nursery_power_test.tscn 2>&1 | tee /tmp/gtfo-nursery-power.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-nursery-power.log
	$(PY) tools/check_dome_light.py
	@$(GODOT) --headless --path . res://tests/facility_power_test.tscn 2>&1 | tee /tmp/gtfo-facility-power.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-facility-power.log
	@$(GODOT) --headless --path . res://tests/nursery_cleanup_test.tscn 2>&1 | tee /tmp/gtfo-cleanup.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-cleanup.log
	@$(GODOT) --headless --path . res://tests/facility_restoration_test.tscn 2>&1 | tee /tmp/gtfo-facilities.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-facilities.log
	@$(PY) tools/check_cultivation.py
	@$(GODOT) --headless --path . res://tests/cultivation_test.tscn 2>&1 | tee /tmp/gtfo-cultivation.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-cultivation.log
	@$(GODOT) --headless --path . res://tests/solar_field_test.tscn 2>&1 | tee /tmp/gtfo-solar.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-solar.log
	@$(GODOT) --headless --path . res://tests/solar_beam_test.tscn 2>&1 | tee /tmp/gtfo-beams.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-beams.log
	@$(GODOT) --headless --path . res://tests/survival_test.tscn 2>&1 | tee /tmp/gtfo-survival.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-survival.log
	@$(GODOT) --headless --path . res://tests/survival_hud_test.tscn 2>&1 | tee /tmp/gtfo-hud.log | grep -v '^$$' || true
	@! grep -qiE 'ERROR|WARNING|[1-9][0-9]* failures' /tmp/gtfo-hud.log
	@$(GODOT) --headless --path . res://tests/inventory_test.tscn 2>&1 | tee /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/repair_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/view_turn_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/map_stream_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/window_crack_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/dev_panel_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/suit_light_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/window_glass_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/window_restore_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
	@$(GODOT) --headless --path . res://tests/bot_story_test.tscn 2>&1 | tee -a /tmp/gtfo-tests.log | grep -v '^$$' || true
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
