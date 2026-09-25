# Ciallo~ Push Sound

A tiny Darktide mod: plays **Ciallo~** every time you **push** (hold right mouse button to block, then press left mouse button).

## How it works

- Hooks `ActionPush._push` — the moment the game **actually executes** the push
  attack — and plays only for your own local player, skipping prediction
  re-simulation so it fires once per real push.
  Why `_push` and not `ActionPush.start`? `start` runs the instant you press
  light attack (the wind-up/charge begins), even when no push will come out:
  stamina broken, staggered mid-block, or charge-type pushes (e.g. psyker force
  swords, which must be held ~0.5 s to charge and cancel if released early).
  `_push` only runs when the push reaches its `damage_time` on `fixed_update`,
  i.e. when the push really goes out. Failed / cancelled pushes never reach it,
  so no sound plays for them.
- If a game update ever renames `ActionPush` internals, the mod falls back to
  hooking `PushAttack.push`, the lowest-level "push really went out" utility
  (logged at load in the console).
- Audio is played **from disk** with one of two backends (auto-detected at load):
  - **Native (preferred):** `bin/ciallo_sfx.dll` — a small C DLL that plays
    overlapping WAV voices through winmm `waveOut` (one waveOut handle per
    voice, mixed by the OS). Low latency, real polyphony, no callbacks.
  - **Fallback:** LuaJIT FFI straight into `winmm.dll` — a pool of concurrent
    MCI `waveaudio` instances (WAV) or a single MCI instance (MP3/other).
- **Volume** (0–100) is applied by scaling the samples in software, on both
  backends. The native player deliberately does **not** call `waveOutSetVolume`:
  on Windows that moves the volume of the whole audio session, so the mod's
  slider also dragged the game's own music up and down with it.
- Non-ASCII paths are supported.

## Install

1. Copy the `ciallo` folder into your game's `mods` folder.
2. Add `ciallo` to `mods\mod_load_order.txt`.
3. Launch and press the **Test sound** button in Mod Options — the sound ships
   inside the mod at `assets\Ciallo~.wav`, so it works out of the box.
4. To use your own sound file, set `Sound file path` in Mod Options to any
   **absolute** path on disk (e.g. `D:/Sounds/ciallo.wav`); leave it at the
   default (`../mods/ciallo/assets/Ciallo~.wav`) to keep using the bundled file.
   If a configured file is missing, the mod auto-tries `.wav`/`.mp3` variants of
   that path.
5. Go push some heretics.

> **Note about the file name:** avoid characters the in-game font cannot render
> (e.g. `∠`, `ω`, `☆`) in the path — they show as boxes in the option field and
> can corrupt the saved path string. Plain ASCII or CJK file names are safest.
>
> **Note about formats:** a file with a `.mp3` extension is not necessarily an
> MP3 — check that it is genuine MPEG audio. MP4/M4A (AAC) files mislabeled as
> `.mp3` will not play through MCI. Convert to WAV for the most reliable result
> (e.g. with ffmpeg: `ffmpeg -i in.mp3 out.wav`).

## Building the native DLL (optional)

The mod works without the DLL (MCI fallback). To build `ciallo_sfx.dll`
(needs Visual Studio with the Windows SDK, x64):

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cl /nologo /O2 /LD /utf-8 src\ciallo_sfx.c /Fe:bin\ciallo_sfx.dll /link winmm.lib
```

Then copy `bin\ciallo_sfx.dll` into your installed mod's `bin\` folder and
restart the game — the native backend is picked up automatically.

`tests\run_tests.ps1` checks the volume behaviour without the game (it compiles
`tests\test_audio_volume.c`, which includes the C source, and also fails if a
device-volume call ever comes back):

```powershell
powershell -NoProfile -File tests\run_tests.ps1 -RebuildDll
```

## Options

| Setting | Description |
| --- | --- |
| Sound file path | Full path to the sound file (WAV recommended, MP3 supported). |
| Overlapping layers (WAV) | How many sounds may play on top of each other (1–8, default 4). Rapid pushes start a new layer instead of cutting the previous one; once all layers are busy, the oldest is restarted. |
| Volume | Volume of this mod's sound, 0–100%. Applies to both backends, from the next sound onwards. Only this mod's playback is scaled — the game's music, the game's sound effects and the Windows volume are not affected. |
| Test sound | Plays the configured file once. |

## Notes

- Sound is only played for **your own** pushes (bots/husk/remote players are ignored).
- **Overlap**: the WAV player keeps a pool of concurrent voices (default 4), so
  rapid pushes layer on top of each other instead of cutting off the previous
  sound. MP3 keeps a single instance (restarts each push).
- The sound ships with the mod at `assets\Ciallo~.wav`; replace it in place or
  point the `Sound file path` option at your own file.
- **Updating from 1.1.0 or earlier:** those builds set the volume through the
  audio session, so your Darktide level in the Windows volume mixer may have
  been left at the last mod volume you used (that is also why the game's music
  moved with the mod's slider). Set that slider back to what you want once — the
  new build never touches it.
- License: MIT
