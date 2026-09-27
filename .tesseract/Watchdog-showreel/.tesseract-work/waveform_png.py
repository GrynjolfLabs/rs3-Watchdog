"""Font-free waveform view (the skill helper's drawtext labels crash this FFmpeg build).

Draws per-10ms peak (dim) and RMS (bright) for a mono fold of the input, with
beat lines (grey), bar lines (white) and optional review markers (orange).
Time axis: `px_per_s` pixels per second from `start`.

Usage: python waveform_png.py in.wav out.png [--start S] [--dur S] [--bpm 120]
       [--markers 4.0,20.0] [--pxs 80]
Input may be any file FFmpeg can decode (decoded to 48 kHz mono f32 via ffmpeg).
"""
import argparse
import struct
import subprocess
import zlib

import numpy as np


def decode(path):
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", "48000", "-f", "f32le", "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype="<f4")


def write_png(path, rgb):
    h, w, _ = rgb.shape
    rows = b"".join(b"\x00" + rgb[y].tobytes() for y in range(h))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--dur", type=float, default=None)
    ap.add_argument("--bpm", type=float, default=120)
    ap.add_argument("--markers", default="")
    ap.add_argument("--pxs", type=float, default=80)
    ap.add_argument("--height", type=int, default=300)
    a = ap.parse_args()

    x = decode(a.inp)
    sr = 48000
    i0 = int(a.start * sr)
    dur = a.dur if a.dur is not None else len(x) / sr - a.start
    x = x[i0 : i0 + int(dur * sr)]
    w = int(dur * a.pxs)
    h = a.height
    img = np.full((h, w, 3), 18, dtype=np.uint8)
    per = len(x) / w
    mid = h // 2
    for px in range(w):
        seg = x[int(px * per) : int((px + 1) * per)]
        if len(seg) == 0:
            continue
        pk = np.sqrt(np.max(np.abs(seg)))
        rms = np.sqrt(np.sqrt(np.mean(seg ** 2)))
        hp, hr = int(pk * (h / 2 - 4)), int(rms * (h / 2 - 4))
        img[mid - hp : mid + hp + 1, px] = (70, 110, 150)
        img[mid - hr : mid + hr + 1, px] = (150, 210, 255)
    beat = 60.0 / a.bpm
    k = int(np.ceil(a.start / beat))
    while k * beat < a.start + dur:
        px = int((k * beat - a.start) * a.pxs)
        if 0 <= px < w:
            bar = k % 4 == 0
            img[: (h if bar else h // 6), px] = (235, 235, 235) if bar else (90, 90, 90)
            img[h - (0 if bar else h // 6) :, px] = (90, 90, 90)
        k += 1
    for m in filter(None, a.markers.split(",")):
        px = int((float(m) - a.start) * a.pxs)
        if 0 <= px < w:
            img[:, max(0, px - 1) : px + 2] = (240, 160, 32)
    write_png(a.out, img)
    print(f"{a.out}: {w}x{h}, {a.pxs} px/s from {a.start}s; white=bar, grey=beat, orange=markers")


if __name__ == "__main__":
    main()
