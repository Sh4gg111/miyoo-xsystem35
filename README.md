# xsystem35 for Miyoo Mini (OnionOS)

Build scripts and patches to run **AliceSoft System 3.x games** on the
**Miyoo Mini / Miyoo Mini Plus** with **OnionOS**, using
[xsystem35-sdl2](https://github.com/kichikuou/xsystem35-sdl2).

This repository contains **only scripts and source code**. It does **not**
include any game data. Get the games from
[haniwa.technology](https://haniwa.technology/games/) (use the `.tar.gz`
builds made for xsystem35-sdl2, not the AppImages).

## Tested games

| Game | Language | Music | Extra step |
|---|---|---|---|
| Kichikuou Rance | English | MP3 (included in the game folder) | — |
| Rance 1 – Quest for Hikari | English | MIDI | run `tools/prerender_midi.py` once |
| Rance III | English | MIDI | run `tools/prerender_midi.py` once |
| Rance IV | English | MP3 (included in the game folder) | — |

Other games supported by xsystem35-sdl2 will probably work the same way.

## Installing a release (no build needed)

Ready-to-use packages are on the [Releases](../../releases) page, one zip
per game. They contain the port only (the Miyoo build of xsystem35, its
libraries, the launcher and the OnionOS shortcut), **not the game**. The
zips for MIDI games (Rance 1 and Rance III) also include the music
converter, in `Roms/PORTS/Games/<Name>/tools/`.

1. Extract the zip on your PC.
2. Download the English `.tar.gz` of the same game from
   [haniwa.technology](https://haniwa.technology/games/) and extract it on
   your PC.
3. Copy everything from the game folder (the `.ALD` files and the rest)
   into the zip's `Roms/PORTS/Games/<Name>/game/` folder.
4. **Rance 1 and Rance III only:** convert the MIDI music to MP3 (see
   [MIDI music](#midi-music-rance-1-and-rance-iii) below).
5. Copy the `Roms` folder to the **root of the SD card** (it merges with the
   `Roms` folder already there).
6. In OnionOS, open **Ports** and run **~Import ports**. The game appears
   once its files are in place.

## MIDI music (Rance 1 and Rance III)

These two games store their soundtrack as MIDI, and synthesizing MIDI in
real time is too heavy for the Miyoo: the music stutters and the game slows
down. `prerender_midi.py` converts the tracks to MP3 **once, on a PC**,
using the game's own sound bank (`TimGM6mb.sf2`), so they sound the same as
on the PC. The MP3 files are not included in the releases because they are
generated from the game files.

**Requirements:** Linux, or Windows with
[WSL](https://learn.microsoft.com/windows/wsl/install) (Ubuntu), plus:

```sh
sudo apt install python3 fluidsynth ffmpeg
```

**Steps** (after copying the game into `Roms/PORTS/Games/<Name>/game/`):

1. Move `prerender_midi.py` from `Roms/PORTS/Games/<Name>/tools/` into
   `Roms/PORTS/Games/<Name>/game/`, the folder with the `.ALD` files and
   `TimGM6mb.sf2`. (The script is also in this repository:
   [`tools/prerender_midi.py`](tools/prerender_midi.py).)
2. Open a WSL terminal in that folder. On Windows: open the folder in File
   Explorer, type `wsl` in the address bar and press Enter.
3. Run:
   ```sh
   python3 prerender_midi.py
   ```
4. It creates a `midi` folder there, with one MP3 per track (`1.mp3`,
   `2.mp3`, …). It goes to the SD card together with the rest of the game.

Without the `midi` folder the game still runs, but it falls back to
synthesizing the MIDI on the Miyoo, so the music stutters and the game slows down.

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
   `tools/prerender_midi.py` automatically the first time and stores the tracks
   in `<game>/midi/`.
   Optional box art: put `Rance1.png` next to `package.sh` before running it.
3. Copy `dist/Rance1/Roms` to the root of the SD card and run
   **~Import ports** in OnionOS.

### Making a release zip

```sh
sudo ./package.sh --release ~/xsystem35-sdl2 ~/Rance1 Rance1 "Rance 1"
```

This builds `dist/Rance1-miyoo-onion.zip` without the game files, the MIDI
MP3s or the box art, with English install instructions. For MIDI games it
adds `prerender_midi.py` in `Roms/PORTS/Games/<Name>/tools/` and the MIDI
step to the instructions. The OnionOS shortcut stays hidden until the
game's `*SA.ALD` file is copied into `game/`.

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

## AI disclosure

This project was developed with the help of an AI assistant (Claude, by
Anthropic), which wrote most of the scripts and the Miyoo patch. Everything
was built and tested on real hardware (Miyoo Mini with OnionOS), but expect
rough edges: please report problems in the
[Issues](../../issues) tab.
