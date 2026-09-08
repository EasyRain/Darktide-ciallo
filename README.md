# Ciallo～(∠・ω- )⌒☆ Push Sound

A tiny Darktide mod: plays **Ciallo～(∠・ω- )⌒☆** every time you **push** (hold right mouse button to block, then press left mouse button).

## How it works

- Hooks `ActionPush.start` (the melee push action) and plays only for your own
  local player, skipping prediction re-simulation so it fires once per real push.
- The audio file is played **from disk** with Windows audio APIs through LuaJIT
  FFI (`winmm.dll`) — no custom DLL, no wwise authoring:
  - **WAV** → `PlaySound` (async)
  - **MP3 / other** → MCI (`mciSendString`, DirectShow)
- Non-ASCII paths are supported (UTF-16 conversion).

## Install

1. Copy the `ciallo` folder into your game's `mods` folder.
2. Add `ciallo` to `mods\mod_load_order.txt`.
3. Put a **WAV** (recommended) or real **MP3** file somewhere on disk.
4. In Mod Options → Ciallo Push Sound, set `Sound file path` to your file
   (or name it `Ciallo～(∠・ω- )⌒☆.wav` next to the `.mp3` of the same name —
   the mod auto-tries `.wav`/`.mp3` variants of the configured path).
5. Press the **Test sound** button to verify, then go push some heretics.

> **Note about formats:** a file with a `.mp3` extension is not necessarily an
> MP3 — check that it is genuine MPEG audio. MP4/M4A (AAC) files mislabeled as
> `.mp3` will not play through MCI. Convert to WAV for the most reliable result
> (e.g. with ffmpeg: `ffmpeg -i in.mp3 out.wav`).

## Options

| Setting | Description |
| --- | --- |
| Sound file path | Full path to the sound file (WAV recommended, MP3 supported). |
| Overlapping layers (WAV) | How many sounds may play on top of each other (1–8, default 4). Rapid pushes start a new layer instead of cutting the previous one; once all layers are busy, the oldest is restarted. |
| Volume | MCI volume 0–100% (MP3 path only; WAV follows system volume). |
| Test sound | Plays the configured file once. |

## Notes

- Sound is only played for **your own** pushes (bots/husk/remote players are ignored).
- **Overlap**: the WAV player keeps a pool of concurrent MCI `waveaudio` instances (default 4), so rapid pushes layer on top of each other instead of cutting off the previous sound. MP3 keeps a single instance (restarts each push).
- The sound file is not bundled with the mod; provide your own.
- License: MIT
