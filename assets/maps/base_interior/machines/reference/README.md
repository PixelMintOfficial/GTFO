# Original Crack Repair panels

These are the owner's supplied images, copied unchanged on 2026-10-08 at their explicit
request. They are the approved exception to GTFO's generated-art rule for these two UI panels.

- `power.png`: `codex-clipboard-64cd559b-ea65-48c3-980c-4e94c49f1a0f.png`
- `oxygen.png`: `codex-clipboard-05b40d7a-674d-40e5-a944-b0d2bdf4a2ee.png`

The source files include the full reference UI. The native puzzle draws only the wall region
from `(43, 99)` with size `642 × 219`, using nearest filtering. The holes are already present.
`tools/interior_gen.py --repair-panels-only` reads the original pixels and exports crop,
hole placement samples and source SHA-256 to `machines.json`; it never writes these PNGs.
