# Sound sources

Written by `tools/sfx_gen.py` - do not edit by hand.

The recordings behind the sampled layer. `python tools/sfx_gen.py --fetch`
downloads and checksums them into `assets/audio/sources/`, which is
git-ignored: the repo keeps the baked `*.wav`, not the raw packs.

| pack | author | licence | page |
|---|---|---|---|
| `jc_nature_vol1` | JC Sounds | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | [Nature Ambient Pack Vol 1](https://opengameart.org/content/jc-sounds-nature-ambient-pack-vol-1) |
| `oga_fire_crackling` | AntumDeluge | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | [Fire Crackling](https://opengameart.org/content/fire-crackling) |
| `oga_corsica_snow` | Corsica_S (submitted by qubodup) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | [42 Snow and Gravel Footsteps](https://opengameart.org/content/42-snow-and-gravel-footsteps) |
| `kenney_impacts` | Kenney | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | [Impact Sounds](https://kenney.nl/assets/impact-sounds) |
| `oga_rubberduck_sfx100v2` | rubberduck | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | [100 CC0 SFX #2](https://opengameart.org/content/100-cc0-sfx-2) |
| `oga_rubberduck_breaking` | rubberduck | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | [75 CC0 breaking / falling / hit sfx](https://opengameart.org/content/75-cc0-breaking-falling-hit-sfx) |
| `oga_rubberduck_metalwood` | rubberduck | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | [100 CC0 metal and wood SFX](https://opengameart.org/content/100-cc0-metal-and-wood-sfx) |
| `oga_rubberduck_loops` | rubberduck | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | [30 CC0 SFX loops](https://opengameart.org/content/30-cc0-sfx-loops) |
| `oga_rubberduck_water` | rubberduck | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | [40 CC0 water / splash / slime SFX](https://opengameart.org/content/40-cc0-water-splash-slime-sfx) |

## Which sound came from where

Every entry in `audio.json` carries a `note` saying which recording it uses and
the measurement that justified it. `python tools/sfx_gen.py --probe <glob>`
measures candidates the same way.

## The synthesised layer

The alien tech - the multitool's beams, the lens, the lamps, the crystal
spires, the beacons, the UI - is generated in `sfx_gen.py` itself, under the
same terms as the rest of this repository.
