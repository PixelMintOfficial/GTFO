// Download buttons for the desktop builds.
//
// The hosting has a 100 MB limit per file, so each zip is stored as a few parts (see tools/build_site.py and
// downloads/manifest.json). The button fetches every part in parallel, joins them in memory, checks the
// SHA-256 against the manifest, and only then hands the finished zip to the browser to save.
(function () {
	'use strict';

	const OS_NAMES = { windows: 'Windows', linux: 'Linux' };
	let manifest = null;
	const busy = {};

	const $$ = (sel) => Array.from(document.querySelectorAll(sel));
	const mb = (bytes) => (bytes / 1e6).toFixed(bytes >= 1e8 ? 0 : 1) + ' MB';

	function setButtons(os, { label, progress, state }) {
		$$('[data-os="' + os + '"]').forEach((btn) => {
			const text = btn.querySelector('.btn-label');
			if (text && label !== undefined) {
				text.textContent = label;
			}
			if (progress !== undefined) {
				btn.style.setProperty('--p', progress + '%');
			}
			btn.classList.toggle('busy', state === 'busy');
			btn.classList.toggle('done', state === 'done');
		});
	}

	function setStatus(os, text, isError) {
		$$('[data-status="' + os + '"]').forEach((el) => {
			el.textContent = text;
			el.classList.toggle('err', !!isError);
		});
	}

	function hex(buffer) {
		return Array.from(new Uint8Array(buffer)).map((b) => b.toString(16).padStart(2, '0')).join('');
	}

	async function fetchParts(entry, onProgress) {
		const whole = new Uint8Array(entry.size);
		const loaded = new Array(entry.parts.length).fill(0);
		let offset = 0;
		const offsets = entry.partSizes.map((s) => { const o = offset; offset += s; return o; });
		await Promise.all(entry.parts.map(async (url, i) => {
			const response = await fetch(url);
			if (!response.ok) {
				throw new Error('Could not load ' + url + ' (' + response.status + ')');
			}
			const reader = response.body.getReader();
			let at = offsets[i];
			for (;;) {
				const { done, value } = await reader.read();
				if (done) {
					break;
				}
				whole.set(value, at);
				at += value.length;
				loaded[i] += value.length;
				onProgress(loaded.reduce((a, b) => a + b, 0) / entry.size);
			}
			if (loaded[i] !== entry.partSizes[i]) {
				throw new Error('Part ' + (i + 1) + ' came through incomplete. Try again.');
			}
		}));
		return whole;
	}

	async function download(os) {
		if (busy[os]) {
			return;
		}
		if (!manifest) {
			setStatus(os, 'The download info did not load. Reload the page and try again.', true);
			return;
		}
		const entry = manifest[os];
		busy[os] = true;
		setStatus(os, '', false);
		try {
			setButtons(os, { label: 'Downloading… 0%', progress: 0, state: 'busy' });
			const whole = await fetchParts(entry, (f) => {
				setButtons(os, { label: 'Downloading… ' + Math.floor(f * 100) + '%', progress: Math.floor(f * 100) });
			});
			let verified = false;
			if (window.crypto && window.crypto.subtle) {
				setButtons(os, { label: 'Checking the file…', progress: 100 });
				const sum = hex(await window.crypto.subtle.digest('SHA-256', whole));
				if (sum !== entry.sha256) {
					throw new Error('The file did not match its checksum, so it was not saved. Try again.');
				}
				verified = true;
			}
			const url = URL.createObjectURL(new Blob([whole], { type: 'application/zip' }));
			const a = document.createElement('a');
			a.href = url;
			a.download = entry.name;
			document.body.appendChild(a);
			a.click();
			a.remove();
			setTimeout(() => URL.revokeObjectURL(url), 120000);
			setButtons(os, { label: 'Saved ' + entry.name, progress: 100, state: 'done' });
			setStatus(os, (verified ? 'Checksum verified. ' : '') + 'Unzip it and run the game.', false);
		} catch (err) {
			console.error(err);
			setButtons(os, { label: 'Download for ' + OS_NAMES[os], progress: 0 });
			setStatus(os, err.message || 'The download failed. Try again.', true);
		} finally {
			busy[os] = false;
			if (!document.querySelector('[data-os="' + os + '"].done')) {
				setButtons(os, { state: '' });
			}
		}
	}

	function wire() {
		$$('[data-os]').forEach((btn) => {
			btn.addEventListener('click', (e) => {
				e.preventDefault();
				download(btn.dataset.os);
			});
		});
	}

	function detect() {
		const ua = navigator.userAgent || '';
		const isMac = /Mac OS X|Macintosh/.test(ua) && !/iPhone|iPad/.test(ua);
		const isLinux = /Linux|X11/.test(ua) && !/Android/.test(ua);
		if (isLinux) {
			document.getElementById('card-linux').classList.add('suggested');
			const win = document.getElementById('dl-windows');
			const lin = document.getElementById('dl-linux');
			win.classList.replace('btn-primary', 'btn-ghost');
			lin.classList.replace('btn-ghost', 'btn-primary');
			win.parentNode.insertBefore(lin, win);
		} else if (/Windows/.test(ua)) {
			document.getElementById('card-windows').classList.add('suggested');
		}
		if (isMac) {
			document.querySelector('.cta-note').innerHTML =
				'On a Mac? There is no Mac build yet &mdash; <a href="play/">play it in your browser</a>.';
		}
	}

	async function loadManifest() {
		try {
			const response = await fetch('downloads/manifest.json', { cache: 'no-cache' });
			manifest = await response.json();
		} catch (err) {
			console.error(err);
			return;
		}
		for (const os of Object.keys(OS_NAMES)) {
			const entry = manifest[os];
			if (!entry) {
				continue;
			}
			$$('[data-size="' + os + '"]').forEach((el) => { el.textContent = mb(entry.size); });
			$$('[data-hash="' + os + '"]').forEach((el) => { el.textContent = entry.sha256; });
		}
		const parts = document.getElementById('parts');
		if (parts) {
			parts.innerHTML = Object.keys(OS_NAMES).filter((os) => manifest[os]).map((os) =>
				manifest[os].parts.map((p) => '<a href="' + p + '">' + p.split('/').pop() + '</a>').join('')).join('<br>');
		}
	}

	wire();
	detect();
	loadManifest();
})();
