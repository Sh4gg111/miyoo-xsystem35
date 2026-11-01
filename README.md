# xsystem35 for Miyoo Mini (OnionOS)

Build scripts and patches to run **AliceSoft System 3.x games** on the
**Miyoo Mini / Miyoo Mini Plus** with **OnionOS**, using
[xsystem35-sdl2](https://github.com/kichikuou/xsystem35-sdl2).

This repository contains **only scripts and source code**. It does **not**
include any game data. Get the games from
[haniwa.technology](https://haniwa.technology/games/) (use the `.tar.gz`
builds made for xsystem35-sdl2, not the AppImages).

## Tested games

| Game | Language | Music |
|---|---|---|
| Kichikuou Rance | English | MP3 (included in the game folder) |
| Rance 1 – Quest for Hikari | English | MIDI → pre-rendered to MP3 |
| Rance III | English | MIDI → pre-rendered to MP3 |
| Rance IV | English | MP3 (included in the game folder) |

Other games supported by xsystem35-sdl2 will probably work the same way.

## What the Miyoo patch adds

The Miyoo Mini has no mouse or touch screen, and its SDL2 port
([steward-fu/sdl2](https://github.com/steward-fu/sdl2)) has some
limitations. The patch in `miyoo/` (enabled only when building with
`-DMIYOO_MINI`) adds:

- a **virtual mouse** driven by the buttons, with a software-drawn cursor;
- a fix for partial screen updates (the Miyoo SDL ignores the rectangle
  position when locking a texture);
- **transition effects** (crossfade etc.) composited in software, because
  the Miyoo renderer draws alpha-blended textures incorrectly;
- a **"Do you want to leave?"** dialog on the Menu button;
- playback of **pre-rendered MIDI music** (`game/midi/<n>.mp3`), since
  synthesizing MIDI in real time is too heavy for the Miyoo CPU.

## Controls

| Button | Action |
|---|---|
| D-pad | move the cursor (hold to accelerate) |
| R1 (hold) | fast cursor |
| L1 + D-pad | keyboard arrow keys |
| A | left click |
| B | right click (cancel / game menu) |
| Start | Enter |
| Select | toggle message skip |
| Menu | "Do you want to leave?" (A confirms, B cancels) |

## Building (Linux or Windows + WSL)

Requirements: Docker, Python 3, git. For MIDI games also
`sudo apt install fluidsynth ffmpeg`.

```sh
git clone https://github.com/kichikuou/xsystem35-sdl2 ~/xsystem35-sdl2
git -C ~/xsystem35-sdl2 checkout fbb12f6   # version the patch was tested with
git clone <this repository> ~/miyoo-xsystem35
cd ~/miyoo-xsystem35
sudo ./build.sh ~/xsystem35-sdl2
```

`build.sh` applies the Miyoo patch to the xsystem35 source, builds a Docker
image with the cross toolchain (OnionUI toolchain + Miyoo SDL2, SDL2_mixer,
json-c, FluidSynth) and compiles `xsystem35` for ARM.

## Packaging a game

1. Extract the game, e.g. to `~/Rance1`, and test it on the PC.
2. Build the OnionOS port folder:
   ```sh
   sudo ./package.sh ~/xsystem35-sdl2 ~/Rance1 Rance1 "Rance 1"
   ```
   If the game folder has a `.sf2` file (MIDI music), `package.sh` runs
   `prerender_midi.py` automatically the first time and stores the tracks
   in `<game>/midi/`.
   Optional box art: put `Rance1.png` next to `package.sh` before running it.
3. Copy `dist/Rance1/Roms` to the root of the SD card and run
   **~Import ports** in OnionOS.

If a game does not start, check
`Roms/PORTS/Games/<Name>/log/run.log` on the SD card.

## Known limitations

- Uses the prebuilt **640×480** SDL2 from steward-fu. Tested on the
  original Miyoo Mini; Miyoo Mini v4 / Flip (different resolution) are untested.
- The Onion `audioserver` is stopped while a game runs and restarted on exit.
- Pre-rendered MIDI loops from the beginning of the track (MIDI loop points
  are not preserved).

## Credits

- [xsystem35-sdl2](https://github.com/kichikuou/xsystem35-sdl2) by kichikuou (GPL-2.0)
- [Miyoo Mini SDL2](https://github.com/steward-fu/sdl2) by Steward Fu (LGPL-2.1)
- [OnionOS](https://github.com/OnionUI/Onion) and its toolchain image
- [OpenRCT2mini](https://github.com/scheeseman486/OpenRCT2mini), used as a
  reference for the Docker toolchain setup
- [SDL_mixer](https://github.com/libsdl-org/SDL_mixer), [FluidSynth](https://github.com/FluidSynth/fluidsynth),
  [json-c](https://github.com/json-c/json-c)
- Game files: AliceSoft (distributed under AliceSoft's free distribution
  declaration) and the respective fan translators, via
  [haniwa.technology](https://haniwa.technology/games/)

## License

The scripts and the Miyoo patch are released under the **GNU GPL v2**
(see `LICENSE`), the same license as xsystem35-sdl2. Third-party
components keep their own licenses.
