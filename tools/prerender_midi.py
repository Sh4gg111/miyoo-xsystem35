#!/usr/bin/env python3
"""Pre-render the MIDI music of a System 3.x game to MP3.

Synthesizing MIDI on the Miyoo Mini is too heavy (the music stutters and
the game slows down). This script does it once, on a PC:

  1. extracts the MIDI tracks from the game's *MA.ALD file;
  2. plays each one with FluidSynth using the game's sound bank (.sf2);
  3. converts them to MP3 in <game folder>/midi/<number>.mp3.

The Miyoo build of xsystem35 (MIYOO_MINI) plays these MP3s instead of MIDI.

Usage:
  python3 prerender_midi.py              (run inside the game folder)
  python3 prerender_midi.py ~/Rance1     (or give the game folder)

Requires:  sudo apt install python3 fluidsynth ffmpeg
"""
import glob
import os
import shutil
import subprocess
import sys
import tempfile


def get3(b, o):
    return b[o] | b[o + 1] << 8 | b[o + 2] << 16


def get2(b, o):
    return b[o] | b[o + 1] << 8


def get4(b, o):
    return b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24


def read_ald(volumes):
    """volumes: {volume_number: path}. Returns {index: bytes}."""
    data = {vol: open(path, "rb").read() for vol, path in volumes.items()}
    first = data[min(data)]
    ofssize = get3(first, 0) << 8
    linksize = (get3(first, 3) << 8) - ofssize
    if ofssize <= 0 or linksize <= 0 or ofssize + linksize > len(first):
        raise SystemExit("ERROR: this does not look like a valid .ALD file")
    link = first[ofssize:ofssize + linksize]

    files = {}
    for i in range(linksize // 3):
        vol = link[i * 3]
        if vol == 0 or vol not in data:
            continue
        buf = data[vol]
        ofs_index = get2(link, i * 3 + 1)
        offset = get3(buf, ofs_index * 3) << 8
        if offset == 0 or offset + 8 > len(buf):
            continue
        ptr = get4(buf, offset)
        size = get4(buf, offset + 4)
        payload = buf[offset + ptr:offset + ptr + size]
        if len(payload) == size and size > 0:
            files[i] = payload
    return files


def find_volumes(game_dir):
    """Finds <name>MA.ALD, <name>MB.ALD... (volume letter at the end)."""
    found = {}
    for path in glob.glob(os.path.join(game_dir, "*")):
        name = os.path.basename(path)
        if not name.upper().endswith(".ALD") or len(name) < 7:
            continue
        kind, letter = name[-6].upper(), name[-5].upper()
        if kind == "M" and "A" <= letter <= "Z":
            found[ord(letter) - ord("A") + 1] = path
    return found


def main():
    if len(sys.argv) > 2:
        raise SystemExit("usage: prerender_midi.py [game folder]  (default: current folder)")
    game_dir = os.path.abspath(os.path.expanduser(sys.argv[1] if len(sys.argv) == 2 else "."))
    print("Game folder:", game_dir)

    for tool in ("fluidsynth", "ffmpeg"):
        if not shutil.which(tool):
            raise SystemExit(f"ERROR: '{tool}' is missing. "
                             "Install it with: sudo apt install fluidsynth ffmpeg")

    sf2 = sorted(glob.glob(os.path.join(game_dir, "*.sf2")) +
                 glob.glob(os.path.join(game_dir, "*.SF2")))
    if not sf2:
        raise SystemExit("ERROR: no .sf2 sound bank in the game folder (are you in the folder with the .ALD files?)")
    sf2 = sf2[0]

    volumes = find_volumes(game_dir)
    if not volumes:
        raise SystemExit("ERROR: no *MA.ALD music file in the game folder")
    print("Music files:", ", ".join(os.path.basename(p) for p in volumes.values()))
    print("Sound bank:", os.path.basename(sf2))

    files = read_ald(volumes)
    midis = {i: d for i, d in files.items() if d[:4] == b"MThd"}
    if not midis:
        raise SystemExit("ERROR: no MIDI tracks found inside the .ALD")
    print(f"{len(midis)} MIDI tracks found")

    out_dir = os.path.join(game_dir, "midi")
    os.makedirs(out_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for i, data in sorted(midis.items()):
            no = i + 1  # the game asks for track "no"; its ALD index is no-1
            mid = os.path.join(tmp, f"{no}.mid")
            wav = os.path.join(tmp, f"{no}.wav")
            mp3 = os.path.join(out_dir, f"{no}.mp3")
            with open(mid, "wb") as f:
                f.write(data)
            subprocess.run(["fluidsynth", "-ni", "-q", "-g", "0.6", "-r", "44100",
                            "-F", wav, sf2, mid],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav,
                            "-ac", "2", "-ar", "44100", "-b:a", "128k", mp3],
                           check=True)
            print(f"  track {no}: {os.path.getsize(mp3) // 1024} KB")
    print(f"Done: {out_dir}")


if __name__ == "__main__":
    main()
