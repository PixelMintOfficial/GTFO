#!/usr/bin/env python3
"""Split the web build's game data into parts, for hosts that cap a single file at 100 MB.

Vercel, GitHub Pages and others refuse a file over 100 MB, and the exported index.pck is ~150 MB.
This copies a Godot web export (make export's build/web) to build/web-split with index.pck cut into
parts, and adds a few lines to index.html that stitch them back together: Godot fetches the data file
with the browser's fetch(), so a wrapper hands it one stream made of all the parts (fetched in
parallel, read in order). The engine and the game are untouched, and its progress bar still works.

usage: python3 tools/web_split_pck.py [SRC=build/web] [DST=build/web-split] [PARTS=4]
Then deploy DST as a static site (vercel deploy DST --prod).
"""
import json
import shutil
import sys
from pathlib import Path

src = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/web')
dst = Path(sys.argv[2] if len(sys.argv) > 2 else 'build/web-split')
n = int(sys.argv[3]) if len(sys.argv) > 3 else 4

pck = src / 'index.pck'
data = pck.read_bytes()
total = len(data)
size = -(-total // n)
if dst.exists():
    shutil.rmtree(dst)
dst.mkdir(parents=True)
for f in src.iterdir():
    if f.is_file() and f.name != 'index.pck' and f.suffix != '.import':
        shutil.copy2(f, dst / f.name)
parts = []
for i in range(n):
    name = f'index.pck.part{i}'
    (dst / name).write_bytes(data[i * size:(i + 1) * size])
    parts.append(name)
    assert (dst / name).stat().st_size < 100 * 1024 * 1024, name

shim = """<script>
// The game data is served in %d parts (see tools/web_split_pck.py); hand Godot one stream of them.
(function () {
	const PARTS = %s;
	const TOTAL = %d;
	const realFetch = window.fetch.bind(window);
	window.fetch = function (input, init) {
		const url = typeof input === 'string' ? input : ((input && input.url) || '');
		if (!/(^|\\/)index\\.pck(\\?|$)/.test(url)) {
			return realFetch(input, init);
		}
		const pending = PARTS.map((p) => realFetch(p));
		let i = 0;
		let reader = null;
		const body = new ReadableStream({
			async pull(controller) {
				for (;;) {
					if (reader === null) {
						if (i >= PARTS.length) {
							controller.close();
							return;
						}
						const r = await pending[i++];
						if (!r.ok) {
							controller.error(new Error('Failed to load ' + r.url + ' (' + r.status + ')'));
							return;
						}
						reader = r.body.getReader();
					}
					const { done, value } = await reader.read();
					if (done) {
						reader = null;
						continue;
					}
					controller.enqueue(value);
					return;
				}
			},
		});
		return Promise.resolve(new Response(body, { status: 200, headers: {
			'Content-Type': 'application/octet-stream', 'Content-Length': String(TOTAL) } }));
	};
})();
</script>
""" % (n, json.dumps(parts), total)

html = (dst / 'index.html').read_text()
tag = '<script src="index.js"></script>'
assert html.count(tag) == 1
(dst / 'index.html').write_text(html.replace(tag, shim + '\t\t' + tag))
print(f'{dst}: {n} parts of up to {size / 1e6:.1f} MB, {total / 1e6:.1f} MB in all')
