#!/usr/bin/env python3
"""
Sound generator
===============

Every sound in the game is built here, so the whole soundtrack is made one way - the audio
side of "everything must look as if the same artist drew it". There is no music: just the
environment of the red planet and the sounds of working on it.

Two kinds of ingredient:

  recordings  Real field recordings and sample packs under open licences: wind, snow
              underfoot, fire, water, stone, sheet metal. They give the world its weight and
              grit. They live in assets/audio/sources/ (git-ignored), are fetched and
              checksummed by --fetch, and every one is listed with its licence in PACKS.
  synthesis   The alien tech is generated from code: the multitool's beams, the lens, the
              lamps, the comms beacon, the UI. A real recording of Earth hardware would sound
              like Earth hardware; these are drawn to match the pixel art instead.

Both then go through the SAME mastering chain - mono, 22050 Hz, filtered, loudness matched,
seamlessly looped - so a recording and a synthesised sound sit in the same room.

    python tools/sfx_gen.py --fetch        download + verify the source packs (~100 MB, once)
    python tools/sfx_gen.py                bake every sound
    python tools/sfx_gen.py --only step    bake only sounds whose name contains "step"
    python tools/sfx_gen.py --probe 'assets/audio/sources/kenney_impacts/Audio/*.ogg'

--probe measures candidate recordings (duration, loudness, spectral centroid, band split,
onset rate, stationarity, flatness) so a source can be chosen on evidence rather than on its
filename - and without listening to 550 files. Every pick in RECIPES carries the measurement
that justified it in its `note`, which is copied into audio.json.

Writes assets/audio/:
    <name>_<n>.wav      the sounds (16-bit mono PCM; looping ones carry a `smpl` chunk, which
                        is how Godot knows where the loop is)
    audio.json          the data contract scripts/audio.gd reads: buses, gains, variants,
                        pitch ranges, loop flags, hearing distance, and why each source
    SOURCES.md          every source pack, its author, licence and URL
    CREDITS.md          the attribution the game MUST ship (some packs are CC BY)

Needs ffmpeg on the PATH (decoding ogg/mp3/flac) and bsdtar or unzip (unpacking).
"""
import argparse
import glob
import hashlib
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import urllib.request
import zlib

import numpy as np
from scipy import signal

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'assets', 'audio')
SRC = os.path.join(OUT, 'sources')

## One rate for everything, like the one camera and the one palette. 22050 Hz reaches 11 kHz,
## which is all the wind, grit and metal here need, and keeps the whole soundtrack a few MB.
SR = 22050
TAU = 2 * math.pi

## Mixer buses, created at runtime by scripts/audio.gd. amb sits under everything; ui is flat
## and non-positional.
BUSES = {'amb': -5.0, 'sfx': 0.0, 'ui': -3.0}


# ================================================================== source packs
# Everything here is CC0 or CC BY. CC BY means the game must credit it: CREDITS.md is
# generated from this table, so adding a pack adds its credit automatically.
PACKS = {
    'jc_nature_vol1': dict(
        title='Nature Ambient Pack Vol 1', author='JC Sounds',
        licence='CC BY 4.0', licence_url='https://creativecommons.org/licenses/by/4.0/',
        credit='Nature Ambient Pack Vol 1 by JC Sounds - CC BY 4.0',
        page='https://opengameart.org/content/jc-sounds-nature-ambient-pack-vol-1',
        url='https://opengameart.org/sites/default/files/nature_ambient_pack_vol_1_-_mp3.7z',
        sha256='6ca6a89759251206a964ade39adbdad2d0b013a959cc7a01fe9722e6e07299a1', strip=1),
    'kenney_impacts': dict(
        title='Impact Sounds', author='Kenney',
        licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/',
        credit='Impact Sounds by Kenney (kenney.nl) - CC0',
        page='https://kenney.nl/assets/impact-sounds',
        url='https://kenney.nl/media/pages/assets/impact-sounds/87b4ddecda-1677589768/'
            'kenney_impact-sounds.zip',
        sha256='029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8', strip=0),
    'oga_corsica_snow': dict(
        title='42 Snow and Gravel Footsteps', author='Corsica_S (submitted by qubodup)',
        licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/',
        credit='42 Snow and Gravel Footsteps by Corsica_S - CC0',
        page='https://opengameart.org/content/42-snow-and-gravel-footsteps',
        url='https://opengameart.org/sites/default/files/corsica_s-walking_in_snow.7z',
        sha256='206306b51f8eeedf82043d6628174ec8ff9b16230dffb5192a5c74688e62abd4', strip=1),
    'oga_rubberduck_sfx100v2': dict(
        title='100 CC0 SFX #2', author='rubberduck',
        licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/',
        credit='100 CC0 SFX #2 by rubberduck - CC0',
        page='https://opengameart.org/content/100-cc0-sfx-2',
        url='https://opengameart.org/sites/default/files/sfx_100_v2.zip',
        sha256='0fc61b4494e2e893c0c015ced4877b3f689c7d84a48cb61daecd7ddb52db797b', strip=0),
    'oga_rubberduck_breaking': dict(
        title='75 CC0 breaking / falling / hit sfx', author='rubberduck',
        licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/',
        credit='75 CC0 breaking / falling / hit sfx by rubberduck - CC0',
        page='https://opengameart.org/content/75-cc0-breaking-falling-hit-sfx',
        url='https://opengameart.org/sites/default/files/sfx_breaking_and_falling.zip',
        sha256='e6ee04d91c5f4d30cfda1260d2c9d1faf96fda36319287215fbd07bcb1a80451', strip=0),
    'oga_rubberduck_metalwood': dict(
        title='100 CC0 metal and wood SFX', author='rubberduck',
        licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/',
        credit='100 CC0 metal and wood SFX by rubberduck - CC0',
        page='https://opengameart.org/content/100-cc0-metal-and-wood-sfx',
        url='https://opengameart.org/sites/default/files/100-CC0-wood-metal-SFX.zip',
        sha256='be6eba63b03409ac0c77787a956b1503a7c186403d04aef9725c52644a4b7878', strip=0),
    'oga_rubberduck_loops': dict(
        title='30 CC0 SFX loops', author='rubberduck',
        licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/',
        credit='30 CC0 SFX loops by rubberduck - CC0',
        page='https://opengameart.org/content/30-cc0-sfx-loops',
        url='https://opengameart.org/sites/default/files/sfx_loops.zip',
        sha256='9c013474c7e56192a0d1b2840535a1e1d8b93166948d4a9f7136bb6c3d5421cd', strip=0),
    'oga_rubberduck_water': dict(
        title='40 CC0 water / splash / slime SFX', author='rubberduck',
        licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/',
        credit='40 CC0 water / splash / slime SFX by rubberduck - CC0',
        page='https://opengameart.org/content/40-cc0-water-splash-slime-sfx',
        url='https://opengameart.org/sites/default/files/water-splash-slime-sfx.zip',
        sha256='7cd39abb49d4362a37ba18dc0e454c7dc1d08029d4e5b683149046bc237b2eba', strip=0),
    'oga_fire_crackling': dict(
        title='Fire Crackling', author='AntumDeluge',
        licence='CC0 1.0', licence_url='https://creativecommons.org/publicdomain/zero/1.0/',
        credit='Fire Crackling by AntumDeluge - CC0',
        page='https://opengameart.org/content/fire-crackling',
        url='https://opengameart.org/sites/default/files/fire-1.wav',
        sha256='26702de8a195bcbafeae72034861d875a1b7917168a25106f4e1957ecdddf7e5', strip=0),
}


def fetch():
    """Download every pack into assets/audio/sources/, verifying its checksum."""
    os.makedirs(SRC, exist_ok=True)
    # Godot must not import 550 source recordings it will never play: .gdignore makes it skip
    # the whole folder, the same way tools/ is skipped. It lives here rather than in the repo
    # because the folder itself is git-ignored.
    with open(os.path.join(SRC, '.gdignore'), 'w') as f:
        f.write('')
    cache = os.path.join(SRC, '.cache')
    os.makedirs(cache, exist_ok=True)
    for pid, p in PACKS.items():
        into = os.path.join(SRC, pid)
        if os.path.isdir(into) and os.listdir(into):
            print(f'  {pid}: already there')
            continue
        name = p['url'].rsplit('/', 1)[-1]
        blob = os.path.join(cache, name)
        if not os.path.exists(blob) or _sha256(blob) != p['sha256']:
            print(f'  {pid}: downloading {name}')
            req = urllib.request.Request(p['url'], headers={'User-Agent': 'gtfo-sfx-gen'})
            with urllib.request.urlopen(req) as r, open(blob, 'wb') as f:
                shutil.copyfileobj(r, f)
        got = _sha256(blob)
        if got != p['sha256']:
            raise SystemExit(f'{pid}: checksum mismatch\n  expected {p["sha256"]}\n  got      {got}\n'
                             f'  The file at {p["url"]} changed. Listen to the new one, then '
                             f'update sha256 in PACKS.')
        os.makedirs(into, exist_ok=True)
        _unpack(blob, into, p['strip'])
        print(f'  {pid}: {len(os.listdir(into))} entries')
    print('sources ready (git-ignored; see assets/audio/SOURCES.md)')


def _sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def _bsdtar():
    """bsdtar by name, or the system tar where that is bsdtar (Windows 10+ and macOS ship it so)."""
    if shutil.which('bsdtar'):
        return 'bsdtar'
    tar = shutil.which('tar')
    if tar and 'bsdtar' in subprocess.run([tar, '--version'], capture_output=True, text=True).stdout:
        return tar
    return None


def _unpack(blob, into, strip):
    if not blob.endswith(('.zip', '.7z', '.tar', '.tar.gz', '.tgz')):
        shutil.copy2(blob, os.path.join(into, os.path.basename(blob).replace('%20', '_')))
        return
    tar = _bsdtar()
    if tar:
        subprocess.run([tar, '-xf', blob, '-C', into] +
                       ([f'--strip-components={strip}'] if strip else []), check=True)
    elif blob.endswith('.zip'):
        import zipfile
        with zipfile.ZipFile(blob) as z:
            z.extractall(into)
    else:
        raise SystemExit(f'cannot unpack {blob}: install bsdtar (libarchive)')


# ================================================================== reading and measuring
def decode(path):
    """Any audio file -> mono float array at SR, via ffmpeg."""
    r = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'f32le', '-ac', '1',
                        '-ar', str(SR), '-'], capture_output=True)
    if r.returncode != 0:
        raise SystemExit(f'ffmpeg failed on {path}:\n{r.stderr.decode()[:400]}')
    return np.frombuffer(r.stdout, dtype='<f4').astype(np.float64)


def take(pack, pattern):
    """Source files matching a glob inside one pack, sorted. Each match is one variant."""
    hits = sorted(glob.glob(os.path.join(SRC, pack, '**', pattern), recursive=True))
    if not hits:
        raise SystemExit(f'no source matches {pack}:{pattern}\n'
                         f'  run: python tools/sfx_gen.py --fetch')
    return hits


def features(x):
    """What --probe prints. Enough to pick a recording without hearing it."""
    n, hop = 1024, 512
    if x.size < n * 2:
        return None
    m = (x.size - n) // hop
    w = np.hanning(n)
    frames = x[np.arange(m)[:, None] * hop + np.arange(n)] * w
    mag = np.abs(np.fft.rfft(frames, axis=1)) + 1e-12
    f = np.fft.rfftfreq(n, 1 / SR)
    p = mag ** 2
    tot = p.sum(1)
    band = p[:, (f >= 2000) & (f < 8000)].sum(1)
    rise = np.diff(np.log(band + 1e-12))
    envel = np.sqrt(tot)
    return dict(
        dur=x.size / SR,
        rms=20 * math.log10(float(np.sqrt(np.mean(x ** 2))) + 1e-12),
        peak=20 * math.log10(float(np.max(np.abs(x))) + 1e-12),
        cent=float(np.mean((p * f).sum(1) / tot)),
        lf=float(np.mean(p[:, f < 300].sum(1) / tot)) * 100,
        mf=float(np.mean(p[:, (f >= 300) & (f < 2000)].sum(1) / tot)) * 100,
        hf=float(np.mean(p[:, f >= 2000].sum(1) / tot)) * 100,
        tran=float((rise > 1.1).sum()) / (x.size / SR),
        stat=1.0 - min(1.0, float(np.std(envel) / (np.mean(envel) + 1e-12))),
        flat=float(np.mean(np.exp(np.mean(np.log(mag), 1)) / np.mean(mag, 1))))


def probe(patterns):
    print(f"{'file':<48}{'dur':>7}{'rms':>6}{'peak':>6}{'cent':>6}{'lf':>5}{'mf':>5}"
          f"{'hf':>5}{'tran':>6}{'stat':>6}{'flat':>6}")
    print('  dur s | rms/peak dBFS | cent Hz | lf<300 mf<2k hf>2k % | tran onsets/s '
          '| stat 1=steady | flat 1=noise')
    for pattern in patterns:
        for path in sorted(glob.glob(pattern, recursive=True)):
            v = features(decode(path))
            name = os.path.basename(path)[:47]
            if v is None:
                print(f'{name:<48}  (too short)')
                continue
            print(f"{name:<48}{v['dur']:7.2f}{v['rms']:6.1f}{v['peak']:6.1f}{v['cent']:6.0f}"
                  f"{v['lf']:5.1f}{v['mf']:5.1f}{v['hf']:5.1f}{v['tran']:6.1f}"
                  f"{v['stat']:6.2f}{v['flat']:6.3f}")


# ================================================================== the mastering chain
# Every op is a function of one signal. A recipe lists them in order; `bake` folds them.
def _ns(sec):
    return max(1, int(round(sec * SR)))


def _sos(kind, *hz, order=2):
    w = [min(h, SR * 0.49) / (SR / 2) for h in hz]
    return signal.butter(order, w if len(w) > 1 else w[0], kind, output='sos')


def hp(hz, order=2):
    """Roll off below hz: takes the mud out and keeps the 384x216 mix clean."""
    return lambda x: signal.sosfilt(_sos('highpass', hz, order=order), x)


def lp(hz, order=2):
    return lambda x: signal.sosfilt(_sos('lowpass', hz, order=order), x)


def bp(lo, hi, order=2):
    return lambda x: signal.sosfilt(_sos('bandpass', lo, hi, order=order), x)


def tilt(db_per_oct, pivot=700.0):
    """Gentle spectral tilt: negative darkens (dust, distance), positive brightens (ice)."""
    def op(x):
        n = x.size
        f = np.fft.rfftfreq(n, 1 / SR)
        g = 10 ** (db_per_oct * np.log2(np.maximum(f, 20.0) / pivot) / 20.0)
        return np.fft.irfft(np.fft.rfft(x) * g, n)
    return op


def trim(thresh_db=-46.0, pad=0.004):
    """Cut leading and trailing silence (sample packs are full of it)."""
    def op(x):
        if x.size == 0:
            return x
        thresh = 10 ** (thresh_db / 20.0) * np.max(np.abs(x))
        loud = np.flatnonzero(np.abs(x) > thresh)
        if loud.size == 0:
            return x
        a = max(0, loud[0] - _ns(pad))
        b = min(x.size, loud[-1] + _ns(pad))
        return x[a:b]
    return op


def cut(start, dur):
    """Take a window, in seconds, out of a longer recording."""
    return lambda x: x[_ns(start):_ns(start) + _ns(dur)]


def head(dur):
    return lambda x: x[:_ns(dur)]


def delay(sec):
    """Start later: silence in front, so a layer lands at its moment inside the sound."""
    return lambda x: np.concatenate([np.zeros(_ns(sec)), x])


def pitch(ratio):
    """Resample: >1 shorter and higher, <1 longer and lower."""
    def op(x):
        n = max(2, int(round(x.size / ratio)))
        return np.interp(np.linspace(0, x.size - 1, n), np.arange(x.size), x)
    return op


def gain(db):
    return lambda x: x * 10 ** (db / 20.0)


def norm(peak_db=-3.0):
    def op(x):
        m = float(np.max(np.abs(x)))
        return x if m < 1e-9 else x * (10 ** (peak_db / 20.0) / m)
    return op


def rms_to(db):
    """Match perceived loudness - better than peak matching for beds and footsteps."""
    def op(x):
        r = float(np.sqrt(np.mean(x ** 2)))
        return x if r < 1e-9 else x * (10 ** (db / 20.0) / r)
    return op


def fade(in_s=0.004, out_s=0.02, shape=1.6):
    def op(x):
        y = x.copy()
        a, b = min(_ns(in_s), y.size), min(_ns(out_s), y.size)
        if a > 1:
            y[:a] *= np.linspace(0.0, 1.0, a) ** shape
        if b > 1:
            y[-b:] *= np.linspace(1.0, 0.0, b) ** shape
        return y
    return op


def ramp(sec, points):
    """An envelope as an array: [(fraction of the sound, level), ...]."""
    fr = np.array([p[0] for p in points], dtype=float)
    lv = np.array([p[1] for p in points], dtype=float)
    return np.interp(np.linspace(0, 1, _ns(sec)), fr, lv)


def env(points):
    """The same envelope as a chain op, for recipes."""
    def op(x):
        fr = np.array([p[0] for p in points])
        lv = np.array([p[1] for p in points])
        return x * np.interp(np.linspace(0, 1, x.size), fr, lv)
    return op


def space(mix=0.22, decay=0.5, size=0.031, circular=False):
    """A small room: four parallel combs into two allpasses (Schroeder). Both are IIR, so
    they run through lfilter rather than a per-sample loop.

    circular=True folds the tail back onto the start, so a loop stays seamless.
    """
    def comb(x, d, g):
        a = np.zeros(d + 1)
        a[0], a[d] = 1.0, -g
        return signal.lfilter([1.0], a, x)

    def allpass(x, d, g):
        b = np.zeros(d + 1)
        b[0], b[d] = -g, 1.0
        a = np.zeros(d + 1)
        a[0], a[d] = 1.0, -g
        return signal.lfilter(b, a, x)

    def op(x):
        n = x.size
        pad = 0 if circular else _ns(decay)
        dry = np.concatenate([x, np.zeros(pad)])
        wet = np.zeros(dry.size)
        for r in (1.0, 0.813, 0.7, 0.633):
            d = max(1, _ns(size * r))
            g = min(0.86, 10 ** (-3.0 * d / max(1, _ns(decay)) / 20.0))
            wet += comb(dry, d, g) / 4.0
        for d_s, g in ((0.0047, 0.7), (0.0017, 0.7)):
            wet = allpass(wet, max(1, _ns(d_s)), g)
        wet /= max(1e-9, float(np.max(np.abs(wet)))) / max(1e-9, float(np.max(np.abs(x))))
        if circular:                                     # wrap what spilled past the end
            tail = wet[n:]
            wet = wet[:n].copy()
            if tail.size:
                k = min(tail.size, n)
                wet[:k] += tail[:k]
            return (1 - mix) * x + mix * wet
        return (1 - mix) * dry + mix * wet

    return op


def loopify(seconds, xfade=0.9):
    """Make a seamless loop: take `seconds` of the recording and crossfade its tail into its
    head, so the join is inaudible however long the player stands there."""
    def op(x):
        n, f = _ns(seconds), _ns(xfade)
        if x.size < n + f:
            reps = int(math.ceil((n + f) / max(1, x.size)))
            x = np.tile(x, reps)
        body = x[:n].copy()
        tail = x[n:n + f]
        w = np.linspace(0.0, 1.0, f) ** 0.5
        body[:f] = body[:f] * w + tail * (1.0 - w)
        return body
    return op


def declick(ms=1.2):
    return fade(ms / 1000.0, ms / 1000.0, shape=1.0)


def limit(ceiling=0.94):
    """Soft knee, so a layered stack never clips into a crunch."""
    return lambda x: np.tanh(x / ceiling) * ceiling


def ceil_at(peak_db=-0.8):
    """Scale down (never up) so the peak sits at most at peak_db. Applied to every sound at
    the end of baking: rms_to() matches loudness without watching the peak, and a footstep
    or a switch has a far higher crest factor than a wind bed."""
    def op(x):
        m = float(np.max(np.abs(x)))
        lim = 10 ** (peak_db / 20.0)
        return x * (lim / m) if m > lim else x
    return op


def dc():
    return lambda x: x - float(np.mean(x))


def run(x, chain):
    for op in chain:
        x = op(x)
    return x


# ================================================================== synthesis
def seeded(name):
    return np.random.default_rng(zlib.crc32(name.encode()) & 0xffffffff)


def sig(sec):
    return np.arange(_ns(sec)) / SR


def sine(sec, hz, phase=0.0):
    return np.sin(TAU * hz * sig(sec) + phase)


def sweep(sec, f0, f1, curve=1.0):
    """A chirp from f0 to f1; curve > 1 holds low then rushes up."""
    t = np.linspace(0.0, 1.0, _ns(sec))
    f = f0 + (f1 - f0) * t ** curve
    return np.sin(TAU * np.cumsum(f) / SR)


def dec(sec, tau, curve=1.0):
    return np.exp(-(np.linspace(0.0, sec, _ns(sec)) / tau) ** curve)


def noise(sec, rng):
    return rng.standard_normal(_ns(sec))


def loop_noise(sec, rng, lo=40.0, hi=9000.0, slope=0.0):
    """Noise built in the frequency domain, so it is exactly periodic over `sec` and loops
    with no seam at all. slope shapes it: -1 pink, -2 brown (deep rumble)."""
    n = _ns(sec)
    f = np.fft.rfftfreq(n, 1 / SR)
    mag = np.zeros(f.size)
    band = (f >= lo) & (f <= hi)
    mag[band] = (np.maximum(f[band], 1e-6) / max(lo, 1.0)) ** slope
    spec = mag * np.exp(1j * rng.uniform(0, TAU, f.size))
    spec[0] = 0.0
    x = np.fft.irfft(spec, n)
    return x / (np.max(np.abs(x)) + 1e-12)


def loop_lfo(sec, rng, slowest=0.15, fastest=1.2):
    """A smooth 0..1 wander that also wraps: for gusting and breathing."""
    x = loop_noise(sec, rng, lo=slowest, hi=fastest, slope=-1.0)
    return 0.5 + 0.5 * x / (np.max(np.abs(x)) + 1e-12)


def modes(sec, freqs, taus, gains=None, detune=0.0, rng=None):
    """A struck object: a few decaying partials. Inharmonic ratios read as metal or stone,
    not as a note, which keeps it out of music's way."""
    gains = gains or [1.0] * len(freqs)
    out = np.zeros(_ns(sec))
    for hz, tau, g in zip(freqs, taus, gains):
        if detune and rng is not None:
            hz *= 1.0 + rng.uniform(-detune, detune)
        out += g * sine(sec, hz) * dec(sec, tau)
    return out / (np.max(np.abs(out)) + 1e-12)


def pulse_train(sec, hz, duty=0.35, shape=2.0):
    """A repeating gate whose rate divides the loop length, so loops stay seamless."""
    cycles = max(1, int(round(hz * sec)))
    ph = (np.linspace(0.0, cycles, _ns(sec), endpoint=False)) % 1.0
    g = np.clip(1.0 - ph / duty, 0.0, 1.0) ** shape
    return g


# ---------------------------------------------------------------- the alien tech
def syn_beam_mine(name):
    """A hot cutting beam: a buzzing core gated at the 7 Hz the beam visibly pulses at
    (multitool.gd draws sin(_t * 46)), with grit riding on top. Seamless over 1 s."""
    rng = seeded(name)
    sec = 1.0
    core = (0.55 * sine(sec, 196.0) + 0.3 * sine(sec, 293.0) + 0.2 * sine(sec, 441.0))
    grit = loop_noise(sec, rng, 900, 6500, -0.4)
    body = core * (0.55 + 0.45 * pulse_train(sec, 7.0, 0.5, 1.0)) + 0.5 * grit * pulse_train(sec, 7.0, 0.6, 1.4)
    return run(body, [bp(140, 6800), rms_to(-20.0), limit()])


def syn_beam_gather(name):
    """The spiral stream: airy, rising, weightless. Three staggered updraughts so nothing
    lands on the loop point."""
    rng = seeded(name)
    sec = 1.0
    air = loop_noise(sec, rng, 600, 8000, -0.5)
    shimmer = np.zeros(_ns(sec))
    for k, ph in enumerate((0.0, 0.33, 0.66)):
        lfo = 0.5 + 0.5 * np.sin(TAU * (2.0 * np.linspace(0, sec, _ns(sec)) + ph))
        shimmer += lfo * loop_noise(sec, seeded(name + str(k)), 1800 + 900 * k, 7000, -0.3)
    body = 0.6 * air + 0.5 * shimmer / 3.0 + 0.25 * sine(sec, 330.0) * loop_lfo(sec, rng)
    return run(body, [hp(380), lp(8500), rms_to(-22.0), limit()])


def syn_beam_fix(name):
    """Scan lines sweeping a dead lamp: a soft tone swept at the 0.8 Hz the beam is drawn
    sweeping at, over a patient hum. 1.25 s = exactly one sweep."""
    rng = seeded(name)
    sec = 1.25
    t = np.linspace(0.0, sec, _ns(sec))
    swept = np.sin(TAU * np.cumsum(620.0 + 300.0 * np.sin(TAU * 0.8 * t)) / SR)
    hum = 0.4 * sine(sec, 155.0) + 0.2 * sine(sec, 311.0)
    air = 0.3 * loop_noise(sec, rng, 2000, 7000, -0.6) * (0.5 + 0.5 * np.sin(TAU * 0.8 * t))
    return run(0.55 * swept * (0.6 + 0.4 * loop_lfo(sec, rng)) + hum + air,
               [bp(110, 7200), rms_to(-23.0), limit()])


def syn_lift_loop(name):
    """Carrying a crate: a patient violet thrum with a slow wobble. 2 s, seamless."""
    rng = seeded(name)
    sec = 2.0
    wob = 0.5 + 0.5 * np.sin(TAU * 1.5 * np.linspace(0, sec, _ns(sec)))
    body = (0.6 * sine(sec, 78.0) + 0.3 * sine(sec, 117.0) * wob
            + 0.18 * sine(sec, 234.0) * (1.0 - 0.6 * wob)
            + 0.12 * loop_noise(sec, rng, 300, 3000, -0.8))
    return run(body, [lp(3400), rms_to(-21.0), limit()])


def syn_unfold(name):
    """T: the device bursts open and the plates fly onto the forearm. 18 frames at 20 fps =
    0.9 s. Servo whine, three plate clacks, then the lock-on."""
    rng = seeded(name)
    sec = 0.95
    out = np.zeros(_ns(sec))
    out += 0.35 * sweep(sec, 120.0, 540.0, 1.5) * ramp(sec, [(0, 0), (0.08, 0.7), (0.75, 0.9), (1, 0.0)])
    out += 0.25 * run(noise(sec, rng), [bp(1400, 6000)]) * ramp(sec, [(0, 0), (0.1, 0.5), (0.8, 0.35), (1, 0)])
    for at, hz in ((0.30, 2100.0), (0.47, 1650.0), (0.63, 2600.0)):
        clack = modes(0.1, [hz, hz * 1.73, hz * 2.41], [0.013, 0.008, 0.005], rng=rng, detune=0.02)
        _add(out, 0.7 * clack, at)
    lock = modes(0.3, [380.0, 655.0, 980.0], [0.1, 0.06, 0.035], [1.0, 0.5, 0.3])
    _add(out, 0.9 * lock, 0.72)
    _add(out, 0.5 * sine(0.25, 1180.0) * dec(0.25, 0.09), 0.74)
    return run(out, [hp(90), lp(9000), norm(-4.0)])


def syn_fold(name):
    """Putting it away: the lock lets go, the plates fold back, the servo winds down."""
    rng = seeded(name)
    sec = 0.7
    out = np.zeros(_ns(sec))
    _add(out, 0.8 * modes(0.18, [520.0, 870.0], [0.05, 0.03]), 0.0)
    out += 0.3 * sweep(sec, 470.0, 110.0, 0.8) * ramp(sec, [(0, 0.2), (0.15, 0.8), (1, 0.0)])
    out += 0.18 * run(noise(sec, rng), [bp(1200, 5200)]) * ramp(sec, [(0, 0.4), (0.6, 0.3), (1, 0)])
    for at, hz in ((0.22, 1900.0), (0.4, 1450.0)):
        _add(out, 0.5 * modes(0.08, [hz, hz * 1.7], [0.01, 0.006], rng=rng, detune=0.02), at)
    return run(out, [hp(90), lp(8000), norm(-5.0)])


def syn_lens(name):
    """The lens coming alive: a small rising charge that settles into a held glow."""
    sec = 0.5
    out = 0.6 * sweep(sec, 300.0, 1240.0, 2.2) * ramp(sec, [(0, 0), (0.1, 1.0), (0.45, 0.6), (1, 0.0)])
    out += 0.3 * sine(sec, 1860.0) * dec(sec, 0.1)
    out += 0.2 * sine(sec, 620.0) * dec(sec, 0.25)
    return run(out, [hp(220), norm(-7.0)])


def syn_gather_pop(name):
    """A chunk vanishing into the lens: the little reward. A quick in-rush, then a clean
    two-tone chime - a fifth, not a tune."""
    sec = 0.4
    out = 0.5 * sweep(0.13, 900.0, 2600.0, 1.4) * dec(0.13, 0.05)
    out = np.concatenate([out, np.zeros(_ns(sec) - out.size)])
    _add(out, 0.55 * sine(0.3, 1568.0) * dec(0.3, 0.1), 0.1)
    _add(out, 0.35 * sine(0.28, 2349.0) * dec(0.28, 0.07), 0.12)
    return run(out, [hp(400), norm(-6.0)])


def syn_lift_grab(name):
    """The tether taking hold: a deep thrum swelling up under the crate."""
    sec = 0.45
    out = 0.7 * sweep(sec, 48.0, 150.0, 0.7) * ramp(sec, [(0, 0), (0.12, 1.0), (1, 0.25)])
    out += 0.3 * sine(sec, 300.0) * dec(sec, 0.12)
    out += 0.15 * sine(sec, 76.0)
    return run(out, [lp(2600), norm(-5.0)])


def syn_lamp_on(name):
    """A repaired path lamp: two struggling ticks, then warm light settling in."""
    rng = seeded(name)
    sec = 1.5
    out = np.zeros(_ns(sec))
    for at in (0.0, 0.17, 0.3):
        _add(out, 0.6 * run(noise(0.04, rng), [bp(2200, 7000), fade(0.001, 0.03)]), at)
        _add(out, 0.4 * sine(0.06, 1400.0) * dec(0.06, 0.02), at)
    hum = (0.5 * sine(sec, 100.0) + 0.25 * sine(sec, 200.0) + 0.12 * sine(sec, 300.0))
    out += 0.7 * hum * ramp(sec, [(0, 0), (0.22, 0.1), (0.3, 0.9), (0.45, 0.75), (1, 0.6)])
    _add(out, 0.35 * sine(0.5, 820.0) * dec(0.5, 0.18), 0.3)
    return run(out, [hp(70), lp(6000), norm(-6.0)])


def syn_lamp_hum(name):
    """A lit lamp, heard from close by. 2 s, seamless, and deliberately almost nothing."""
    rng = seeded(name)
    sec = 2.0
    body = 0.6 * sine(sec, 100.0) + 0.25 * sine(sec, 200.0) + 0.1 * loop_noise(sec, rng, 1500, 6000, -0.5)
    return run(body, [lp(5200), rms_to(-27.0)])


def syn_dome_hum(name):
    """A powered dome: the nursery and comms are alive while the base is dead, so this is
    what 'working' sounds like. A deep machine drone with a slow breath. 4 s."""
    rng = seeded(name)
    sec = 4.0
    breath = loop_lfo(sec, rng, 0.25, 0.8)
    body = (0.5 * sine(sec, 58.0) + 0.3 * sine(sec, 87.0) * (0.6 + 0.4 * breath)
            + 0.14 * sine(sec, 174.0) + 0.1 * sine(sec, 232.0) * breath
            + 0.12 * loop_noise(sec, rng, 200, 2600, -0.9))
    return run(body, [lp(3200), rms_to(-24.0), limit()])


def syn_spire(name):
    """A crystal spire breathing light: one slow inharmonic tone, drawn to match the glow
    pulsing at 0.55 rad/s in biome_fx.gd. Not a note; it never resolves anywhere. 8 s."""
    rng = seeded(name)
    sec = 8.0
    t = np.linspace(0.0, sec, _ns(sec))
    glow = 0.55 + 0.45 * np.sin(TAU * 0.125 * t)          # one slow breath per 8 s loop
    body = np.zeros(_ns(sec))
    for hz, g, rate in ((233.0, 0.5, 0.125), (349.5, 0.3, 0.25), (601.0, 0.18, 0.375),
                        (1043.0, 0.08, 0.5)):
        body += g * sine(sec, hz) * (0.4 + 0.6 * (0.5 + 0.5 * np.sin(TAU * rate * t)))
    body = body * glow + 0.06 * loop_noise(sec, rng, 2000, 8000, -0.4) * glow
    return run(body, [hp(150), lp(8800), space(0.3, 0.9, 0.041, circular=True), rms_to(-26.0)])


def syn_alien_life(name):
    """The forest's own voices: slow warbles and chitters that belong to no Earth animal.
    Layered under the recorded air so the alien forest is not just a wind bed. 12 s."""
    rng = seeded(name)
    sec = 12.0
    out = np.zeros(_ns(sec))
    for k in range(14):                                  # warbles: short bent whistles
        at = rng.uniform(0.0, sec - 1.0)
        d = rng.uniform(0.18, 0.5)
        f0 = rng.uniform(700.0, 1900.0)
        bend = rng.uniform(0.6, 1.7)
        v = np.sin(TAU * np.cumsum(f0 * (1.0 + 0.35 * np.sin(TAU * rng.uniform(3, 9)
                   * np.linspace(0, d, _ns(d)))) * np.linspace(1.0, bend, _ns(d))) / SR)
        _add(out, 0.22 * v * ramp(d, [(0, 0), (0.2, 1), (0.7, 0.7), (1, 0)]) * dec(d, d * 0.8), at)
    for k in range(26):                                  # chitters: dry clicks in runs
        at = rng.uniform(0.0, sec - 0.4)
        for j in range(rng.integers(2, 6)):
            d = 0.012
            _add(out, 0.18 * run(noise(d, rng), [bp(2400, 7000), fade(0.001, 0.008)]),
                 at + j * rng.uniform(0.03, 0.07))
    return run(out, [hp(400), lp(9000), space(0.35, 1.1, 0.037, circular=True), rms_to(-30.0)])


def syn_ice_groan(name):
    """Ice shifting somewhere out of sight: a low creak that bends. Layered into the ice bed
    so the frozen lakes feel like they are under strain. 12 s."""
    rng = seeded(name)
    sec = 12.0
    out = np.zeros(_ns(sec))
    for k in range(5):
        at = rng.uniform(0.0, sec - 2.5)
        d = rng.uniform(0.9, 2.2)
        f0 = rng.uniform(52.0, 120.0)
        v = np.sin(TAU * np.cumsum(f0 * np.linspace(1.0, rng.uniform(0.7, 1.5), _ns(d))) / SR)
        creak = run(noise(d, rng), [bp(140, 900)]) * (0.4 + 0.6 * np.abs(np.sin(
            TAU * rng.uniform(6, 16) * np.linspace(0, d, _ns(d)))))
        _add(out, (0.6 * v + 0.35 * creak) * ramp(d, [(0, 0), (0.15, 1), (0.6, 0.8), (1, 0)]), at)
    return run(out, [hp(40), lp(1400), space(0.3, 1.4, 0.05, circular=True), rms_to(-30.0)])


def syn_suit(name):
    """Inside the helmet: the life-support fan, and nothing else. The one sound that is
    always there, so it has to be almost inaudible. 6 s."""
    rng = seeded(name)
    sec = 6.0
    wob = loop_lfo(sec, rng, 0.2, 0.9)
    body = (0.4 * sine(sec, 124.0) * (0.85 + 0.15 * wob) + 0.18 * sine(sec, 248.0)
            + 0.5 * loop_noise(sec, rng, 300, 4000, -1.0))
    return run(body, [bp(110, 4200), rms_to(-32.0)])


def syn_spark(name):
    """Torn wiring letting go: an electrical crack, bright and dry, over in a blink.
    interior_fx.gd fires these in ones and in crackling runs."""
    rng = seeded(name)
    sec = 0.28
    out = run(noise(sec, rng), [bp(1800, 9500)]) * dec(sec, 0.035, 0.7)
    out += 0.5 * run(noise(sec, rng), [bp(400, 2200)]) * dec(sec, 0.018)
    for k in range(int(rng.integers(2, 5))):
        at = rng.uniform(0.005, 0.12)
        _add(out, 0.7 * run(noise(0.01, rng), [bp(3000, 9800), fade(0.0005, 0.004)]), at)
    _add(out, 0.35 * sine(0.09, rng.uniform(2600, 4200)) * dec(0.09, 0.02), 0.0)
    return run(out, [hp(300), norm(-5.0)])


def syn_jump(name):
    """Pushing off in low gravity: the suit's servos take the load and the boots leave."""
    rng = seeded(name)
    sec = 0.5
    out = 0.4 * sweep(sec, 180.0, 430.0, 1.6) * ramp(sec, [(0, 0), (0.06, 1.0), (0.5, 0.4), (1, 0)])
    out += 0.3 * run(noise(sec, rng), [bp(900, 5000)]) * ramp(sec, [(0, 0), (0.04, 0.9), (0.35, 0.2), (1, 0)])
    out += 0.3 * sine(sec, 90.0) * dec(sec, 0.07)
    return run(out, [hp(70), lp(7000), norm(-8.0)])


def syn_beacon(name):
    """The comms dome's beacon, and the wreck's distress call: a hard double blip. dome_fx.gd
    strobes it twice every 2 s; this is one of those."""
    sec = 0.22
    out = 0.7 * sine(sec, 1480.0) * dec(sec, 0.035, 0.8)
    out += 0.3 * sine(sec, 2960.0) * dec(sec, 0.02)
    out += 0.15 * sine(sec, 740.0) * dec(sec, 0.06)
    return run(out, [hp(500), norm(-9.0)])


def syn_roar(name):
    """Re-entry: the satellite coming down. A thin atmosphere's version of a fireball -
    pressure and tearing, not a jet engine. 2 s, seamless (the intro loops it while it falls)."""
    rng = seeded(name)
    sec = 2.0
    body = (0.8 * loop_noise(sec, rng, 40, 900, -1.2) + 0.5 * loop_noise(sec, rng, 900, 5000, -0.7)
            + 0.3 * sine(sec, 44.0))
    body *= 0.7 + 0.3 * loop_lfo(sec, rng, 0.5, 2.0)
    return run(body, [lp(6000), rms_to(-14.0), limit()])


def syn_zoom(name):
    """A camera zoom step: the quietest possible confirmation."""
    sec = 0.1
    return run(sine(sec, 880.0) * dec(sec, 0.025) + 0.3 * sine(sec, 1320.0) * dec(sec, 0.015),
               [hp(400), norm(-16.0)])


def syn_prompt(name):
    """A prompt appearing ([E] ENTER, or the tool's job icon): a soft tick, not a beep."""
    sec = 0.12
    out = sine(sec, 1240.0) * dec(sec, 0.02) + 0.4 * sine(sec, 1860.0) * dec(sec, 0.012)
    return run(out, [hp(600), norm(-17.0)])


def syn_toast(name):
    """A room's name fading in: one warm swell, under the door and the sparks."""
    sec = 0.6
    out = (0.5 * sine(sec, 220.0) + 0.3 * sine(sec, 330.0) + 0.15 * sine(sec, 440.0))
    return run(out * ramp(sec, [(0, 0), (0.25, 1.0), (1, 0.0)]), [hp(140), lp(4000), norm(-15.0)])


def syn_servo(name):
    """The airlock's mechanism while the slab moves: layered under the recorded sheet metal
    so the door is heavy AND powered. 0.6 s, seamless."""
    rng = seeded(name)
    sec = 0.6
    body = (0.5 * sine(sec, 86.0) + 0.3 * sine(sec, 129.0)
            + 0.35 * loop_noise(sec, rng, 600, 4500, -0.6) * (0.6 + 0.4 * pulse_train(sec, 20.0, 0.5, 1.0)))
    return run(body, [bp(60, 5200), rms_to(-20.0)])


def syn_slot(name):
    """Moving along the hotbar: the smallest possible confirmation, high and dry."""
    sec = 0.07
    out = sine(sec, 2100.0) * dec(sec, 0.012) + 0.3 * sine(sec, 3150.0) * dec(sec, 0.007)
    return run(out, [hp(900), norm(-14.0)])


def syn_pick(name):
    """Lifting an item out of a slot: a short rise, as if it came away cleanly."""
    sec = 0.14
    out = 0.7 * sweep(sec, 780.0, 1560.0, 1.3) * ramp(sec, [(0, 0), (0.15, 1.0), (1, 0.0)])
    out += 0.25 * sine(sec, 2340.0) * dec(sec, 0.03)
    return run(out, [hp(500), norm(-11.0)])


def syn_place(name):
    """Putting it down again: the same shape, falling."""
    sec = 0.16
    out = 0.7 * sweep(sec, 1400.0, 640.0, 0.8) * ramp(sec, [(0, 0), (0.1, 1.0), (1, 0.0)])
    out += 0.3 * sine(sec, 430.0) * dec(sec, 0.06)
    return run(out, [hp(300), norm(-11.0)])


def syn_deny(name):
    """The backpack is full. Two flat low notes: unmistakably "no", never harsh - the player
    has not done anything wrong, they are just out of room."""
    sec = 0.34
    out = np.zeros(_ns(sec))
    for at in (0.0, 0.14):
        buzz = (0.6 * sine(0.12, 196.0) + 0.3 * sine(0.12, 148.0)) * dec(0.12, 0.045)
        _add(out, buzz, at)
    return run(out, [lp(2600), norm(-12.0)])


def syn_panel_on(name):
    """A dead service panel coming alive: contact, then the screen finding its feet."""
    rng = seeded(name)
    sec = 0.6
    out = 0.35 * sweep(sec, 60.0, 220.0, 1.8) * ramp(sec, [(0, 0), (0.1, 1.0), (0.6, 0.7), (1, 0.2)])
    out += 0.3 * sine(sec, 440.0) * ramp(sec, [(0, 0), (0.25, 0.0), (0.35, 0.9), (1, 0.35)])
    out += 0.2 * run(noise(sec, rng), [bp(1800, 7000)]) * ramp(sec, [(0, 0), (0.3, 0.5), (1, 0.0)])
    _add(out, 0.5 * modes(0.2, [820.0, 1310.0], [0.05, 0.03]), 0.3)
    return run(out, [hp(70), lp(8000), norm(-9.0)])


def syn_panel_off(name):
    """And going back to sleep."""
    sec = 0.4
    out = 0.5 * sweep(sec, 420.0, 90.0, 0.7) * ramp(sec, [(0, 0.9), (1, 0.0)])
    out += 0.2 * sine(sec, 220.0) * dec(sec, 0.1)
    return run(out, [lp(5000), norm(-12.0)])


def syn_connect(name):
    """A circuit completing: two tones a fifth apart, the second arriving as the first ends.
    The only moment in the game that is allowed to sound like good news."""
    sec = 0.5
    out = 0.55 * sine(sec, 784.0) * dec(sec, 0.13)
    _add(out, 0.45 * sine(0.4, 1175.0) * dec(0.4, 0.11), 0.07)
    _add(out, 0.2 * sine(0.3, 1568.0) * dec(0.3, 0.07), 0.13)
    out += 0.15 * sweep(sec, 300.0, 900.0, 1.5) * dec(sec, 0.06)
    return run(out, [hp(250), norm(-9.0)])


def syn_pulse(name):
    """The charge running from the capacitor bank to the relay: a surge that travels, then
    arrives. Matches the single bright pulse the panel draws along the solved route."""
    rng = seeded(name)
    sec = 0.75
    out = 0.5 * sweep(sec, 90.0, 520.0, 2.0) * ramp(sec, [(0, 0), (0.08, 0.8), (0.75, 1.0), (1, 0.0)])
    out += 0.35 * run(noise(sec, rng), [bp(1200, 8000)]) * ramp(sec, [(0, 0), (0.1, 0.4), (0.7, 0.7), (1, 0.0)])
    _add(out, 0.6 * modes(0.3, [392.0, 588.0, 988.0], [0.1, 0.07, 0.04], [1.0, 0.6, 0.3]), 0.62)
    return run(out, [hp(60), lp(9000), norm(-7.0)])


def syn_repair_done(name):
    """A machine's wiring finished: the same warmth as a lamp coming back on, because it is
    the same feeling - something on this outpost works again."""
    sec = 1.1
    hum = 0.5 * sine(sec, 110.0) + 0.25 * sine(sec, 220.0) + 0.12 * sine(sec, 330.0)
    out = hum * ramp(sec, [(0, 0), (0.1, 0.9), (0.35, 0.75), (1, 0.0)])
    _add(out, 0.4 * sine(0.6, 659.0) * dec(0.6, 0.18), 0.05)
    _add(out, 0.3 * sine(0.5, 988.0) * dec(0.5, 0.14), 0.16)
    return run(out, [hp(80), lp(6500), norm(-8.0)])


# ---------------------------------------------------------------- the cargo box and the panes
def syn_box_boom(name):
    """The cargo box struck: a big steel shell ringing round the air inside it. Low
    inharmonic modes - a hollow body, not a note - detuned a little per variant."""
    rng = seeded(name)
    sec = 0.7
    out = modes(sec, [71.0, 109.0, 163.0, 238.0, 351.0, 517.0], [0.3, 0.24, 0.15, 0.1, 0.06, 0.035],
                [1.0, 0.8, 0.55, 0.4, 0.25, 0.15], detune=0.04, rng=rng)
    out += 0.6 * sine(sec, 48.0) * dec(sec, 0.07)
    return run(out, [hp(40), lp(2400), norm(-6.0)])


def syn_steel_stress(name):
    """Steel giving under a boot: the panel buckles in with a dull pop, a crack runs through
    it in a few dry ticks, and the metal pings - short, inharmonic, over a bright tear."""
    rng = seeded(name)
    sec = 0.45
    out = 0.7 * sweep(sec, 640.0, 210.0, 0.4) * dec(sec, 0.045)
    _add(out, 0.55 * run(noise(0.12, rng), [bp(1800, 8500)]) * ramp(0.12, [(0, 0), (0.08, 1.0), (0.4, 0.5), (1, 0)]), 0.02)
    at = 0.03
    for k in range(int(rng.integers(3, 6))):
        _add(out, 0.45 * run(noise(0.008, rng), [bp(2500, 9500), fade(0.0005, 0.005)]), at)
        at += rng.uniform(0.012, 0.03)
    ping = modes(0.4, [1170.0, 1810.0, 2630.0, 3570.0], [0.09, 0.06, 0.04, 0.025], [1.0, 0.7, 0.45, 0.3],
                 detune=0.03, rng=rng)
    _add(out, 0.45 * ping, 0.01)
    return run(out, [hp(120), lp(9500), norm(-5.0)])


def syn_box_groan(name):
    """The box about to go: its shell bending under the weight. A low tone sags while the
    seams stick and slip faster and faster; it peaks as it gives (0.45 s in, WindowCracks.GROAN)
    and the burst takes over."""
    rng = seeded(name)
    sec = 0.85
    t = np.linspace(0.0, sec, _ns(sec))
    bend = np.sin(TAU * np.cumsum(152.0 - 52.0 * (t / sec) ** 1.3) / SR)
    slip = np.abs(np.sin(TAU * np.cumsum(7.0 + 26.0 * (t / sec) ** 1.5) / SR)) ** 6
    creak = run(noise(sec, rng), [bp(420, 2600)]) * slip
    body = 0.5 * bend * (0.6 + 0.4 * slip) + 0.7 * creak + 0.25 * sine(sec, 233.0) * slip
    shape = ramp(sec, [(0, 0), (0.1, 0.45), (0.53, 1.0), (0.7, 0.5), (1, 0.0)])
    return run(body * shape, [hp(45), lp(3200), space(0.2, 0.35, 0.023), norm(-5.0)])


def syn_pane_mend(name):
    """A smashed pane sealed: a breath of air drawn across the gap, then the new glass
    setting with a clear ring that never resolves - inharmonic, like real glass, not a chime."""
    rng = seeded(name)
    sec = 1.25
    out = np.zeros(_ns(sec))
    seal = run(noise(0.3, rng), [bp(1500, 7000)]) * ramp(0.3, [(0, 0), (0.75, 1.0), (1, 0.0)])
    _add(out, 0.35 * seal, 0.0)
    ring = modes(0.95, [1297.0, 2083.0, 2931.0, 4012.0, 5410.0], [0.32, 0.22, 0.15, 0.1, 0.07],
                 [1.0, 0.7, 0.5, 0.35, 0.2], detune=0.01, rng=rng)
    ring *= 1.0 - 0.25 * (0.5 + 0.5 * np.sin(TAU * 11.0 * sig(0.95)))
    _add(out, 0.6 * ring, 0.22)
    _add(out, 0.3 * sine(0.5, 310.0) * dec(0.5, 0.16), 0.22)        # the frame taking it
    return run(out, [hp(200), lp(9500), norm(-6.0)])


# ---------------------------------------------------------------- the bot and reserve power
def syn_bot_boot(name):
    """The bot coming out of hibernation, in step with its wake animation (bot_gen.py: 10
    frames at 10 fps, eyes flickering on at frames 2, 4 off, 5): a relay clack, a servo whine
    rising as it straightens and lifts off the cradle, two dry ticks as the eyes catch, and a
    settling pair of blips at an inharmonic ratio - awake, not a jingle."""
    rng = seeded(name)
    sec = 1.15
    out = np.zeros(_ns(sec))
    _add(out, 0.55 * modes(0.14, [1650.0, 2710.0, 3930.0], [0.03, 0.02, 0.012], [1.0, 0.6, 0.35]), 0.0)
    out += 0.4 * sweep(sec, 95.0, 430.0, 1.6) * ramp(sec, [(0, 0), (0.1, 0.0), (0.2, 0.7), (0.8, 0.9), (0.95, 0.0), (1, 0)])
    out += 0.15 * run(noise(sec, rng), [bp(1200, 6000)]) * ramp(sec, [(0, 0), (0.15, 0.4), (0.8, 0.3), (1, 0)])
    for at in (0.2, 0.5):                                # the eyes catching
        _add(out, 0.5 * run(noise(0.03, rng), [bp(2200, 7500), fade(0.001, 0.02)]), at)
    _add(out, 0.35 * sine(0.25, 1180.0) * dec(0.25, 0.07), 0.86)
    _add(out, 0.28 * sine(0.25, 1730.0) * dec(0.25, 0.06), 0.93)
    return run(out, [hp(80), lp(8500), norm(-7.0)])


def syn_bot_chirp(name):
    """The bot's voice as it types: a tiny two-blip chirp with a little glide. Each variant
    picks its own pitches at an inharmonic ratio, so a sentence never spells out a tune."""
    rng = seeded(name)
    sec = rng.uniform(0.06, 0.09)
    f0 = rng.uniform(900.0, 1500.0)
    out = 0.6 * sweep(sec, f0, f0 * rng.uniform(1.08, 1.22), 1.0) * dec(sec, sec * 0.45)
    _add(out, 0.35 * sine(sec * 0.6, f0 * rng.uniform(1.31, 1.47)) * dec(sec * 0.6, sec * 0.2), sec * 0.35)
    return run(out, [hp(500), lp(7000), norm(-14.0)])


def syn_bot_hover(name):
    """The bot flying with you: a soft airy lift-fan hum with a slow wobble, so it is there
    when you listen for it and gone when you don't. 2 s, seamless (loop_noise, whole cycles)."""
    rng = seeded(name)
    sec = 2.0
    t = sig(sec)
    wob = 0.5 + 0.5 * np.sin(TAU * 1.5 * t)
    body = (0.35 * sine(sec, 172.0) * (0.7 + 0.3 * wob) + 0.18 * sine(sec, 251.0) * (1.0 - 0.4 * wob)
            + 0.45 * loop_noise(sec, rng, 700, 4200, -0.7) * (0.6 + 0.4 * loop_lfo(sec, rng, 0.5, 2.0)))
    return run(body, [bp(120, 5200), rms_to(-27.0), limit()])


def syn_reserve_on(name):
    """Reserve power coming on, the way InteriorFX draws it: a heavy relay clunk, then the
    emergency circuits stuttering up - the hum gated on at 0, 0.27, 0.54, 0.81 s for 0.15 s
    each, steady from 0.95 s - then settling into a low breath. 1.8 s."""
    rng = seeded(name)
    sec = 1.8
    t = sig(sec)
    out = np.zeros(_ns(sec))
    _add(out, 0.8 * modes(0.4, [62.0, 97.0, 151.0, 233.0], [0.16, 0.11, 0.07, 0.04], [1.0, 0.7, 0.45, 0.25]), 0.0)
    _add(out, 0.4 * run(noise(0.05, rng), [bp(900, 5000), fade(0.001, 0.04)]), 0.0)
    gate = ((np.mod(t, 0.27) < 0.15) | (t > 0.95)).astype(float)
    hum = 0.45 * sine(sec, 92.0) + 0.25 * sine(sec, 139.0) + 0.12 * sine(sec, 287.0) + 0.08 * run(noise(sec, rng), [bp(1500, 4000)])
    out += hum * gate * ramp(sec, [(0, 0.5), (0.53, 0.85), (0.75, 0.7), (1, 0.0)])
    return run(out, [hp(40), lp(6000), fade(0.002, 0.3), norm(-6.0)])


def _add(dst, src, at_sec):
    """Mix src into dst starting at at_sec (clipped to dst)."""
    i = _ns(at_sec) if at_sec > 0 else 0
    n = min(src.size, dst.size - i)
    if n > 0:
        dst[i:i + n] += src[:n]
    return dst


# ================================================================== the sounds
# One entry per sound the game asks for by name. Each is either recorded (`take`, and often
# `layer`), synthesised (`synth`), or both. `note` records WHY this source - the --probe
# numbers that justified it - and is copied into audio.json for whoever changes it next.
#
#   take    (pack, glob) -> every match is one variant the game picks between at random
#   layer   [(pack, glob, db, chain)] or [(synth_fn, db, chain)] mixed into every variant
#   chain   the mastering chain, applied last
#   bus     amb | sfx | ui          pitch  random pitch range per play, keeps repeats fresh
#   loop    plays forever until stopped (gets a `smpl` chunk so Godot loops it seamlessly)
#   dist    how far away it can still be heard, in map pixels (positional sounds only)
#   fade    seconds to fade a loop in and out
STEP_CHAIN = [trim(), hp(110), lp(8200), fade(0.003, 0.05), rms_to(-20.0), declick()]
BED = dict(bus='amb', loop=True, fade=1.6)

RECIPES = {
    # ---------------------------------------------------------------- the three lands
    'amb_red': dict(
        BED, gain_db=-9.0,
        take=('jc_nature_vol1', '*Weather_Desert Wind.mp3'),
        chain=[cut(14.0, 17.0), loopify(16.0, 1.0), hp(45), lp(7000), tilt(-1.0),
               rms_to(-21.0), declick()],
        note='JC Desert Wind: centroid 414 Hz, 64% of energy below 300 Hz, 0.0 onsets/s - '
             'broad dusty wind with body and no wildlife. Tilted down for thin air.'),
    'amb_forest': dict(
        BED, gain_db=-10.0,
        take=('jc_nature_vol1', '*Forest Enviroments_Enchanted Forest.mp3'),
        layer=[('jc_nature_vol1', '*Weather_Mountain Peak.mp3', -7.0,
                [cut(22.0, 13.0), loopify(12.0, 1.0), bp(500, 6000)]),
               (syn_alien_life, -4.0, [])],
        chain=[cut(20.0, 13.0), loopify(12.0, 1.0), hp(50), lp(8000), rms_to(-22.0), declick()],
        note='JC Enchanted Forest: centroid 239 Hz, 0.1 onsets/s - a deep drone with NO bird '
             'or insect transients (Forest Day/Pine/Rainforest measured 1-4/s of Earth fauna, '
             'wrong planet). Mountain Peak adds air; syn_alien_life adds this world\'s voices.'),
    'amb_ice': dict(
        BED, gain_db=-10.0,
        take=('jc_nature_vol1', '*Weather_Winter Wind.mp3'),
        layer=[('jc_nature_vol1', '*Weather_Mountain Peak.mp3', -9.0,
                [cut(30.0, 13.0), loopify(12.0, 1.0), bp(900, 8000)]),
               (syn_ice_groan, -5.0, [])],
        chain=[cut(26.0, 13.0), loopify(12.0, 1.0), hp(55), lp(8600), tilt(0.8),
               rms_to(-22.0), declick()],
        note='JC Winter Wind: centroid 410 Hz, stationarity 0.74 - steady cold wind. Mountain '
             'Peak (0.6% below 300 Hz) adds the thin whistle over the peaks; syn_ice_groan '
             'puts the frozen lakes under strain.'),
    'amb_suit': dict(BED, gain_db=-14.0, synth=syn_suit, chain=[declick()],
                     note='Synthesised: the helmet fan. Always present, so kept near silent.'),

    # ---------------------------------------------------------------- inside the dead base
    'amb_interior': dict(
        BED, gain_db=-8.0,
        take=('jc_nature_vol1', '*Weather_Fog.mp3'),
        chain=[cut(18.0, 13.0), loopify(12.0, 1.0), hp(38), lp(2600),
               space(0.3, 1.3, 0.055, circular=True), rms_to(-23.0), declick()],
        note='JC Fog: centroid 128 Hz, 97% below 300 Hz, flatness 0.000 - a pure low drone. '
             'Low-passed hard and given a big room: wind outside the smashed windows, heard '
             'from inside a dead building.'),
    'amb_gas_leak': dict(
        BED, gain_db=-16.0, dist=190.0,
        take=('oga_rubberduck_loops', 'noise_02.ogg'),
        chain=[loopify(3.0, 0.4), bp(900, 8000), rms_to(-24.0), declick()],
        note='rubberduck noise_02: 95.5% above 2 kHz, stationarity 0.87 - a steady hiss. '
             'Positioned on the oxygen generator\'s snapped pipe (fx.vapor).'),
    'spark': dict(
        bus='sfx', gain_db=-13.0, dist=230.0, pitch=(0.9, 1.12), variants=4, synth=syn_spark,
        note='Synthesised electrical arc. Drawn as solid pixels because additive light '
             'vanishes on the white machines; the sound does the same job for the ear.'),

    # ---------------------------------------------------------------- living scenery
    'amb_pool': dict(
        BED, gain_db=-13.0, dist=300.0,
        take=('oga_rubberduck_water', 'loop_bubbles_1.ogg'),
        layer=[('jc_nature_vol1', '*Water Enviroments_ Underground River .mp3', -8.0,
                [cut(30.0, 9.0), loopify(8.0, 0.8), bp(300, 4000)])],
        chain=[loopify(8.0, 0.8), hp(120), lp(6500), rms_to(-25.0), declick()],
        note='rubberduck loop_bubbles_1: 11.3 onsets/s - a proper burble. Underground River '
             '(stationarity 0.88, no transients) puts it in a hollow space.'),
    'amb_spire': dict(BED, gain_db=-15.0, dist=340.0, synth=syn_spire, chain=[declick()],
                      note='Synthesised: one slow inharmonic tone breathing with the crystal\'s '
                           'glow. Alien, and deliberately not a note.'),
    'amb_dome': dict(BED, gain_db=-13.0, dist=560.0, synth=syn_dome_hum, chain=[declick()],
                     layer=[('oga_rubberduck_loops', 'ambient_01.ogg', -6.0,
                             [loopify(4.0, 0.6), lp(1800)])],
                     note='Synthesised drone + rubberduck ambient_01 (centroid 221 Hz, '
                          'flatness 0.008 - a real tonal machine hum). Only the powered domes '
                          '(nursery, comms) get this; the base is dead and silent.'),
    'amb_wreck': dict(
        BED, gain_db=-12.0, dist=420.0,
        take=('jc_nature_vol1', '*Fire & Elemental_Dying Embers.mp3'),
        layer=[('oga_fire_crackling', 'fire-1.wav', -8.0, [trim(), loopify(2.6, 0.3), lp(1200)])],
        chain=[cut(12.0, 11.0), loopify(10.0, 1.0), hp(60), lp(7500), rms_to(-24.0), declick()],
        note='JC Dying Embers: 5.0 onsets/s, 61% below 300 Hz - crackle with weight, and the '
             'right name for a wreck that has been burning a while. fire-1 (centroid 261 Hz) '
             'adds the deep pops.'),
    'amb_lamp': dict(BED, gain_db=-19.0, dist=150.0, synth=syn_lamp_hum, chain=[declick()],
                     note='Synthesised: a repaired lamp, heard only from right under it.'),
    'beacon': dict(bus='sfx', gain_db=-15.0, dist=900.0, synth=syn_beacon,
                   note='Synthesised double blip, fired in step with the drawn strobe.'),

    # ---------------------------------------------------------------- boots on the ground
    'step_dust': dict(
        bus='sfx', gain_db=-10.0, dist=260.0, pitch=(0.92, 1.08),
        take=('kenney_impacts', 'footstep_grass_00*.ogg'),
        chain=[trim(), hp(90), lp(5200), tilt(-1.4), fade(0.003, 0.06), rms_to(-21.0), declick()],
        note='Kenney footstep_grass: 90.6% below 300 Hz - soft and granular, not leafy once '
             'the top is tilted off. Reads as boots in deep red dust.'),
    'step_moss': dict(
        bus='sfx', gain_db=-12.0, dist=240.0, pitch=(0.9, 1.06),
        take=('kenney_impacts', 'footstep_carpet_00*.ogg'),
        chain=[trim(), hp(80), lp(3800), fade(0.004, 0.08), rms_to(-23.0), declick()],
        note='Kenney footstep_carpet: the most muffled set in the pack. Damp forest moss.'),
    'step_snow': dict(
        bus='sfx', gain_db=-10.0, dist=260.0, pitch=(0.95, 1.06),
        take=('oga_corsica_snow', 'Corsica_S-Walking_on_snow_covered_gravel_0[1-6].flac'),
        chain=[trim(), hp(130), lp(9000), fade(0.003, 0.05), rms_to(-20.0), declick()],
        note='Corsica_S: real field recordings of single steps on snow over gravel, ~0.6 s '
             'each. The authentic crunch - nothing synthesised comes close.'),
    'step_metal': dict(
        bus='sfx', gain_db=-11.0, dist=300.0, pitch=(0.94, 1.07),
        take=('kenney_impacts', 'footstep_concrete_00*.ogg'),
        layer=[('kenney_impacts', 'impactPlate_light_000.ogg', -15.0, [trim(), bp(600, 6000), head(0.2)])],
        chain=STEP_CHAIN,
        note='Kenney footstep_concrete for the hard tile floor, with impactPlate_light '
             'underneath for the ring of a metal deck below it.'),

    # ---------------------------------------------------------------- the low-gravity jump
    'jump': dict(bus='sfx', gain_db=-13.0, dist=260.0, pitch=(0.97, 1.05), synth=syn_jump,
                 note='Synthesised suit servo and push-off.'),
    'land_soft': dict(
        bus='sfx', gain_db=-11.0, dist=300.0, pitch=(0.95, 1.06),
        take=('kenney_impacts', 'impactSoft_heavy_00[0-2].ogg'),
        layer=[('kenney_impacts', 'footstep_grass_002.ogg', -9.0, [trim(), hp(300), lp(6000)])],
        chain=[trim(), hp(55), lp(6000), fade(0.002, 0.1), rms_to(-18.0), declick()],
        note='Kenney impactSoft_heavy: centroid 61 Hz, 100% below 300 Hz - a pure dull thud. '
             'Grit from a footstep on top so it lands in dust.'),
    'land_hard': dict(
        bus='sfx', gain_db=-8.0, dist=380.0, pitch=(0.9, 1.0),
        take=('kenney_impacts', 'impactSoft_heavy_00[3-4].ogg'),
        layer=[('kenney_impacts', 'impactPlate_heavy_000.ogg', -8.0, [trim(), lp(900)]),
               ('kenney_impacts', 'footstep_grass_000.ogg', -8.0, [trim(), hp(300)])],
        chain=[trim(), hp(45), lp(6500), fade(0.001, 0.14), rms_to(-15.0), limit(), declick()],
        note='The same thud with impactPlate_heavy (95% below 300 Hz) for the drop from height.'),
    'slide': dict(
        bus='sfx', gain_db=-14.0, dist=280.0, loop=True, fade=0.12,
        take=('oga_rubberduck_loops', 'rolling.ogg'),
        chain=[pitch(0.55), loopify(1.4, 0.25), bp(180, 4000), rms_to(-23.0), declick()],
        note='rubberduck rolling.ogg pitched down: a continuous scrape for skidding down '
             'ground too steep to stand on.'),

    # ---------------------------------------------------------------- the multitool
    'tool_unfold': dict(bus='sfx', gain_db=-9.0, dist=300.0, synth=syn_unfold,
                        layer=[('oga_rubberduck_metalwood', 'metal_spring_01.ogg', -14.0,
                                [trim(), bp(1200, 8000), head(0.5)])],
                        note='Synthesised servo, plate clacks and lock-on, timed to the 18-frame '
                             'equip animation at 20 fps. Real spring metal on top for bite.'),
    'tool_fold': dict(bus='sfx', gain_db=-11.0, dist=280.0, synth=syn_fold,
                      note='The reverse, at the 1.3x the animation plays backwards at.'),
    'tool_lens': dict(bus='sfx', gain_db=-13.0, dist=240.0, synth=syn_lens,
                      note='The lens lighting on equip frame 14.'),
    'tool_target': dict(bus='ui', gain_db=-20.0, synth=syn_prompt,
                        note='The job icon appearing over a new target. Near-threshold.'),
    'beam_mine': dict(bus='sfx', gain_db=-11.0, dist=320.0, loop=True, fade=0.08,
                      synth=syn_beam_mine, chain=[declick()],
                      note='Synthesised, gated at the 7 Hz the beam is drawn pulsing at.'),
    'beam_gather': dict(bus='sfx', gain_db=-13.0, dist=280.0, loop=True, fade=0.06,
                        synth=syn_beam_gather, chain=[declick()],
                        note='Synthesised airy updraught for the spiral stream.'),
    'beam_fix': dict(bus='sfx', gain_db=-13.0, dist=280.0, loop=True, fade=0.1,
                     synth=syn_beam_fix, chain=[declick()],
                     note='Synthesised sweep at the 0.8 Hz the scan lines sweep at.'),
    'rock_crack': dict(
        bus='sfx', gain_db=-12.0, dist=340.0, pitch=(0.92, 1.1),
        take=('kenney_impacts', 'impactMining_00*.ogg'),
        chain=[trim(), hp(90), lp(8000), fade(0.002, 0.08), rms_to(-20.0), declick()],
        note='Kenney impactMining: made for exactly this, 92% below 300 Hz. Fires as the '
             'cracks spread, not continuously.'),
    'rock_burst': dict(
        bus='sfx', gain_db=-7.0, dist=460.0, pitch=(0.94, 1.05),
        take=('oga_rubberduck_breaking', 'bfh1_rock_breaking_0[1-3].ogg'),
        layer=[('kenney_impacts', 'impactMining_002.ogg', -6.0, [trim(), lp(1400)]),
               (lambda n: run(sine(0.4, 58.0) * dec(0.4, 0.13), [norm(-6.0)]), -9.0, [])],
        chain=[trim(), hp(60), lp(9500), fade(0.001, 0.2), rms_to(-14.0), limit(), declick()],
        note='rubberduck rock_breaking (12.7 onsets/s of debris) + impactMining for the low '
             'end + a synthesised sub thump, because the camera shakes 2.6 px here.'),
    'gather_pop': dict(bus='sfx', gain_db=-13.0, dist=260.0, pitch=(0.97, 1.06),
                       synth=syn_gather_pop,
                       layer=[('oga_rubberduck_sfx100v2', 'sfx100v2_stones_01.ogg', -13.0,
                               [trim(), hp(1200), head(0.25)])],
                       note='Synthesised chime for the thing vanishing into the lens, with real '
                            'stone grit so it stays a rock and not a UI noise.'),
    'lift_grab': dict(bus='sfx', gain_db=-11.0, dist=280.0, synth=syn_lift_grab,
                      note='Synthesised: the violet tether taking hold.'),
    'lift_loop': dict(bus='sfx', gain_db=-17.0, dist=240.0, loop=True, fade=0.25,
                      synth=syn_lift_loop, chain=[declick()],
                      note='Synthesised thrum while a crate follows you.'),
    'lift_drop': dict(
        bus='sfx', gain_db=-10.0, dist=340.0, pitch=(0.93, 1.06),
        take=('oga_rubberduck_breaking', 'bfh1_wood_falling_0[1-2].ogg'),
        layer=[('kenney_impacts', 'impactSoft_heavy_001.ogg', -7.0, [trim(), lp(700)])],
        chain=[trim(), hp(60), lp(7000), fade(0.001, 0.15), rms_to(-17.0), declick()],
        note='A cargo crate settling: real wood fall plus a soft heavy thud for the mass.'),
    'lamp_on': dict(bus='sfx', gain_db=-10.0, dist=380.0, synth=syn_lamp_on,
                    note='Synthesised: two struggling ticks, then warm light. The first thing '
                         'in the game you actually fix.'),

    # ---------------------------------------------------------------- storage's panes and the cargo box
    'cargo_land': dict(
        bus='sfx', gain_db=-10.0, dist=360.0, pitch=(0.94, 1.04),
        take=('kenney_impacts', 'impactMetal_heavy_00[0-2].ogg'),
        layer=[('oga_rubberduck_metalwood', 'metal_hit_0[34].ogg', -7.0, [trim(), lp(6000), rms_to(-20.0)]),
               (syn_box_boom, -9.0, [hp(90)])],
        chain=[trim(), hp(80), lp(8000), fade(0.001, 0.2), rms_to(-18.0), limit(), declick()],
        note='Landing on the cargo box. It plays over the astronaut\'s landing thud, so it carries '
             'only the steel: Kenney impactMetal_heavy (centroid 507-741 Hz, flatness 0.002-0.06 - a '
             'tonal clank) for the boots on its lid, rubberduck metal_hit 03/04 (centroid 1.9-3.1 kHz) '
             'for the lid ringing, syn_box_boom for the hollow shell under it.'),
    'cargo_crack': dict(
        bus='sfx', gain_db=-9.0, dist=380.0, pitch=(0.93, 1.05),
        take=('oga_rubberduck_metalwood', 'metal_sheet_0[356].ogg'),
        layer=[('oga_rubberduck_metalwood', 'wood_cracking_0[2-4].ogg', -4.0, [trim(), pitch(0.85), hp(1600)]),
               ('kenney_impacts', 'impactMetal_heavy_003.ogg', -6.0, [trim(), lp(1200)]),
               (syn_steel_stress, -3.0, [])],
        chain=[trim(), hp(70), lp(9500), fade(0.001, 0.15), rms_to(-16.0), limit(), declick()],
        note='The box cracking under you, once per pane: rubberduck metal_sheet 03/05/06 (centroid '
             '1.4-2.0 kHz, 54-71% in the mids) - a steel wall buckling. wood_cracking (92-98% above '
             '2 kHz), high-passed so no wood body is left, is the fracture running; impactMetal_heavy '
             'the weight on it; syn_steel_stress the ping of steel giving.'),
    'cargo_groan': dict(
        bus='sfx', gain_db=-9.0, dist=380.0, pitch=(0.96, 1.03),
        synth=syn_box_groan,
        layer=[('oga_rubberduck_metalwood', 'wood_squeak_01.ogg', -1.0,
                [trim(), pitch(0.5), bp(300, 3200), rms_to(-20.0)]),
               ('oga_rubberduck_metalwood', 'metal_sheet_04.ogg', -5.0, [trim(), pitch(0.6), lp(2800), rms_to(-20.0)])],
        chain=[hp(70), lp(7000), fade(0.002, 0.2), rms_to(-18.0), limit(), declick()],
        note='The box about to give way (0.45 s before it bursts): syn_box_groan, a sagging tone '
             'with the seams slipping faster and faster. rubberduck wood_squeak_01 (8.4 onsets/s, '
             'centroid 2.8 kHz) pitched down to 0.45 becomes a slow metal creak; metal_sheet_04 '
             '(27.6% below 300 Hz) at 0.6 the shell bending.'),
    'cargo_burst': dict(
        bus='sfx', gain_db=-6.0, dist=480.0, pitch=(0.95, 1.04),
        take=('kenney_impacts', 'impactPlate_heavy_00[13].ogg'),
        layer=[('oga_rubberduck_metalwood', 'metal_slam_01.ogg', 2.0, [trim(), lp(6000), rms_to(-20.0)]),
               ('oga_rubberduck_breaking', 'bfh1_metal_falling_0[12].ogg', -2.0, [trim(), rms_to(-20.0)]),
               ('oga_rubberduck_metalwood', 'metal_falling_01.ogg', -9.0, [trim(), hp(400), rms_to(-20.0), delay(0.1)]),
               (lambda n: run(sweep(0.7, 64.0, 30.0, 0.6) * dec(0.7, 0.2), [norm(-5.0)]), -4.0, [])],
        chain=[trim(), hp(35), lp(9500), fade(0.001, 0.35), rms_to(-13.0), limit(), declick()],
        note='The box giving way and crushing flat: Kenney impactPlate_heavy (55-58 Hz) and a falling '
             'sub for the weight - the camera shakes 2.6 px - under rubberduck metal_slam_01 (53.5% '
             'below 300 Hz), the walls hitting the floor; bfh1_metal_falling 01/02 (centroid 2.4-2.7 '
             'kHz, 4-5 onsets/s), sheet steel coming down; metal_falling_01 (76% above 2 kHz) '
             'clattering just after. Layers levelled with rms_to: the raw falls differ by 7 dB.'),
    'cargo_drop': dict(
        bus='sfx', gain_db=-9.0, dist=360.0, pitch=(0.92, 1.03),
        take=('kenney_impacts', 'impactMetal_heavy_00[0-2].ogg'),
        layer=[('kenney_impacts', 'impactPlate_heavy_00[234].ogg', -5.0, [trim(), lp(900), rms_to(-20.0)]),
               ('oga_rubberduck_breaking', 'bfh1_metal_hit_05.ogg', -4.0, [trim(), lp(2000), rms_to(-20.0)]),
               ('oga_rubberduck_metalwood', 'metal_hit_04.ogg', -9.0, [trim(), hp(1500), rms_to(-22.0), delay(0.06)]),
               (syn_box_boom, -10.0, [pitch(0.85), hp(70)])],
        chain=[trim(), hp(50), lp(7500), fade(0.001, 0.2), rms_to(-16.0), limit(), declick()],
        note='The tool setting the cargo box down (its drop_sound): Kenney impactMetal_heavy (centroid '
             '507-741 Hz) for its steel base meeting the floor, impactPlate_heavy (55-78 Hz) under it '
             'for the mass, rubberduck bfh1_metal_hit_05 (289 Hz, a dull heavy steel hit), and '
             'metal_hit_04 (3.1 kHz) a moment later: the rations inside shifting. lift_drop is wood - '
             'right for crates, wrong for this.'),
    'ration_land': dict(
        bus='sfx', gain_db=-13.0, dist=280.0, pitch=(0.94, 1.1),
        take=('kenney_impacts', 'impactGeneric_light_00[0-3].ogg'),
        layer=[('kenney_impacts', 'impactSoft_medium_00[0-3].ogg', -6.0, [trim(), lp(400), rms_to(-20.0)]),
               ('oga_rubberduck_sfx100v2', 'sfx100v2_items_0[12].ogg', -4.0,
                [trim(), head(0.16), hp(1800), fade(0.001, 0.06), rms_to(-22.0)])],
        chain=[trim(), hp(70), lp(8000), fade(0.001, 0.08), rms_to(-21.0), declick()],
        note='A ration pack landing after the box bursts: Kenney impactGeneric_light (centroid '
             '300-511 Hz, 38-54% in the mids) for the pouch slapping the floor, impactSoft_medium '
             '(60-87 Hz) under it for a full pouch\'s weight, rubberduck items 01/02 (76-97% above '
             '2 kHz) cut to 160 ms for the foil. Four land one after another, so four variants.'),
    'pane_mend': dict(
        bus='sfx', gain_db=-10.0, dist=420.0,
        synth=syn_pane_mend,
        layer=[('kenney_impacts', 'impactGlass_light_001.ogg', -9.0, [trim(), hp(600), delay(0.22)])],
        chain=[hp(150), lp(9800), fade(0.002, 0.3), rms_to(-20.0), declick()],
        note='A smashed pane mended: syn_pane_mend draws air across the gap, then the new glass sets '
             'with an inharmonic ring. Kenney impactGlass_light_001 (centroid 1.3 kHz, flatness 0.006 '
             '- a clean tonal tap) lands with the ring, so it is a real pane. Played where the pane '
             'is mended (for now, landing on the box under it).'),

    # ---------------------------------------------------------------- the airlock
    'door_prompt': dict(bus='ui', gain_db=-18.0, synth=syn_prompt,
                        note='[E] ENTER appearing.'),
    'door_unseal': dict(
        bus='sfx', gain_db=-7.0, dist=460.0,
        take=('oga_rubberduck_metalwood', 'lock_open_01.ogg'),
        layer=[('oga_rubberduck_metalwood', 'metal_open_01.ogg', -5.0, [trim(), lp(5000)]),
               ('kenney_impacts', 'impactMetal_heavy_000.ogg', -8.0, [trim(), lp(2500)])],
        chain=[trim(), hp(60), lp(8500), fade(0.001, 0.2), rms_to(-14.0), limit(), declick()],
        note='rubberduck lock_open (9.5 onsets/s of mechanism) over metal_open and a heavy '
             'metal impact: the seal letting go of a door 1.6x the astronaut\'s height.'),
    'door_vent': dict(
        bus='sfx', gain_db=-9.0, dist=440.0,
        take=('oga_rubberduck_sfx100v2', 'sfx100v2_air_01.ogg'),
        chain=[trim(), bp(500, 9000), env([(0, 0), (0.04, 1.0), (0.4, 0.5), (1, 0.0)]),
               rms_to(-17.0), declick()],
        note='rubberduck air_01: 89.7% above 2 kHz - pressurised air. Shaped to a burst that '
             'matches the 28-puff gas cloud the door throws.'),
    'door_slide': dict(
        bus='sfx', gain_db=-11.0, dist=420.0, loop=True, fade=0.05,
        take=('oga_rubberduck_metalwood', 'metal_sheet_03.ogg'),
        layer=[(syn_servo, -5.0, [])],
        chain=[loopify(0.6, 0.12), bp(90, 7000), rms_to(-19.0), declick()],
        note='Real sheet metal moving, with a synthesised servo under it: heavy slab, powered '
             'mechanism. Looped while the halves travel.'),
    'door_close': dict(
        bus='sfx', gain_db=-8.0, dist=460.0,
        take=('oga_rubberduck_metalwood', 'metal_slam_01.ogg'),
        layer=[('kenney_impacts', 'impactPlate_heavy_001.ogg', -7.0, [trim(), lp(1100)])],
        chain=[trim(), hp(55), lp(8000), fade(0.001, 0.25), rms_to(-14.0), limit(), declick()],
        note='metal_slam over a heavy plate: the door sealing behind you.'),
    'door_lamp': dict(bus='sfx', gain_db=-21.0, dist=240.0, synth=syn_beacon,
                      chain=[pitch(1.6), lp(6000), norm(-11.0)],
                      note='The amber warning light ticking while the door works.'),

    # ---------------------------------------------------------------- the crash
    'crash_roar': dict(bus='sfx', gain_db=-6.0, dist=4000.0, loop=True, fade=0.4,
                       synth=syn_roar, chain=[declick()],
                       note='Synthesised re-entry: pressure and tearing in a thin atmosphere.'),
    'crash_impact': dict(
        bus='sfx', gain_db=-3.0, dist=4000.0,
        take=('oga_rubberduck_sfx100v2', 'sfx100v2_thunder_01.ogg'),
        layer=[('kenney_impacts', 'impactPlate_heavy_003.ogg', -5.0, [trim(), lp(1600)]),
               (lambda n: run(sweep(0.9, 70.0, 28.0, 0.5) * dec(0.9, 0.3), [norm(-4.0)]), -4.0, [])],
        chain=[trim(), hp(30), lp(9000), head(3.2), fade(0.001, 0.8), rms_to(-11.0), limit(), declick()],
        note='rubberduck thunder_01 (5.3 s, 63.6% below 300 Hz) plus a heavy plate and a '
             'synthesised falling sub: the touchdown that shakes the camera 5 px.'),
    'crash_skid': dict(
        bus='sfx', gain_db=-8.0, dist=3000.0, loop=True, fade=0.25,
        take=('oga_rubberduck_loops', 'rolling.ogg'),
        layer=[('jc_nature_vol1', '*Weather_Heavy Thunderstorm.mp3', -7.0,
                [cut(40.0, 1.6), loopify(1.4, 0.3), lp(400)])],
        chain=[pitch(0.42), loopify(1.4, 0.3), hp(40), lp(3500), rms_to(-16.0), limit(), declick()],
        note='The satellite ploughing its trench: rolling pitched right down, with the low end '
             'of a thunderstorm under it for mass.'),
    'debris': dict(
        bus='sfx', gain_db=-12.0, dist=900.0, pitch=(0.9, 1.12),
        take=('oga_rubberduck_breaking', 'bfh1_rock_falling_0[1-4].ogg'),
        chain=[trim(), hp(80), lp(8500), fade(0.002, 0.15), rms_to(-20.0), declick()],
        note='Real rock falling: what comes down after the impact.'),

    # ---------------------------------------------------------------- the backpack
    'ui_bag_open': dict(
        bus='ui', gain_db=-14.0,
        take=('oga_rubberduck_metalwood', 'keys_01.ogg'),
        chain=[trim(), head(0.45), hp(220), lp(7500), env([(0, 0), (0.03, 1.0), (1, 0.0)]),
               rms_to(-20.0), declick()],
        note='rubberduck keys_01: real buckle and strap metal. The backpack is a thing you '
             'open, not a menu that appears.'),
    'ui_bag_close': dict(
        bus='ui', gain_db=-15.0,
        take=('oga_rubberduck_metalwood', 'keys_04.ogg'),
        chain=[trim(), head(0.35), hp(220), lp(6000), env([(0, 0), (0.03, 1.0), (1, 0.0)]),
               rms_to(-21.0), declick()],
        note='The same buckle, shorter and duller: closing it.'),
    'ui_slot': dict(bus='ui', gain_db=-21.0, pitch=(0.97, 1.05), synth=syn_slot,
                    note='Moving along the hotbar. Near-threshold: it happens constantly.'),
    'ui_pick': dict(bus='ui', gain_db=-16.0, synth=syn_pick,
                    note='Lifting an item out of a slot.'),
    'ui_place': dict(bus='ui', gain_db=-16.0, synth=syn_place,
                     layer=[('oga_rubberduck_sfx100v2', 'sfx100v2_items_01.ogg', -16.0,
                             [trim(), hp(1500), head(0.12)])],
                     note='Putting it back, with a real handling tick so it has an object in it.'),
    'ui_deny': dict(bus='ui', gain_db=-14.0, synth=syn_deny,
                    note='The backpack is full - the one failure the player meets regularly, '
                         'so it says no without scolding.'),

    # ---------------------------------------------------------------- the circuit panel
    'ui_panel_open': dict(
        bus='ui', gain_db=-11.0, synth=syn_panel_on,
        layer=[('oga_rubberduck_metalwood', 'lock_open_01.ogg', -13.0, [trim(), lp(5000), head(0.4)])],
        note='A dead service panel coming alive: a real latch, then a synthesised screen '
             'finding its feet.'),
    'ui_panel_close': dict(bus='ui', gain_db=-13.0, synth=syn_panel_off,
                           note='The screen going back to sleep.'),
    'wire_turn': dict(
        bus='ui', gain_db=-17.0, pitch=(0.94, 1.08),
        take=('kenney_impacts', 'impactMetal_light_00[0-2].ogg'),
        chain=[trim(), head(0.18), hp(700), lp(9000), fade(0.001, 0.09), rms_to(-22.0), declick()],
        note='Kenney impactMetal_light (centroid 1684 Hz), cut short: one module clicking '
             'round a quarter turn. Three variants and a pitch spread, because solving a '
             'board is dozens of these.'),
    'wire_connect': dict(bus='ui', gain_db=-11.0, synth=syn_connect,
                         note='The circuit completing.'),
    'power_pulse': dict(bus='sfx', gain_db=-9.0, synth=syn_pulse,
                        note='The charge running the solved route to the relay, timed to the '
                             'pulse the panel draws.'),
    'repair_done': dict(bus='sfx', gain_db=-9.0, synth=syn_repair_done,
                        note='A machine\'s wiring finished: the warmth of lamp_on, because it '
                             'is the same feeling - something here works again.'),

    # ---------------------------------------------------------------- the bot and reserve power
    'bot_boot': dict(bus='sfx', gain_db=-9.0, dist=360.0, synth=syn_bot_boot,
                     note='The bot waking, timed to its 1 s wake animation: relay clack, rising '
                          'servo, two ticks as its eyes catch, two inharmonic blips.'),
    'bot_chirp': dict(bus='ui', gain_db=-20.0, pitch=(0.94, 1.08), variants=5, synth=syn_bot_chirp,
                      note='The bot\'s voice while its words type out, every few letters. Five '
                           'variants at inharmonic ratios and a pitch spread: a sentence never '
                           'becomes a tune. Near-threshold, like the UI ticks.'),
    'bot_hover': dict(bus='sfx', gain_db=-18.0, dist=200.0, loop=True, fade=0.4, synth=syn_bot_hover,
                      chain=[declick()],
                      note='The bot following you: a soft lift-fan hum, heard only close by. Seamless 2 s.'),
    'reserve_on': dict(bus='sfx', gain_db=-8.0, synth=syn_reserve_on,
                       note='Reserve power: a relay clunk, then the emergency hum stuttering on '
                            'in step with the flicker InteriorFX draws on the emergency lines.'),

    # ---------------------------------------------------------------- UI
    'ui_map_open': dict(bus='ui', gain_db=-13.0,
                        take=('oga_rubberduck_sfx100v2', 'sfx100v2_switch_01.ogg'),
                        chain=[trim(), hp(300), lp(9000), fade(0.001, 0.04), rms_to(-19.0), declick()],
                        note='A real switch: the map screen is a physical thing on the suit.'),
    'ui_map_close': dict(bus='ui', gain_db=-13.0,
                         take=('oga_rubberduck_sfx100v2', 'sfx100v2_switch_02.ogg'),
                         chain=[trim(), hp(300), lp(9000), fade(0.001, 0.04), rms_to(-19.0), declick()],
                         note='The same switch, the other way.'),
    'ui_zoom': dict(bus='ui', gain_db=-22.0, synth=syn_zoom, note='A zoom step.'),
    'ui_room': dict(bus='ui', gain_db=-16.0, synth=syn_toast,
                    note='A room name fading in on the toast plate.'),
}


# ================================================================== baking
def build(name, spec):
    """Turn one recipe into its finished variants (a list of float arrays)."""
    layers = spec.get('layer', [])
    variants = []
    if 'take' in spec:
        pack, pattern = spec['take']
        srcs = take(pack, pattern)
        want = spec.get('variants', len(srcs))
        for path in srcs[:want]:
            variants.append(decode(path))
    if 'synth' in spec:
        n = spec.get('variants', 1) if 'take' not in spec else 0
        for k in range(n):
            variants.append(spec['synth'](f'{name}:{k}'))
        if 'take' in spec:                               # synthesis mixed into every take
            layers = list(layers) + [(spec['synth'], 0.0, [])]
    if not variants:
        raise SystemExit(f'{name}: recipe has neither take nor synth')

    out = []
    for i, x in enumerate(variants):
        x = run(x, [dc()])
        for layer in layers:
            if callable(layer[0]):
                fn, db, chain = layer
                y = run(fn(f'{name}:layer:{i}'), chain)
            else:
                pack, pattern, db, chain = layer
                hits = take(pack, pattern)
                y = run(decode(hits[i % len(hits)]), chain)
            y = y * 10 ** (db / 20.0)
            n = max(x.size, y.size)
            x = np.pad(x, (0, n - x.size)) + np.pad(y, (0, n - y.size))
        chain = spec.get('chain', [trim(), norm(-4.0), declick()])
        out.append(run(x, list(chain) + [limit(0.95), ceil_at(-0.8)]))
    return out


def write_wav(path, x, loop=False):
    """16-bit mono PCM. Looping sounds carry a `smpl` chunk: Godot's WAV importer reads it and
    loops the whole file, with no .import editing and no runtime guessing."""
    pcm = np.clip(x, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype('<i2').tobytes()
    frames = len(pcm) // 2
    chunks = [b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, SR, SR * 2, 2, 16)]
    if loop:
        chunks.append(b'smpl' + struct.pack('<I9I', 36 + 24, 0, 0, int(1e9 // SR), 60, 0, 0, 0, 1, 0)
                      + struct.pack('<6I', 0, 0, 0, max(0, frames - 1), 0, 0))
    chunks.append(b'data' + struct.pack('<I', len(pcm)) + pcm)
    body = b'WAVE' + b''.join(chunks)
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', len(body)) + body)
    return frames


## Which part of the game a sound belongs to, for SOURCES.md and the viewer.
GROUPS = [
    ('amb_', 'Ambience: the air of a place'),
    ('step_', 'Boots on the ground'),
    ('jump', 'The low-gravity jump'), ('land_', 'The low-gravity jump'),
    ('slide', 'The low-gravity jump'),
    ('tool_', 'The multitool'), ('beam_', 'The multitool'), ('rock_', 'The multitool'),
    ('gather_', 'The multitool'), ('lift_', 'The multitool'), ('lamp_', 'The multitool'),
    ('spark', 'Inside the dead base'),
    ('ui_bag', 'The backpack'), ('ui_slot', 'The backpack'), ('ui_pick', 'The backpack'),
    ('ui_place', 'The backpack'), ('ui_deny', 'The backpack'),
    ('ui_panel', 'The circuit panel'), ('wire_', 'The circuit panel'),
    ('power_pulse', 'The circuit panel'), ('repair_done', 'The circuit panel'),
    ('door_', 'The airlock'),
    ('cargo_', 'Storage: the cargo box and the panes'), ('ration_', 'Storage: the cargo box and the panes'),
    ('pane_', 'Storage: the cargo box and the panes'),
    ('crash_', 'The satellite crash'), ('debris', 'The satellite crash'),
    ('beacon', 'Lights and beacons'),
    ('ui_', 'Interface'),
]


def group_of(name):
    for prefix, title in GROUPS:
        if name.startswith(prefix):
            return title
    return 'Other'


def peaks_of(x, buckets=240):
    """min/max per bucket, for the waveform the viewer draws. Baked in so the page needs no
    fetch and works straight off the filesystem."""
    n = max(1, x.size // buckets)
    out = []
    for i in range(0, x.size, n):
        chunk = x[i:i + n]
        if chunk.size:
            out.append([round(float(chunk.min()), 2), round(float(chunk.max()), 2)])
    return out[:buckets]


def bake(only=None):
    os.makedirs(OUT, exist_ok=True)
    manifest = {
        'note': 'Written by tools/sfx_gen.py - do not edit by hand. Read by scripts/audio.gd. '
                'Sources and licences: SOURCES.md, CREDITS.md.',
        'format': {'rate': SR, 'bits': 16, 'channels': 1},
        'buses': BUSES,
        'credits': sorted({p['credit'] for p in PACKS.values()}),
        'sounds': {},
    }
    existing = {}
    man_path = os.path.join(OUT, 'audio.json')
    if only and os.path.exists(man_path):
        existing = json.load(open(man_path)).get('sounds', {})
    total = 0
    waves = {}
    prev_waves = {}
    wave_path = os.path.join(OUT, 'preview.json')
    if only and os.path.exists(wave_path):
        prev_waves = json.load(open(wave_path)).get('waves', {})
    for name, spec in RECIPES.items():
        if only and only not in name:
            if name in existing:
                manifest['sounds'][name] = existing[name]
                waves[name] = prev_waves.get(name, [])
            continue
        variants = build(name, spec)
        waves[name] = [peaks_of(x) for x in variants]
        files = []
        seconds = 0.0
        for i, x in enumerate(variants):
            fn = f'{name}_{i}.wav' if len(variants) > 1 else f'{name}.wav'
            frames = write_wav(os.path.join(OUT, fn), x, spec.get('loop', False))
            files.append(fn)
            seconds = max(seconds, frames / SR)
            total += frames * 2
        entry = {'files': files, 'bus': spec.get('bus', 'sfx'),
                 'gain_db': round(float(spec.get('gain_db', -6.0)), 2),
                 'loop': bool(spec.get('loop', False)), 'seconds': round(seconds, 3)}
        if 'pitch' in spec:
            entry['pitch'] = [round(float(spec['pitch'][0]), 3), round(float(spec['pitch'][1]), 3)]
        if 'dist' in spec:
            entry['dist'] = float(spec['dist'])
        if 'fade' in spec:
            entry['fade'] = float(spec['fade'])
        entry['note'] = ' '.join(spec.get('note', '').split())
        entry['group'] = group_of(name)
        manifest['sounds'][name] = entry
        print(f'  {name:<14} {len(files)} file(s)  {seconds:5.2f}s  '
              f'{"loop" if spec.get("loop") else "    "}  {entry["bus"]}')
    with open(man_path, 'w') as f:
        json.dump(manifest, f, indent=1)
        f.write('\n')
    with open(wave_path, 'w') as f:
        json.dump({'note': 'Waveforms for viewer.html. Not read by the game.',
                   'waves': waves}, f, separators=(',', ':'))
        f.write('\n')
    write_viewer(manifest, waves)
    write_credits()
    print(f'{len(manifest["sounds"])} sounds, {total / 1e6:.1f} MB of wav in assets/audio/')


VIEWER = r'''<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>GTFO sound</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&family=Nunito:wght@400;600;700&family=Pixelify+Sans:wght@500;700&display=swap">
<style>
  /* Generated by tools/sfx_gen.py. Same night palette as the sprite bench and the map viewer. */
  :root {
    --night: #0d0b17; --panel: #1c1829; --rule: #342c47; --cream: #f1e8dc;
    --lavender: #a99bb4; --coral: #ec7a5a; --teal: #4fc6b4; --mustard: #efb950;
    --violet: #b583ff; --font-display: 'Pixelify Sans', ui-monospace, monospace;
    --font-body: 'Nunito', system-ui, sans-serif; --font-data: 'JetBrains Mono', ui-monospace, monospace;
    color-scheme: dark;
  }
  * { box-sizing: border-box; }
  html, body { background: var(--night); color: var(--cream); }
  body { margin: 0; font: 15px/1.5 var(--font-body); padding: 22px clamp(16px, 2.5vw, 32px) 48px; }
  h1 { font: 700 30px/1.1 var(--font-display); margin: 0 0 6px; letter-spacing: .02em; }
  h2 { font: 700 16px/1.2 var(--font-display); margin: 30px 0 10px; color: var(--teal);
       letter-spacing: .06em; text-transform: uppercase; }
  .sub { color: var(--lavender); font-size: 13px; margin: 0 0 18px; max-width: 76ch; }
  .mixer { display: flex; flex-wrap: wrap; gap: 18px; align-items: center; background: var(--panel);
           border: 1px solid var(--rule); border-radius: 10px; padding: 12px 16px; margin-bottom: 8px;
           position: sticky; top: 0; z-index: 5; }
  .mixer label { font: 500 12px var(--font-data); color: var(--lavender); display: flex;
                 align-items: center; gap: 8px; }
  .mixer input[type=range] { width: 120px; accent-color: var(--coral); }
  .mixer .val { color: var(--cream); min-width: 52px; text-align: right; }
  #filter { background: #120f1d; border: 1px solid var(--rule); color: var(--cream);
            font: 13px var(--font-data); padding: 6px 10px; border-radius: 6px; width: 200px; }
  button { font: 500 12px var(--font-data); background: #241f36; color: var(--cream);
           border: 1px solid var(--rule); border-radius: 6px; padding: 5px 10px; cursor: pointer; }
  button:hover { border-color: var(--coral); }
  button.on { background: var(--coral); color: #2a1520; border-color: var(--coral); }
  .card { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px;
          padding: 12px 14px; margin-bottom: 10px; }
  .card h3 { font: 500 15px var(--font-data); margin: 0; color: var(--cream); display: inline; }
  .chips { display: inline-flex; gap: 6px; margin-left: 10px; vertical-align: 2px; }
  .chip { font: 500 10px var(--font-data); padding: 2px 7px; border-radius: 99px;
          border: 1px solid var(--rule); color: var(--lavender); letter-spacing: .04em; }
  .chip.amb { color: var(--teal); border-color: #2c5b52; }
  .chip.sfx { color: var(--mustard); border-color: #5c4a22; }
  .chip.ui  { color: var(--violet); border-color: #4a3a66; }
  .chip.loop { color: var(--coral); border-color: #5c3328; }
  .note { color: var(--lavender); font-size: 12.5px; margin: 8px 0 10px; max-width: 92ch; }
  .vars { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
  .var { position: relative; cursor: pointer; border: 1px solid var(--rule); border-radius: 6px;
         background: #120f1d; padding: 0; line-height: 0; }
  .var:hover { border-color: var(--coral); }
  .var.playing { border-color: var(--teal); box-shadow: 0 0 0 1px var(--teal) inset; }
  .var canvas { display: block; }
  .var span { position: absolute; left: 4px; top: 2px; font: 500 9px var(--font-data);
              color: var(--lavender); }
  footer { margin-top: 36px; border-top: 1px solid var(--rule); padding-top: 14px;
           color: var(--lavender); font-size: 12.5px; }
  footer code { font: 12px var(--font-data); color: var(--cream); }
  footer li { margin-bottom: 4px; }
</style>

<h1>GTFO &mdash; sound</h1>
<p class="sub">Generated by <code>tools/sfx_gen.py</code>. There is no screenshot for sound, so
this is how you check it: click a waveform to hear it. Looping sounds latch, so you can stack a
land's bed with what lives in it (try <code>amb_red</code> + <code>amb_wreck</code> +
<code>amb_suit</code>) and hear what the astronaut hears. The sliders are the mix the game
actually uses &mdash; the <code>gain_db</code> from <code>audio.json</code> plus its bus &mdash;
so if something is too loud here it is too loud in the game, and the fix is a number in
<code>RECIPES</code>, not a line of GDScript.</p>

<div class="mixer">
  <label>master <input type="range" id="m-master" min="-30" max="6" step="1" value="0"><span class="val" id="v-master">0 dB</span></label>
  <label>amb <input type="range" id="m-amb" min="-30" max="6" step="1"><span class="val" id="v-amb"></span></label>
  <label>sfx <input type="range" id="m-sfx" min="-30" max="6" step="1"><span class="val" id="v-sfx"></span></label>
  <label>ui <input type="range" id="m-ui" min="-30" max="6" step="1"><span class="val" id="v-ui"></span></label>
  <input id="filter" type="search" placeholder="filter by name or note">
  <button id="stop">stop everything</button>
</div>

<div id="list"></div>

<footer id="credits"></footer>

<script>
const DATA = __DATA__;
const WAVES = __WAVES__;
const playing = new Map();          // key -> HTMLAudioElement
const buses = { amb: 0, sfx: 0, ui: 0 };
let master = 0;

for (const b of ['amb', 'sfx', 'ui']) {
  buses[b] = DATA.buses[b] ?? 0;
  const slider = document.getElementById('m-' + b);
  slider.value = buses[b];
  document.getElementById('v-' + b).textContent = buses[b] + ' dB';
  slider.addEventListener('input', () => {
    buses[b] = +slider.value;
    document.getElementById('v-' + b).textContent = buses[b] + ' dB';
    relevel();
  });
}
const mm = document.getElementById('m-master');
mm.addEventListener('input', () => {
  master = +mm.value;
  document.getElementById('v-master').textContent = master + ' dB';
  relevel();
});

function levelOf(name) {
  const e = DATA.sounds[name];
  return Math.min(1, Math.pow(10, (e.gain_db + (buses[e.bus] ?? 0) + master) / 20));
}
function relevel() {
  for (const [key, a] of playing) a.volume = levelOf(key.split('#')[0]);
}

function draw(canvas, peaks, w, h) {
  const dpr = devicePixelRatio || 1;
  canvas.width = w * dpr; canvas.height = h * dpr;
  canvas.style.width = w + 'px'; canvas.style.height = h + 'px';
  const g = canvas.getContext('2d');
  g.scale(dpr, dpr);
  g.fillStyle = '#120f1d'; g.fillRect(0, 0, w, h);
  g.strokeStyle = '#342c47'; g.beginPath(); g.moveTo(0, h / 2); g.lineTo(w, h / 2); g.stroke();
  g.fillStyle = '#4fc6b4';
  const n = peaks.length || 1;
  for (let i = 0; i < n; i++) {
    const [lo, hi] = peaks[i];
    const x = (i / n) * w;
    const y0 = (0.5 - hi / 2) * h, y1 = (0.5 - lo / 2) * h;
    g.fillRect(x, y0, Math.max(1, w / n), Math.max(1, y1 - y0));
  }
}

function stopAll() {
  for (const [, a] of playing) { a.pause(); a.currentTime = 0; }
  playing.clear();
  document.querySelectorAll('.var.playing').forEach(el => el.classList.remove('playing'));
}
document.getElementById('stop').addEventListener('click', stopAll);

function toggle(name, index, el) {
  const e = DATA.sounds[name];
  const key = name + '#' + index;
  if (playing.has(key)) {
    playing.get(key).pause();
    playing.delete(key);
    el.classList.remove('playing');
    return;
  }
  const a = new Audio(e.files[index]);
  a.loop = e.loop;
  a.volume = levelOf(name);
  a.addEventListener('ended', () => { playing.delete(key); el.classList.remove('playing'); });
  a.play().catch(err => console.warn(name, err));
  playing.set(key, a);
  el.classList.add('playing');
}

const groups = new Map();
for (const [name, e] of Object.entries(DATA.sounds)) {
  if (!groups.has(e.group)) groups.set(e.group, []);
  groups.get(e.group).push(name);
}
const list = document.getElementById('list');
for (const [title, names] of groups) {
  const h = document.createElement('h2');
  h.textContent = title + '  (' + names.length + ')';
  list.appendChild(h);
  for (const name of names) {
    const e = DATA.sounds[name];
    const card = document.createElement('div');
    card.className = 'card';
    card.dataset.hay = (name + ' ' + (e.note || '')).toLowerCase();
    const head = document.createElement('div');
    head.innerHTML = '<h3></h3><span class="chips"></span>';
    head.querySelector('h3').textContent = name;
    const chips = head.querySelector('.chips');
    const add = (cls, text) => {
      const c = document.createElement('span');
      c.className = 'chip ' + cls; c.textContent = text; chips.appendChild(c);
    };
    add(e.bus, e.bus);
    if (e.loop) add('loop', 'loop');
    add('', e.seconds.toFixed(2) + ' s');
    add('', e.gain_db + ' dB');
    if (e.files.length > 1) add('', e.files.length + ' variants');
    if (e.pitch) add('', 'pitch ' + e.pitch[0] + '-' + e.pitch[1]);
    if (e.dist) add('', 'heard to ' + e.dist + ' px');
    card.appendChild(head);
    if (e.note) {
      const n = document.createElement('p');
      n.className = 'note'; n.textContent = e.note; card.appendChild(n);
    }
    const vars = document.createElement('div');
    vars.className = 'vars';
    e.files.forEach((file, i) => {
      const b = document.createElement('button');
      b.className = 'var';
      b.title = file + '  (click to ' + (e.loop ? 'latch the loop' : 'play') + ')';
      const c = document.createElement('canvas');
      b.appendChild(c);
      const tag = document.createElement('span');
      tag.textContent = e.files.length > 1 ? i : '';
      b.appendChild(tag);
      const width = Math.round(Math.min(360, Math.max(90, 70 + e.seconds * 22)));
      draw(c, (WAVES[name] || [])[i] || [], width, 42);
      b.addEventListener('click', () => toggle(name, i, b));
      vars.appendChild(b);
    });
    card.appendChild(vars);
    list.appendChild(card);
  }
}

const f = document.getElementById('filter');
f.addEventListener('input', () => {
  const q = f.value.trim().toLowerCase();
  document.querySelectorAll('.card').forEach(c => {
    c.style.display = !q || c.dataset.hay.includes(q) ? '' : 'none';
  });
  document.querySelectorAll('h2').forEach(h => {
    let el = h.nextElementSibling, any = false;
    while (el && el.tagName === 'DIV') { if (el.style.display !== 'none') any = true; el = el.nextElementSibling; }
    h.style.display = any ? '' : 'none';
  });
});

document.getElementById('credits').innerHTML =
  '<p><strong>Sources.</strong> The sampled layer comes from the open-licence packs below; the '
  + 'alien tech is synthesised in <code>tools/sfx_gen.py</code>. Packs marked CC BY '
  + '<strong>must</strong> be credited wherever the game is distributed &mdash; see '
  + '<code>assets/audio/CREDITS.md</code>.</p><ul>'
  + DATA.credits.map(c => '<li>' + c + '</li>').join('') + '</ul>';
</script>
'''


def write_viewer(manifest, waves):
    """A self-contained page to listen to every sound. The waveforms are baked in, so it works
    straight off the filesystem with no server (file:// cannot fetch)."""
    html = VIEWER.replace('__DATA__', json.dumps(manifest, separators=(',', ':')))
    html = html.replace('__WAVES__', json.dumps(waves, separators=(',', ':')))
    with open(os.path.join(OUT, 'viewer.html'), 'w') as f:
        f.write(html)


def write_credits():
    """SOURCES.md is the full record; CREDITS.md is what the game has to show people."""
    rows = sorted(PACKS.items(), key=lambda kv: (kv[1]['licence'], kv[1]['author']))
    with open(os.path.join(OUT, 'SOURCES.md'), 'w') as f:
        f.write('# Sound sources\n\n'
                'Written by `tools/sfx_gen.py` - do not edit by hand.\n\n'
                'The recordings behind the sampled layer. `python tools/sfx_gen.py --fetch`\n'
                'downloads and checksums them into `assets/audio/sources/`, which is\n'
                'git-ignored: the repo keeps the baked `*.wav`, not the raw packs.\n\n'
                '| pack | author | licence | page |\n|---|---|---|---|\n')
        for pid, p in rows:
            f.write(f'| `{pid}` | {p["author"]} | [{p["licence"]}]({p["licence_url"]}) '
                    f'| [{p["title"]}]({p["page"]}) |\n')
        f.write('\n## Which sound came from where\n\n'
                'Every entry in `audio.json` carries a `note` saying which recording it uses and\n'
                'the measurement that justified it. `python tools/sfx_gen.py --probe <glob>`\n'
                'measures candidates the same way.\n\n'
                '## The synthesised layer\n\n'
                'The alien tech - the multitool\'s beams, the lens, the lamps, the crystal\n'
                'spires, the beacons, the UI - is generated in `sfx_gen.py` itself, under the\n'
                'same terms as the rest of this repository.\n')
    byattr = [p for _, p in rows if not p['licence'].startswith('CC0')]
    with open(os.path.join(OUT, 'CREDITS.md'), 'w') as f:
        f.write('# Sound credits\n\n'
                'Written by `tools/sfx_gen.py` - do not edit by hand.\n\n'
                '**The game must ship this.** The packs below are CC BY: the licence requires\n'
                'that they are credited wherever the game is distributed.\n\n')
        for p in byattr:
            f.write(f'* {p["credit"]}  \n  {p["page"]}\n')
        f.write('\nThe following are CC0 and need no credit. They are listed because their\n'
                'authors deserve it anyway.\n\n')
        for _, p in rows:
            if p['licence'].startswith('CC0'):
                f.write(f'* {p["credit"]}  \n  {p["page"]}\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('--fetch', action='store_true', help='download and verify the source packs')
    ap.add_argument('--only', metavar='TEXT', help='bake only sounds whose name contains TEXT')
    ap.add_argument('--probe', nargs='+', metavar='GLOB', help='measure candidate recordings')
    args = ap.parse_args()
    if args.probe:
        probe(args.probe)
        return
    if args.fetch:
        fetch()
        return
    if not os.path.isdir(SRC):
        raise SystemExit('no sources yet - run: python tools/sfx_gen.py --fetch')
    if not shutil.which('ffmpeg'):
        raise SystemExit('ffmpeg not found on PATH (needed to decode ogg/mp3/flac)')
    bake(args.only)


if __name__ == '__main__':
    main()
