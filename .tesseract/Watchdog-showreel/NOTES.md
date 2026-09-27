# Watchdog showreel (26 s, 1920x1080, 30 fps)

Built from scratch from the Watchdog plugin code (`ui/theme.lua`, `toast.lua`, `nodes/**`,
`resources/images/bell.png`) and the mod.io page URL. No assets or decisions carried over from
the earlier portrait announcement in `.tesseract/`.

## Files

| File | What |
| --- | --- |
| `Watchdog-showreel.tsrct` | Editable document (native layers + AnimationGraph, no prerendered design) |
| `Watchdog-showreel.mp4` | Export: H.264 1920x1080 30 fps, AAC 48 kHz stereo, 26.000 s |
| `Previews/filmstrip-overview.png` | 21-frame overview |
| `.tesseract-work/build.py` | Generator for the whole document (all beat times, nodes, wires) |
| `.tesseract-work/make_music.py` | Original 120 BPM F-minor music bed synthesis |
| `.tesseract-work/checks/` | Loudness report, verification strips |
| `.tesseract-work/scratch-diagnostics/` | Font / renderer diagnostics kept for reference |

Rebuild: `python .tesseract-work/build.py` then
`tsrct project commit --project Watchdog-showreel.tsrct --file .tesseract-work/showreel.json`.

Music changes: regenerate `Sources/audio/showreel-music-v1.wav` with `make_music.py`, then
**package it into the `.tsrct`** (`tsrct project import-asset ... --asset-id music-vN --kind audio`)
and point the bed layer in `build.py` at that id — export does not read the loose WAV on disk
if an older asset is still referenced.

## Structure (cut to 120 BPM: beat 500 ms, bar 2000 ms)

| Time (s) | Scene | Beat logic |
| --- | --- | --- |
| 0 - 3.75 | Hook: feed of real trigger events ("while you were AFK") | one per beat, then 8ths, then 16ths |
| 3.75 - 4.0 | Blackout | music dropout |
| 4.0 - 6.0 | Logo: eye mark + WATCHDOG, pupil looks around, zooms to fill | drop on 4.0 |
| 6.0 - 14.0 | Editor: Inventory -> Toast wired live, toast fires, zoom out to bigger graph, headline | nodes land on beats; connect 8.0, toast 9.0 |
| 13.88 - 19.75 | WHEN / THEN reels: real trigger -> action pairs | per beat, 8ths, 16ths; Screen Flash fires 16.5 |
| 19.75 - 20.0 | Blackout | dropout |
| 20.0 - 26.0 | Outro: lockup, "Get it on mod.io", `mod.io/g/runescape/m/watchdog` | URL wire lands 22.0, blink 23.9, stab 24.0; fade to black 25.0-26.0 |

All node names, pin labels, defaults and colors come from the plugin source
(e.g. Screen Flash default red, Toast pins, Player Chat matcher rows, theme category colors).

## Checks

- Loudness (ffmpeg loudnorm): -15.28 LUFS integrated, -3.05 dBTP, LRA 2.5 LU
  (target -16..-14 LUFS, <= -1 dBTP). See `checks/loudness-final.json`.
- Every trigger/action name on screen matches a `displayName` in `nodes/`.
- Frame checks at every cut and hit point (see `checks/strip-v*.png`).

## Renderer findings (tsrct 0.2.0, Windows)

- Font families register without spaces: use `SpaceGrotesk` / `JetBrainsMono`
  (style `Bold` / `Medium`); the display names return `missing_fonts`.
- A root `Adjustment` layer makes text layers draw through layers above it (black fade and
  flash did not cover text). The finish (chromatic hits + grain) therefore lives as effects on
  a `picture` group; the vignette is a radial-gradient rect.
- `chromaticAberration.amount` ~1.0 is already a strong split at 1080p; hits peak at 0.36-0.9.
- `filmstrip` tiles default to 135 px tall regardless of `--tile-width`; pass `--tile-height`.

## Limitations

- The music bed and SFX are original synthesis and were checked by waveform and loudness only;
  they have not been listened to on this machine.
- The editor scene is a diagrammatic rebuild of the node editor, not a screen recording.

## Status

- [x] Document built and committed
- [x] Scene-by-scene frame review and fixes
- [x] MP4 export, probe, loudness
- [ ] Listen-through of the mix (needs a human)
- [ ] Git commit (not done; awaiting instruction)
