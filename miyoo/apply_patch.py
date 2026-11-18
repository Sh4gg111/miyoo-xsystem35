#!/usr/bin/env python3
"""Applies the "Miyoo Mini mode" to the xsystem35-sdl2 source.

Usage: python3 apply_patch.py ~/xsystem35-sdl2

- copies miyoo.c and miyoo.h to src/
- adds miyoo.c to the CMake source list
- inserts hooks (all inside #ifdef MIYOO_MINI) into event.c,
  gfx_draw.c, gfx_video.c, effect.c, midi.sdlmixer.c, mixer.sdl2mixer.c
  (RG DS only) and system.c

Can be run several times: the original files are restored first.
"""
import pathlib
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
MARK = "MIYOO_MINI"


def fail(msg):
    print("ERROR: " + msg)
    sys.exit(1)


def patch(path, edits):
    """edits: list of (anchor, new_text). Each anchor must appear exactly once."""
    src = path.read_text(encoding="utf-8")
    if MARK in src:
        print(f"  {path.name}: already applied")
        return
    for anchor, new in edits:
        n = src.count(anchor)
        if n != 1:
            fail(f"{path.name}: expected text found {n} times:\n{anchor}")
        src = src.replace(anchor, new, 1)
    path.write_text(src, encoding="utf-8")
    print(f"  {path.name}: applied")


def main():
    if len(sys.argv) != 2:
        fail("usage: apply_patch.py <xsystem35-sdl2 folder>")
    root = pathlib.Path(sys.argv[1]).expanduser().resolve()
    srcdir = root / "src"
    if not (srcdir / "event.c").exists():
        fail(f"not found: {srcdir / 'event.c'}")

    print("==> Applying the Miyoo Mini mode to", root)
    # Restore the original files first, so a new version of this patch
    # replaces the previous one.
    import subprocess
    files = ["src/event.c", "src/gfx_draw.c", "src/gfx_video.c", "src/effect.c",
             "src/midi.sdlmixer.c", "src/mixer.sdl2mixer.c", "src/system.c",
             "src/CMakeLists.txt"]
    r = subprocess.run(["git", "-C", str(root), "checkout", "--"] + files,
                       capture_output=True, text=True)
    if r.returncode == 0:
        print("  original files restored (git)")
    else:
        print("  WARNING: could not restore with git: " + r.stderr.strip())
    for f in ("miyoo.c", "miyoo.h"):
        shutil.copy(HERE / f, srcdir / f)
        print(f"  {f}: copied")

    # CMake: build miyoo.c too
    cm = srcdir / "CMakeLists.txt"
    txt = cm.read_text(encoding="utf-8")
    if "miyoo.c" not in txt:
        anchor = "  event.c\n"
        if txt.count(anchor) != 1:
            fail("src/CMakeLists.txt: line '  event.c' not found")
        txt = txt.replace(anchor, anchor + "  miyoo.c\n", 1)
        cm.write_text(txt, encoding="utf-8")
        print("  CMakeLists.txt: miyoo.c added")
    else:
        print("  CMakeLists.txt: already applied")

    # event.c: buttons -> virtual mouse; update the cursor on every poll
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

    # gfx_draw.c: draw the cursor before showing the screen, and erase it
    # before any texture update
    patch(srcdir / "gfx_draw.c", [
        ('#include "debugger.h"\n',
         '#include "debugger.h"\n'
         '#ifdef MIYOO_MINI\n#include "miyoo.h"\n#endif\n'),
        ("\tif (!gfx_dirty)\n\t\treturn;\n\tSDL_RenderClear(gfx_renderer);\n",
         "\tif (!gfx_dirty)\n\t\treturn;\n"
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_frame_begin();\n"
         "\tif (!redraw_handler)\n"
         "\t\tmiyoo_cursor_show();\n"
         "#endif\n"
         "\tSDL_RenderClear(gfx_renderer);\n"),
        ("\tmodal_render_overlay();\n",
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_frame_copied();\n"
         "#endif\n"
         "\tmodal_render_overlay();\n"),
        ("\tSDL_RenderPresent(gfx_renderer);\n\tgfx_dirty = false;\n",
         "\tSDL_RenderPresent(gfx_renderer);\n"
         "#ifdef MIYOO_MINI\n"
         "\tmiyoo_on_present();\n"
         "#endif\n"
         "\tgfx_dirty = false;\n"),
        # The Miyoo SDL ignores the rectangle position when locking a texture:
        # lock the whole texture and copy to the right position.
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

    # gfx_video.c: texture recreated / mouse warped by the game
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
    # effect.c: transition textures composited in software (the Miyoo
    # renderer draws alpha-blended textures incorrectly)
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
    # midi.sdlmixer.c: play pre-rendered MIDI music (midi/<number>.wav, .mp3
    # or .ogg in the game folder) instead of synthesizing it on the device,
    # which is too heavy for the Miyoo.
    patch(srcdir / "midi.sdlmixer.c", [
        ('#include "mixer.h"\n',
         '#include "mixer.h"\n'
         '#if defined(MIYOO_MINI) && !defined(RGDS)\n'
         '#include <stdio.h>\n'
         '#include <sys/stat.h>\n'
         '/* Looks for midi/<no>.wav, .mp3 or .ogg in the game folder. */\n'
         'static bool miyoo_prerendered(int no, char *path, size_t len) {\n'
         '\tstatic const char *ext[] = { "wav", "mp3", "ogg" };\n'
         '\tstruct stat st;\n'
         '\tfor (int i = 0; i < 3; i++) {\n'
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
         "#if defined(MIYOO_MINI) && !defined(RGDS)\n"
         "\t{\n"
         "\t\tstruct stat st;\n"
         "\t\tif (stat(\"midi\", &st) == 0 && S_ISDIR(st.st_mode)) {\n"
         "\t\t\tNOTICE(\"MIDI: using pre-rendered music from the midi/ folder\");\n"
         "\t\t\treturn true;\n"
         "\t\t}\n"
         "\t}\n"
         "#endif\n"
         "\treturn mixer_init_midi();\n"),
        ("\tmusic = mixer_music_load_midi(data, datalen);\n",
         "#if defined(MIYOO_MINI) && !defined(RGDS)\n"
         "\tchar path[64];\n"
         "\tif (miyoo_prerendered(no, path, sizeof(path)))\n"
         "\t\tmusic = mixer_music_load_file(path);\n"
         "\telse\n"
         "#endif\n"
         "\tmusic = mixer_music_load_midi(data, datalen);\n"),
    ])
    # mixer.sdl2mixer.c (RG DS only): if audio fails to open, write the reason
    # to the log, and report which audio driver and MIDI sound bank are used.
    patch(srcdir / "mixer.sdl2mixer.c", [
        ('#include "mixer.h"\n',
         '#include "mixer.h"\n'
         '#if defined(MIYOO_MINI) && defined(RGDS)\n#include <stdio.h>\n#endif\n'),
        ("\tif (Mix_OpenAudioDevice(SAMPLE_RATE, AUDIO_S16LSB, 2, buffer_size, NULL, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE) < 0)\n"
         "\t\treturn false;\n",
         "\tif (Mix_OpenAudioDevice(SAMPLE_RATE, AUDIO_S16LSB, 2, buffer_size, NULL, SDL_AUDIO_ALLOW_FREQUENCY_CHANGE) < 0) {\n"
         "#if defined(MIYOO_MINI) && defined(RGDS)\n"
         "\t\tfprintf(stderr, \"[rgds] audio: failed to open (%s), driver %s\\n\", SDL_GetError(),\n"
         "\t\t        SDL_GetCurrentAudioDriver() ? SDL_GetCurrentAudioDriver() : \"none\");\n"
         "#endif\n"
         "\t\treturn false;\n"
         "\t}\n"
         "#if defined(MIYOO_MINI) && defined(RGDS)\n"
         "\tfprintf(stderr, \"[rgds] audio: ok, driver %s\\n\", SDL_GetCurrentAudioDriver());\n"
         "#endif\n"),
        ("\treturn Mix_Init(MIX_INIT_MID) == MIX_INIT_MID;\n",
         "#if defined(MIYOO_MINI) && defined(RGDS)\n"
         "\t{\n"
         "\t\tbool ok = (Mix_Init(MIX_INIT_MID) & MIX_INIT_MID) != 0;\n"
         "\t\tfprintf(stderr, \"[rgds] MIDI (FluidSynth): %s, sound bank %s\\n\", ok ? \"ok\" : SDL_GetError(),\n"
         "\t\t        Mix_GetSoundFonts() ? Mix_GetSoundFonts() : \"none\");\n"
         "\t\treturn ok;\n"
         "\t}\n"
         "#endif\n"
         "\treturn Mix_Init(MIX_INIT_MID) == MIX_INIT_MID;\n"),
    ])
    # system.c: steady frame pacing (~60/s). The original sleeps 16 ms AFTER
    # drawing; on the Miyoo drawing takes several ms, so frames were uneven
    # and the cursor stuttered. Here it only sleeps for the time left.
    patch(srcdir / "system.c", [
        ('#include "scheduler.h"\n',
         '#include "scheduler.h"\n'
         '#ifdef MIYOO_MINI\n#include "miyoo.h"\n#endif\n'),
        ("#else\n\tSDL_Delay(16);\n#endif\n",
         "#elif defined(MIYOO_MINI)\n"
         "\tmiyoo_wait_frame();\n"
         "#else\n\tSDL_Delay(16);\n#endif\n"),
    ])
    print("==> Done.")


if __name__ == "__main__":
    main()
