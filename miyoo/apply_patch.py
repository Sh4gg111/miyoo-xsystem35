#!/usr/bin/env python3
"""Aplica o "modo Miyoo Mini" no codigo do xsystem35-sdl2.

Uso: python3 apply_patch.py ~/xsystem35-sdl2

- copia miyoo.c e miyoo.h para src/
- adiciona miyoo.c na lista de fontes do CMake
- insere ganchos (todos dentro de #ifdef MIYOO_MINI) em event.c,
  gfx_draw.c e gfx_video.c

Pode ser rodado varias vezes: o que ja foi aplicado e pulado.
"""
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
MARK = "MIYOO_MINI"


def fail(msg):
    print("ERRO: " + msg)
    sys.exit(1)


def patch(path, edits):
    """edits: lista de (ancora, texto_novo). A ancora precisa existir 1 vez."""
    src = path.read_text(encoding="utf-8")
    if MARK in src:
        print(f"  {path.name}: ja estava aplicado")
        return
    for anchor, new in edits:
        n = src.count(anchor)
        if n != 1:
            fail(f"{path.name}: trecho esperado aparece {n} vezes:\n{anchor}")
        src = src.replace(anchor, new, 1)
    path.write_text(src, encoding="utf-8")
    print(f"  {path.name}: aplicado")


def main():
    if len(sys.argv) != 2:
        fail("uso: apply_patch.py <pasta do xsystem35-sdl2>")
    root = pathlib.Path(sys.argv[1]).expanduser().resolve()
    srcdir = root / "src"
    if not (srcdir / "event.c").exists():
        fail(f"nao achei {srcdir / 'event.c'}")

    print("==> Aplicando modo Miyoo Mini em", root)
    # Volta os arquivos ao original antes de aplicar, para que uma versao
    # nova deste patch substitua a anterior.
    import subprocess
    files = ["src/event.c", "src/gfx_draw.c", "src/gfx_video.c", "src/effect.c",
             "src/midi.sdlmixer.c", "src/CMakeLists.txt"]
    r = subprocess.run(["git", "-C", str(root), "checkout", "--"] + files,
                       capture_output=True, text=True)
    if r.returncode == 0:
        print("  arquivos originais restaurados (git)")
    else:
        print("  AVISO: nao consegui restaurar pelo git: " + r.stderr.strip())
    for f in ("miyoo.c", "miyoo.h"):
        shutil.copy(HERE / f, srcdir / f)
        print(f"  {f}: copiado")

    # CMake: compilar miyoo.c junto
    cm = srcdir / "CMakeLists.txt"
    txt = cm.read_text(encoding="utf-8")
    if "miyoo.c" not in txt:
        anchor = "  event.c\n"
        if txt.count(anchor) != 1:
            fail("src/CMakeLists.txt: nao achei a linha '  event.c'")
        txt = txt.replace(anchor, anchor + "  miyoo.c\n", 1)
        cm.write_text(txt, encoding="utf-8")
        print("  CMakeLists.txt: miyoo.c adicionado")
    else:
        print("  CMakeLists.txt: ja estava aplicado")

    # event.c: botoes -> mouse virtual; atualizar cursor a cada leitura
    patch(srcdir / "event.c", [
        ('#include "volume.h"\n',
         '#include "volume.h"\n'
         '#ifdef MIYOO_MINI\n#include "miyoo.h"\n#endif\n'),
        ("void event_handle_event(SDL_Event *e) {\n",
         "void event_handle_event(SDL_Event *e) {\n"
         "#ifdef MIYOO_MINI\n"
         "\tif (miyoo_handle_event(e))\n"
         "\t\treturn;\n"
         "#endif\n"),
        ("\tscheduler_on_event(scheduler_event);\n",
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_update();\n"
         "#endif\n"
         "\tscheduler_on_event(scheduler_event);\n"),
    ])

    # gfx_draw.c: desenhar o cursor antes de mostrar a tela, e apaga-lo
    # antes de qualquer atualizacao da textura
    patch(srcdir / "gfx_draw.c", [
        ('#include "debugger.h"\n',
         '#include "debugger.h"\n'
         '#ifdef MIYOO_MINI\n#include "miyoo.h"\n#endif\n'),
        ("\tif (!gfx_dirty)\n\t\treturn;\n\tSDL_RenderClear(gfx_renderer);\n",
         "\tif (!gfx_dirty)\n\t\treturn;\n"
         "#ifdef MIYOO_MINI\n"
         "\tif (!redraw_handler)\n"
         "\t\tmiyoo_cursor_show();\n"
         "#endif\n"
         "\tSDL_RenderClear(gfx_renderer);\n"),
        ("\tSDL_RenderPresent(gfx_renderer);\n\tgfx_dirty = false;\n",
         "\tSDL_RenderPresent(gfx_renderer);\n"
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_on_present();\n"
         "#endif\n"
         "\tgfx_dirty = false;\n"),
        # O SDL do Miyoo ignora a posicao do retangulo ao travar a textura:
        # trava a textura inteira e copia para a posicao certa.
        ("\tSDL_Surface *sf;\n"
         "\tSDL_LockTextureToSurface(gfx_texture, &dr, &sf);\n"
         "\tSDL_BlitSurface(main_surface, &sr, sf, NULL);\n",
         "\tSDL_Surface *sf;\n"
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_cursor_hide();\n"
         "\tSDL_LockTextureToSurface(gfx_texture, NULL, &sf);\n"
         "\tSDL_BlitSurface(main_surface, &sr, sf, &dr);\n"
         "#else\n"
         "\tSDL_LockTextureToSurface(gfx_texture, &dr, &sf);\n"
         "\tSDL_BlitSurface(main_surface, &sr, sf, NULL);\n"
         "#endif\n"),
    ])

    # gfx_video.c: textura recriada / mouse "teleportado" pelo jogo
    patch(srcdir / "gfx_video.c", [
        ('#include "gfx_private.h"\n',
         '#include "gfx_private.h"\n'
         '#ifdef MIYOO_MINI\n#include "miyoo.h"\n#include "event.h"\n#endif\n'),
        ("\tgfx_texture = SDL_CreateTexture(\n",
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_cursor_reset();\n"
         "#endif\n"
         "\tgfx_texture = SDL_CreateTexture(\n"),
        ("\tSDL_WarpMouseInWindow(gfx_window, point.x, point.y);\n",
         "\tSDL_WarpMouseInWindow(gfx_window, point.x, point.y);\n"
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_set_cursor(x, y);\n"
         "\tevent_set_mouse_internal_location(x, y);\n"
         "#endif\n"),
    ])
    # effect.c: texturas das transicoes num formato que o Miyoo desenha certo
    patch(srcdir / "effect.c", [
        ('#include "gfx_private.h"\n',
         '#include "gfx_private.h"\n'
         '#ifdef MIYOO_MINI\n'
         '#include "miyoo.h"\n'
         '#define SDL_CreateTextureFromSurface(r, s) miyoo_texture_from_surface(r, s)\n'
         '#define SDL_DestroyTexture(t) miyoo_destroy_texture(t)\n'
         '#endif\n'),
        ("\treturn sdl_RenderTexture(gfx_renderer, t->tx, &real_srcrect, dstrect);\n",
         "#ifdef MIYOO_MINI\n"
         "\tif (miyoo_comp_draw(t->tx, &real_srcrect, dstrect))\n"
         "\t\treturn true;\n"
         "#endif\n"
         "\treturn sdl_RenderTexture(gfx_renderer, t->tx, &real_srcrect, dstrect);\n"),
        ("\tstruct effect *eff = arg;\n"
         "\tif (!eff->is_fullscreen)\n"
         "\t\tsdl_RenderTexture(gfx_renderer, gfx_texture, NULL, NULL);\n"
         "\teff->draw(eff, eff->progress);\n",
         "\tstruct effect *eff = arg;\n"
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_comp_begin();\n"
         "#endif\n"
         "\tif (!eff->is_fullscreen)\n"
         "\t\tsdl_RenderTexture(gfx_renderer, gfx_texture, NULL, NULL);\n"
         "\teff->draw(eff, eff->progress);\n"
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_comp_end();\n"
         "#endif\n"),
    ])
    # midi.sdlmixer.c: tocar musica MIDI pre-gravada (midi/<numero>.mp3 ou
    # .ogg na pasta do jogo) em vez de sintetizar no aparelho, que e pesado
    # demais para o Miyoo.
    patch(srcdir / "midi.sdlmixer.c", [
        ('#include "mixer.h"\n',
         '#include "mixer.h"\n'
         '#ifdef MIYOO_MINI\n'
         '#include <stdio.h>\n'
         '#include <sys/stat.h>\n'
         '/* Procura midi/<no>.mp3 ou midi/<no>.ogg na pasta do jogo. */\n'
         'static bool miyoo_prerendered(int no, char *path, size_t len) {\n'
         '\tstatic const char *ext[] = { "mp3", "ogg" };\n'
         '\tstruct stat st;\n'
         '\tfor (int i = 0; i < 2; i++) {\n'
         '\t\tsnprintf(path, len, "midi/%d.%s", no, ext[i]);\n'
         '\t\tif (stat(path, &st) == 0)\n'
         '\t\t\treturn true;\n'
         '\t}\n'
         '\treturn false;\n'
         '}\n'
         '#endif\n'),
        ("static bool midi_initialize(int subdev) {\n"
         "\treturn mixer_init_midi();\n",
         "static bool midi_initialize(int subdev) {\n"
         "#ifdef MIYOO_MINI\n"
         "\t{\n"
         "\t\tstruct stat st;\n"
         "\t\tif (stat(\"midi\", &st) == 0 && S_ISDIR(st.st_mode)) {\n"
         "\t\t\tNOTICE(\"MIDI: usando musicas pre-gravadas da pasta midi/\");\n"
         "\t\t\treturn true;\n"
         "\t\t}\n"
         "\t}\n"
         "#endif\n"
         "\treturn mixer_init_midi();\n"),
        ("\tmusic = mixer_music_load_midi(data, datalen);\n",
         "#ifdef MIYOO_MINI\n"
         "\tchar path[64];\n"
         "\tif (miyoo_prerendered(no, path, sizeof(path)))\n"
         "\t\tmusic = mixer_music_load_file(path);\n"
         "\telse\n"
         "#endif\n"
         "\tmusic = mixer_music_load_midi(data, datalen);\n"),
    ])
    print("==> Pronto.")


if __name__ == "__main__":
    main()
