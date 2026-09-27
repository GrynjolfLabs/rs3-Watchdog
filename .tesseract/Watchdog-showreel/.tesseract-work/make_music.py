"""Original 120 BPM electronic bed for the Watchdog showreel.

Everything is synthesized here (no samples), so the arrangement is locked to a
grid the picture can be cut to: beat = 0.5 s, bar = 2 s, 16th = 125 ms.

Arrangement (bar index b starts at 2*b seconds):
  b0      0-2    intro: kick on every beat + filtered chord stabs
  b1      2-4    build: 16th hats, accelerating snare roll, riser; silence 3.75-4.0
  b2-b6   4-14   drop / main groove (crash + impact at 4.0); arp joins at 10.0
  b7-b8   14-18  drive: rolling 16th bass, beat ticks for the slot reels
  b9      18-20  build 2: no kick, snare roll, riser; silence 19.75-20.0
  b10-b11 20-24  outro groove under a held chord (impact at 20.0)
  24.0           final stab, tail fades out by 25.0

Usage: python make_music.py <output.wav>
"""
import sys
import wave

import numpy as np

SR = 48000
BPM = 120
BEAT = 60.0 / BPM
BAR = 4 * BEAT
S16 = BEAT / 4
LENGTH = 25.0
N = int(LENGTH * SR)
rng = np.random.default_rng(7)

# One chord per bar: F minor - Db - Ab - Eb (i - VI - III - VII).
CHORDS = {
    "Fm": [53, 56, 60],
    "Db": [49, 53, 56],
    "Ab": [56, 60, 63],
    "Eb": [51, 55, 58],
}
BASS_ROOT = {"Fm": 41, "Db": 37, "Ab": 44, "Eb": 39}
BAR_CHORDS = ["Fm", "Fm", "Fm", "Db", "Ab", "Eb", "Fm", "Db", "Ab", "Eb", "Fm", "Db", "Fm"]


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def lp1(x, fc):
    """One-pole lowpass; fc may be a scalar or a per-sample array."""
    fc = np.broadcast_to(np.asarray(fc, dtype=float), x.shape)
    a = 1.0 - np.exp(-2 * np.pi * np.minimum(fc, SR * 0.45) / SR)
    y = np.empty_like(x)
    s = 0.0
    for i in range(len(x)):
        s += a[i] * (x[i] - s)
        y[i] = s
    return y


def lp2(x, fc):
    return lp1(lp1(x, fc), fc)


def hp1(x, fc):
    return x - lp1(x, fc)


def saw(freq, t, phase=0.0):
    p = (freq * t + phase) % 1.0
    return 2.0 * p - 1.0


def supersaw(freq, t, voices=5, detune=0.012):
    out = np.zeros_like(t)
    for v in range(voices):
        d = (v - (voices - 1) / 2) / ((voices - 1) / 2) * detune
        out += saw(freq * (1 + d), t, phase=rng.random())
    return out / voices


def env_ad(n, attack, decay_tau):
    t = np.arange(n) / SR
    a = np.minimum(1.0, t / max(attack, 1e-4))
    return a * np.exp(-t / decay_tau)


class Track:
    def __init__(self):
        self.l = np.zeros(N)
        self.r = np.zeros(N)

    def add(self, sig, at, gain=1.0, pan=0.0):
        """Mix a mono (or (l, r) tuple) signal starting at `at` seconds."""
        i = int(round(at * SR))
        if i >= N:
            return
        if isinstance(sig, tuple):
            left, right = sig
        else:
            left = right = sig
        left = left[: N - i]
        right = right[: N - i]
        gl = gain * np.sqrt(0.5 * (1 - pan)) * np.sqrt(2)
        gr = gain * np.sqrt(0.5 * (1 + pan)) * np.sqrt(2)
        self.l[i : i + len(left)] += left * gl
        self.r[i : i + len(right)] += right * gr

    def mix_into(self, other, gain=1.0):
        other.l += self.l * gain
        other.r += self.r * gain


# ---------------------------------------------------------------- instruments

def kick(level=1.0):
    t = t_axis(0.45)
    f = 45 + 110 * np.exp(-t / 0.035)
    phase = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(phase) * np.exp(-t / 0.16)
    click = rng.standard_normal(len(t)) * np.exp(-t / 0.003) * 0.35
    return np.tanh((body + click) * 1.6) * level


def clap():
    n = int(0.35 * SR)
    noise = rng.standard_normal(n)
    e = np.zeros(n)
    for k, off in enumerate((0.0, 0.009, 0.018)):
        i = int(off * SR)
        e[i:] += env_ad(n - i, 0.0005, 0.012 if k < 2 else 0.11)
    sig = hp1(lp1(noise * e, 3200), 900)
    return sig * 1.8


def snare(level=1.0):
    t = t_axis(0.22)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.04) * 0.5
    noise = hp1(rng.standard_normal(len(t)), 1500) * np.exp(-t / 0.06)
    return (tone + noise) * level


def hat(open_=False, level=1.0):
    dur = 0.25 if open_ else 0.05
    t = t_axis(dur)
    noise = rng.standard_normal(len(t))
    sig = hp1(hp1(noise, 7000), 7000)
    return sig * np.exp(-t / (0.07 if open_ else 0.012)) * level


def tick():
    t = t_axis(0.06)
    s = np.sin(2 * np.pi * 1850 * t) * np.exp(-t / 0.012)
    s += hp1(rng.standard_normal(len(t)), 4000) * np.exp(-t / 0.004) * 0.4
    return s


def crash(dur=2.4):
    t = t_axis(dur)
    noise = rng.standard_normal(len(t))
    sig = hp1(noise, 4500) * np.exp(-t / 0.7)
    sig2 = hp1(rng.standard_normal(len(t)), 4500) * np.exp(-t / 0.7)
    return (sig, sig2)


def impact():
    t = t_axis(1.6)
    f = 32 + 60 * np.exp(-t / 0.12)
    body = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.55)
    # upper harmonics so the hit survives small speakers
    grit = np.tanh(body * 3.0) * 0.35
    thump = lp1(rng.standard_normal(len(t)), 900) * np.exp(-t / 0.05) * 1.5
    return body + grit + thump


def stab(chord, dur=0.22, cutoff=2400, level=1.0):
    t = t_axis(dur + 0.25)
    sig = np.zeros_like(t)
    for m in CHORDS[chord] + [CHORDS[chord][0] + 12]:
        sig += supersaw(hz(m), t, voices=5, detune=0.01)
    e = env_ad(len(t), 0.003, dur * 0.55)
    fc = cutoff * (0.35 + 0.65 * np.exp(-t / 0.09))
    return lp2(sig * e, fc) * level * 0.5


def pad(chord, dur, level=1.0, cutoff=1800):
    t = t_axis(dur)
    sig = np.zeros_like(t)
    for m in CHORDS[chord] + [CHORDS[chord][0] + 12, CHORDS[chord][0] - 12]:
        sig += supersaw(hz(m), t, voices=7, detune=0.015)
    att = np.minimum(1.0, t / 0.02)
    rel = np.clip((dur - t) / 0.6, 0, 1)
    e = att * (0.55 + 0.45 * np.exp(-t / 0.5)) * rel
    return lp1(sig * e, cutoff) * level * 0.35


def bass_note(midi, dur, cutoff=700, level=1.0):
    t = t_axis(dur)
    f = hz(midi)
    sig = saw(f, t) * 0.7 + np.sin(2 * np.pi * f / 2 * t) * 0.6
    e = env_ad(len(t), 0.002, dur * 0.6) * np.clip((dur - t) / 0.01, 0, 1)
    fc = cutoff * (0.5 + 0.5 * np.exp(-t / 0.05))
    return np.tanh(lp2(sig * e, fc) * 1.5) * level


def pluck(midi, dur=0.2, level=1.0):
    t = t_axis(dur + 0.2)
    f = hz(midi)
    sq = np.sign(np.sin(2 * np.pi * f * t)) * 0.5 + saw(f * 1.004, t) * 0.5
    e = env_ad(len(t), 0.001, 0.08)
    return lp1(sq * e, 1500 + 3500 * np.exp(-t / 0.05)) * level * 0.4


def riser(dur):
    t = t_axis(dur)
    p = t / dur
    noise = rng.standard_normal(len(t))
    sig = hp1(noise, 400 + 6000 * p ** 2) * (p ** 1.6)
    tone = supersaw(110 * 2 ** (p * 2.0), t, voices=3, detune=0.02) * (p ** 2) * 0.35
    return sig * 0.5 + tone


# ---------------------------------------------------------------- arrangement

def bar_start(b):
    return b * BAR


def build():
    drums, music, fx = Track(), Track(), Track()
    sidechain = np.ones(N)

    def duck(at, depth=0.65, release=0.18):
        i = int(at * SR)
        n = int(0.45 * SR)
        t = np.arange(n) / SR
        curve = 1 - depth * np.exp(-t / release)
        end = min(N, i + n)
        sidechain[i:end] = np.minimum(sidechain[i:end], curve[: end - i])

    def kick_at(at, level=1.0):
        drums.add(kick(level), at, gain=0.95)
        duck(at)

    # --- b0: intro, kick + stab on every beat
    for k in range(4):
        at = k * BEAT
        kick_at(at, 0.9)
        music.add(stab("Fm", cutoff=1100 + k * 250), at, gain=0.55, pan=(-0.25, 0.25, -0.15, 0.15)[k])
        music.add(bass_note(29 + 12, 0.35, cutoff=300), at, gain=0.5)

    # --- b1: build (2.0 - 3.75), silence 3.75 - 4.0
    for k in range(3):
        kick_at(bar_start(1) + k * BEAT, 0.9)
    for s in range(14):
        drums.add(hat(level=0.45 + 0.03 * s), bar_start(1) + s * S16, gain=0.35, pan=0.2)
    roll = [2.0 + i * 0.25 for i in range(4)] + [3.0 + i * S16 for i in range(4)] + [3.5 + i * S16 / 2 for i in range(4)]
    for i, at in enumerate(roll):
        drums.add(snare(0.35 + 0.05 * i), at, gain=0.6)
    for k in range(7):
        at = bar_start(1) + k * BEAT / 2
        if at < 3.75:
            music.add(stab("Fm", dur=0.12, cutoff=1400 + 300 * k), at, gain=0.35, pan=0.3 if k % 2 else -0.3)
    fx.add(riser(1.75), 2.0, gain=0.45)

    # --- impacts and crashes
    for at in (4.0, 20.0):
        fx.add(impact(), at, gain=0.75)
        fx.add(crash(), at, gain=0.30)

    stab_steps = [0, 3, 6, 10, 12]
    arp_pattern = [0, 1, 2, 3, 2, 1, 3, 2, 0, 2, 1, 3, 2, 3, 1, 2]

    def groove_bar(b, *, arp=False, drive=False, stabs=True, ticks=False, clap_on=True):
        t0 = bar_start(b)
        chord = BAR_CHORDS[b]
        for k in range(4):
            kick_at(t0 + k * BEAT)
            drums.add(hat(open_=True, level=0.55), t0 + k * BEAT + BEAT / 2, gain=0.33, pan=0.25)
            if ticks:
                fx.add(tick(), t0 + k * BEAT, gain=0.18, pan=-0.2)
        if clap_on:
            for k in (1, 3):
                drums.add(clap(), t0 + k * BEAT, gain=0.5)
        for s in range(16):
            if s % 2 == 1:
                drums.add(hat(level=0.3), t0 + s * S16, gain=0.25, pan=-0.3)
        root = BASS_ROOT[chord]
        if drive:
            for s in range(16):
                if s % 4 != 0:
                    music.add(bass_note(root + (12 if s % 8 == 6 else 0), S16 * 0.9, cutoff=900), t0 + s * S16, gain=0.55)
        else:
            for k in range(4):
                music.add(bass_note(root, BEAT / 2 * 0.95, cutoff=750), t0 + k * BEAT + BEAT / 2, gain=0.6)
        if stabs:
            for s in stab_steps:
                music.add(stab(chord, dur=0.16, cutoff=2600), t0 + s * S16, gain=0.4, pan=-0.35 if s % 2 else 0.35)
        if arp:
            notes = CHORDS[chord] + [CHORDS[chord][0] + 12]
            for s in range(16):
                m = notes[arp_pattern[s]] + 12
                music.add(pluck(m, level=0.8 if s % 4 == 0 else 0.55), t0 + s * S16, gain=0.4, pan=0.4 * np.sin(s * 0.8))

    for b in range(2, 7):  # 4 - 14
        groove_bar(b, arp=b >= 5)
    for b in (7, 8):  # 14 - 18
        groove_bar(b, arp=True, drive=True, stabs=False, ticks=True)
    # fills leading into bar 5 (10.0) and bar 7 (14.0)
    for at in [9.5 + i * S16 for i in range(4)] + [13.5 + i * S16 for i in range(4)]:
        drums.add(snare(0.5), at, gain=0.45)
    # screen-flash accent at 16.5 (a beat inside bar 8)
    music.add(stab("Ab", dur=0.3, cutoff=4200), 16.5, gain=0.5)

    # --- b9: build 2 (18 - 19.75), silence 19.75 - 20.0
    t0 = bar_start(9)
    roll2 = [t0 + i * 0.25 for i in range(4)] + [t0 + 1.0 + i * S16 for i in range(4)] + [t0 + 1.5 + i * S16 / 2 for i in range(4)]
    for i, at in enumerate(roll2):
        drums.add(snare(0.35 + 0.05 * i), at, gain=0.6)
    notes = CHORDS["Eb"] + [CHORDS["Eb"][0] + 12]
    for s in range(14):
        music.add(pluck(notes[arp_pattern[s]] + 12, level=0.5 + 0.03 * s), t0 + s * S16, gain=0.45)
    fx.add(riser(1.75), t0, gain=0.5)

    # --- b10-b11: outro (20 - 24) under held chords
    music.add(pad("Fm", 2.0), 20.0, gain=0.9)
    music.add(pad("Db", 2.0), 22.0, gain=0.9)
    for b in (10, 11):
        tb = bar_start(b)
        chord = BAR_CHORDS[b]
        for k in range(4):
            kick_at(tb + k * BEAT, 0.8)
            drums.add(hat(open_=True, level=0.45), tb + k * BEAT + BEAT / 2, gain=0.28, pan=0.25)
        for k in (1, 3):
            drums.add(clap(), tb + k * BEAT, gain=0.42)
        for k in range(4):
            music.add(bass_note(BASS_ROOT[chord], BEAT / 2 * 0.95, cutoff=650), tb + k * BEAT + BEAT / 2, gain=0.5)
        notes = CHORDS[chord] + [CHORDS[chord][0] + 12]
        for s in range(0, 16, 2):
            music.add(pluck(notes[arp_pattern[s]] + 12, level=0.45), tb + s * S16, gain=0.35, pan=0.4 * np.sin(s))

    # --- 24.0 final stab + tail
    kick_at(24.0, 1.0)
    music.add(stab("Fm", dur=0.6, cutoff=3000), 24.0, gain=0.7)
    music.add(pad("Fm", 1.0, level=0.8), 24.0, gain=0.7)
    fx.add(crash(1.0), 24.0, gain=0.22)
    music.add(bass_note(41, 0.6, cutoff=500), 24.0, gain=0.6)

    music.l *= sidechain
    music.r *= sidechain
    return drums, music, fx


def reverb(track, seconds=1.4, wet=0.18):
    n = int(seconds * SR)
    t = np.arange(n) / SR
    ir_l = rng.standard_normal(n) * np.exp(-t / (seconds / 5))
    ir_r = rng.standard_normal(n) * np.exp(-t / (seconds / 5))
    ir_l[: int(0.012 * SR)] = 0
    ir_r[: int(0.017 * SR)] = 0
    size = 1 << int(np.ceil(np.log2(N + n)))
    out = []
    for x, ir in ((track.l, ir_l), (track.r, ir_r)):
        y = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)[:N]
        y /= np.sqrt(np.sum(ir ** 2)) * 6
        out.append(x + y * wet * 6)
    track.l, track.r = out


def main():
    out_path = sys.argv[1]
    drums, music, fx = build()
    reverb(music, 1.6, 0.22)
    reverb(fx, 1.2, 0.15)
    master = Track()
    drums.mix_into(master, 0.9)
    music.mix_into(master, 0.8)
    fx.mix_into(master, 0.8)

    # hard dropouts: silence the dry mix before each drop, leaving only a tiny tail
    for start, end in ((3.75, 4.0), (19.75, 20.0)):
        i0, i1 = int(start * SR), int(end * SR)
        ramp = int(0.01 * SR)
        fade = np.ones(i1 - i0) * 0.04
        fade[:ramp] = np.linspace(1, 0.04, ramp)
        master.l[i0:i1] *= fade
        master.r[i0:i1] *= fade

    # tail fade 24.6 -> 25.0
    i0 = int(24.6 * SR)
    fade = np.linspace(1, 0, N - i0) ** 2
    master.l[i0:] *= fade
    master.r[i0:] *= fade

    stereo = np.stack([master.l, master.r], axis=1)
    stereo = np.tanh(stereo * 0.9) / np.tanh(0.9)
    peak = np.max(np.abs(stereo))
    stereo = stereo / peak * 10 ** (-1.5 / 20)
    pcm = (stereo * 32767).astype("<i2")
    with wave.open(out_path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {out_path}: {LENGTH}s, peak normalized to -1.5 dBFS")


if __name__ == "__main__":
    main()
