#!/usr/bin/env python3
"""Pre-grava as musicas MIDI de um jogo System 3.x em MP3.

Sintetizar MIDI no Miyoo Mini pesa demais (a musica engasga e o jogo fica
lento). Este script faz isso uma vez so, no PC:

  1. extrai os MIDIs do arquivo *MA.ALD do jogo;
  2. toca cada um com o FluidSynth usando o banco de sons (.sf2) do jogo;
  3. converte para MP3 em <pasta do jogo>/midi/<numero>.mp3.

O xsystem35 do Miyoo (modo MIYOO_MINI) toca esses MP3 no lugar do MIDI.

Uso:
  python3 prerender_midi.py ~/Rance1

Precisa de:  sudo apt install fluidsynth ffmpeg
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
    """volumes: {numero_do_volume: caminho}. Retorna {indice: bytes}."""
    data = {vol: open(path, "rb").read() for vol, path in volumes.items()}
    first = data[min(data)]
    ofssize = get3(first, 0) << 8
    linksize = (get3(first, 3) << 8) - ofssize
    if ofssize <= 0 or linksize <= 0 or ofssize + linksize > len(first):
        raise SystemExit("ERRO: o arquivo nao parece um .ALD valido")
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
    """Acha <nome>MA.ALD, <nome>MB.ALD... (letra do volume no fim)."""
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
    if len(sys.argv) != 2:
        raise SystemExit("uso: prerender_midi.py <pasta do jogo>")
    game_dir = os.path.abspath(os.path.expanduser(sys.argv[1]))

    for tool in ("fluidsynth", "ffmpeg"):
        if not shutil.which(tool):
            raise SystemExit(f"ERRO: falta o programa '{tool}'. "
                             "Instale com: sudo apt install fluidsynth ffmpeg")

    sf2 = sorted(glob.glob(os.path.join(game_dir, "*.sf2")) +
                 glob.glob(os.path.join(game_dir, "*.SF2")))
    if not sf2:
        raise SystemExit("ERRO: nenhum banco de sons .sf2 na pasta do jogo")
    sf2 = sf2[0]

    volumes = find_volumes(game_dir)
    if not volumes:
        raise SystemExit("ERRO: nenhum arquivo de musica *MA.ALD na pasta do jogo")
    print("Arquivos de musica:", ", ".join(os.path.basename(p) for p in volumes.values()))
    print("Banco de sons:", os.path.basename(sf2))

    files = read_ald(volumes)
    midis = {i: d for i, d in files.items() if d[:4] == b"MThd"}
    if not midis:
        raise SystemExit("ERRO: nenhum MIDI encontrado dentro do .ALD")
    print(f"{len(midis)} musicas MIDI encontradas")

    out_dir = os.path.join(game_dir, "midi")
    os.makedirs(out_dir, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for i, data in sorted(midis.items()):
            no = i + 1  # o jogo pede a musica "no"; o indice no ALD e no-1
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
            print(f"  musica {no}: {os.path.getsize(mp3) // 1024} KB")
    print(f"Pronto: {out_dir}")


if __name__ == "__main__":
    main()
