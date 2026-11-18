#!/bin/bash
# Builds the OnionOS "port" folder for a System 3.x game (xsystem35-sdl2).
# The same binary works for every supported game; only the folder changes.
#
# Usage:
#   sudo ./package.sh [--release] <xsystem35-sdl2> <game folder> [FolderName] ["Menu name"] [font.ttf]
#
# --release: builds the PUBLIC package (for GitHub Releases): without the
#   game files and box art, with install instructions and a ready .zip in
#   dist/<FolderName>-miyoo-onion.zip. The game folder is still needed: the
#   script reads the *SA.ALD file name from it and whether the music is MIDI.
# Examples:
#   sudo ./package.sh ~/xsystem35-sdl2 ~/KichikuouRance KichikuouRance "Kichikuou Rance"
#   sudo ./package.sh ~/xsystem35-sdl2 ~/Rance1 Rance1 "Rance 1"
# FolderName (no spaces) becomes the name of the folder, the shortcut and the
# box art. If omitted, the game folder's name is used.
#
# The output is in ./dist/<FolderName>/Roms/... : copy that "Roms" folder to
# the root of the SD card (it merges with the Roms/ folder already there).
#
# Generated layout:
#   Roms/PORTS/Games/<FolderName>/    binary, launch.sh, lib/, fonts/, game/, save/
#                                     (+ midiconv, if the game has MIDI music)
#   Roms/PORTS/Shortcuts/Adventure/<FolderName>.port
#   Roms/PORTS/Imgs/<FolderName>.png  (box art, if <FolderName>.png is next to this script)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASE=0
if [ "${1:-}" = "--release" ]; then
    RELEASE=1
    shift
fi
REPO_URL="https://github.com/Sh4gg111/miyoo-xsystem35"
SRC="${1:-$HOME/xsystem35-sdl2}"
GAME_SRC="${2:-}"
APP_NAME="${3:-}"
GAME_TITLE="${4:-}"
FONT_SRC="${5:-}"
IMAGE=xsystem35-miyoo-toolchain
if [ -z "$APP_NAME" ]; then
    if [ -n "$GAME_SRC" ]; then
        APP_NAME="$(basename "$GAME_SRC")"
    else
        APP_NAME=KichikuouRance
    fi
fi
case "$APP_NAME" in
    *[!A-Za-z0-9_-]*) echo "ERROR: FolderName may only contain letters, digits, - and _ (no spaces): $APP_NAME"; exit 1 ;;
esac
GAME_TITLE="${GAME_TITLE:-$APP_NAME}"
BIN="$SRC/build-arm/src/xsystem35"
OWNER="${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}"

if [ ! -f "$BIN" ]; then
    echo "ERROR: binary not found: $BIN"
    echo "Run first:  sudo ./build.sh $SRC"
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Docker image '$IMAGE' does not exist. Run ./build.sh first."
    exit 1
fi

GAME_DATA_FILE="xsystem35"
IS_MIDI=0
IS_RANCE2=0
if [ "$RELEASE" = 1 ]; then
    if [ -z "$GAME_SRC" ] || [ ! -d "$GAME_SRC" ]; then
        echo "ERROR: --release needs the game folder (to find the *SA.ALD file)"
        exit 1
    fi
    SA="$(find "$GAME_SRC" -maxdepth 1 -iname '*SA.ALD' -printf '%f\n' | head -1)"
    if [ -z "$SA" ]; then
        echo "ERROR: no *SA.ALD file found in $GAME_SRC"
        exit 1
    fi
    # OnionOS only shows the port once this file exists (game installed).
    # "~Import ports" searches with  find <GameDir> -maxdepth 2 -iname <name>,
    # so this must be the bare file name (it is found in game/, level 2).
    GAME_DATA_FILE="$SA"
    # Rance II: the game is haniwa's Japanese build + velt211's translation,
    # which brings System39.ain. The Japanese build also has RANCE2SA.ALD, so
    # the shortcut depends on System39.ain: it only shows up once the
    # translation has been copied.
    if [ "$(echo "$SA" | tr a-z A-Z)" = "RANCE2SA.ALD" ]; then
        IS_RANCE2=1
        GAME_DATA_FILE="System39.ain"
    fi
fi
# Game with MIDI music (ships a .sf2): add the midiconv converter, which
# renders the music to WAV on the Miyoo itself the first time the game starts.
if [ -n "$GAME_SRC" ] && [ -d "$GAME_SRC" ] && \
   [ -n "$(find "$GAME_SRC" -maxdepth 1 -iname '*.sf2' -print -quit)" ]; then
    IS_MIDI=1
fi

DIST="$HERE/dist/$APP_NAME"
PORTS="$DIST/Roms/PORTS"
APP="$PORTS/Games/$APP_NAME"
SHORTCUTS="$PORTS/Shortcuts/Adventure"

rm -rf "$DIST"
mkdir -p "$APP/lib" "$APP/fonts" "$APP/game" "$APP/save" "$APP/log" "$SHORTCUTS"
# The script runs as root (sudo), but Docker runs as your user: the folders
# must be yours, or strip/cp inside the container can't write to them.
chown -R "$OWNER" "$DIST" 2>/dev/null || true

##############################################################################
# 1. Binary (without debug symbols, to make it smaller)
##############################################################################
echo "==> Binary"
cp "$BIN" "$APP/xsystem35"
chmod 755 "$APP/xsystem35"
chown "$OWNER" "$APP/xsystem35" 2>/dev/null || true
docker run --rm --user "$OWNER" -v "$DIST":/dist "$IMAGE" \
    arm-linux-gnueabihf-strip -s "/dist/Roms/PORTS/Games/$APP_NAME/xsystem35"

##############################################################################
# 1b. MIDI music converter (only for games with a .sf2)
##############################################################################
if [ "$IS_MIDI" = 1 ]; then
    echo "==> MIDI music converter (midiconv)"
    docker run --rm --user "$OWNER" -v "$HERE":/src:ro -v "$DIST":/dist "$IMAGE" bash -c '
        set -e
        OUT=/dist/Roms/PORTS/Games/'"$APP_NAME"'/midiconv
        arm-linux-gnueabihf-gcc -O2 -marm -mtune=cortex-a7 -mfpu=neon-vfpv4 \
            -mfloat-abi=hard -march=armv7ve \
            -o "$OUT" /src/tools/midiconv.c \
            $(pkg-config --cflags sdl2) $(pkg-config --libs sdl2) -lfluidsynth -lm \
            -Wl,--allow-shlib-undefined -Wl,-rpath,"\$ORIGIN/lib"
        arm-linux-gnueabihf-strip -s "$OUT"
    '
fi

##############################################################################
# 2. Libraries: the Miyoo SDL2 + virtual EGL/GLES (kept in the image in
#    /opt/miyoo-runtime), json-c, zlib and freetype from the sysroot. The
#    SigmaStar libraries (libmi_*, libshmvar) are NOT included: the device
#    has its own (tested without them).
##############################################################################
echo "==> Libraries"
docker run --rm --user "$OWNER" -v "$DIST":/dist "$IMAGE" bash -c '
    set -e
    SYSROOT=$(arm-linux-gnueabihf-gcc -print-sysroot)
    OUT=/dist/Roms/PORTS/Games/'"$APP_NAME"'/lib
    SKIP=" libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-armhf.so.3 libgcc_s.so.1 "

    for f in libSDL2-2.0.so.0 libEGL.so libGLESv2.so libjson-c.so.5; do
        if [ -e "/opt/miyoo-runtime/$f" ]; then
            cp -L "/opt/miyoo-runtime/$f" "$OUT/$f"
            echo "  lib: $f"
        else
            echo "  ERROR: $f is not in the image. Run ./build.sh again."
            exit 1
        fi
    done

    # MIDI (optional): SDL2_mixer only loads this library if the game uses MIDI.
    if [ -e /opt/miyoo-runtime/libfluidsynth.so.3 ]; then
        cp -L /opt/miyoo-runtime/libfluidsynth.so.3 "$OUT/"
        echo "  lib: libfluidsynth.so.3"
    fi

    find_lib() {
        for d in "$SYSROOT/usr/lib" "$SYSROOT/lib" "$SYSROOT/usr/lib/arm-linux-gnueabihf"; do
            if [ -e "$d/$1" ]; then echo "$d/$1"; return 0; fi
        done
        return 1
    }
    copy_lib() {
        if src=$(find_lib "$1"); then
            cp -L "$src" "$OUT/$1"
            arm-linux-gnueabihf-strip --strip-unneeded "$OUT/$1" 2>/dev/null || true
            echo "  lib: $1"
        else
            echo "  WARNING: $1 not found in the sysroot (the device must have it)"
        fi
    }

    copy_lib libz.so.1
    copy_lib libfreetype.so.6
    for n in $(arm-linux-gnueabihf-readelf -d "$OUT/libfreetype.so.6" | sed -n "s/.*Shared library: \[\(.*\)\]/\1/p"); do
        case "$SKIP" in
            *" $n "*) ;;
            *) copy_lib "$n" ;;
        esac
    done
'

##############################################################################
# 3. Font (optional; needed to show kanji if the game has no fonts of its own)
##############################################################################
if [ -n "$FONT_SRC" ]; then
    if [ -f "$FONT_SRC" ]; then
        echo "==> Font: $FONT_SRC"
        cp "$FONT_SRC" "$APP/fonts/font.ttf"
    else
        echo "WARNING: font not found: $FONT_SRC"
    fi
else
    echo "==> No extra font (fine if the game ships its own, such as MTLc3m.ttf and mincho.otf)"
fi

##############################################################################
# 4. Game files (optional: you can also copy them straight to the SD card)
##############################################################################
if [ "$RELEASE" = 1 ]; then
    echo "==> Release: without the game files"
    cat > "$APP/game/PUT_GAME_FILES_HERE.txt" <<PLACEHOLDER_EOF
Copy the game files here (the .ALD files and everything else from the
game folder). See ../INSTALL.txt.
PLACEHOLDER_EOF
elif [ -n "$GAME_SRC" ]; then
    if [ -d "$GAME_SRC" ]; then
        echo "==> Copying the game from $GAME_SRC (may take a while)"
        cp -r "$GAME_SRC"/. "$APP/game/"
    else
        echo "WARNING: game folder not found: $GAME_SRC"
    fi
fi

##############################################################################
# 5. launch.sh
##############################################################################
cat > "$APP/launch.sh" <<'LAUNCH_EOF'
#!/bin/sh
# System 3.x game launcher (xsystem35-sdl2) for Miyoo Mini / OnionOS.
APPDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APPDIR"
mkdir -p "$APPDIR/save" "$APPDIR/log"
LOGFILE="$APPDIR/log/run.log"

# Libraries: ours first, then the device firmware's
# (libmi_*, libshmvar, libjson-c) and OnionOS's.
export LD_LIBRARY_PATH="$APPDIR/lib:/config/lib:/customer/lib:/mnt/SDCARD/miyoo/lib:/mnt/SDCARD/.tmp_update/lib:${LD_LIBRARY_PATH:-}"

# Miyoo Mini SDL2 drivers (steward-fu/sdl2). The names come from the
# VideoBootStrap/AudioBootStrap in its source: video "Mini", audio "Miyoo Mini".
export SDL_VIDEODRIVER="Mini"
export SDL_AUDIODRIVER="Miyoo Mini"

# Set to 1 to log the cursor frame rate to log/run.log.
export MIYOO_FPS_LOG=0

# MIDI music: use the sound bank (.sf2) that comes with the game.
SF2=$(ls "$APPDIR"/game/*.sf2 "$APPDIR"/game/*.SF2 2>/dev/null | head -1)
if [ -n "$SF2" ]; then
    export SDL_SOUNDFONTS="$SF2"
fi

# MIDI music: the first time, convert the music to WAV (game/midi/), with a
# progress screen. If interrupted, it continues the next time.
# Menu cancels and returns to OnionOS (exit code 3).
if [ -n "$SF2" ] && [ -x "$APPDIR/midiconv" ] && [ ! -f "$APPDIR/game/midi/.done" ]; then
    echo "== midiconv @ $(date)" >> "$APPDIR/log/midiconv.log"
    "$APPDIR/midiconv" "$APPDIR/game" 22050 >> "$APPDIR/log/midiconv.log" 2>&1
    MRC=$?
    echo "midiconv exited with code $MRC" >> "$APPDIR/log/midiconv.log"
    sync
    if [ "$MRC" = 3 ]; then
        exit 0
    fi
fi

FONT_OPTS=""
if [ -f "$APPDIR/fonts/font.ttf" ]; then
    FONT_OPTS="-ttfont_mincho $APPDIR/fonts/font.ttf -ttfont_gothic $APPDIR/fonts/font.ttf"
fi

{
    echo "== $(basename "$APPDIR") @ $(date)"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    echo "font: ${FONT_OPTS:-none}"
    echo "soundfont (MIDI): ${SDL_SOUNDFONTS:-none}"
    echo "game files:"
    ls "$APPDIR/game" 2>&1 | head -20
    echo "----"
} > "$LOGFILE" 2>&1

# --- Audio -----------------------------------------------------------------
# OnionOS runs an "audioserver" that holds the audio device (MI_AO). While it
# runs, the SDL driver fails with "MI_AO_SetPubAttr ... 0xa0052009".
# Onion's official ports do the same (KillAudioserver=1 option): stop the
# audioserver while the game runs and start it again afterwards.
unset LD_PRELOAD
AUDIO_CMD=""
for name in audioserver audioserver.mod; do
    PID=$(pidof "$name" 2>/dev/null | awk '{print $1}')
    if [ -n "$PID" ]; then
        AUDIO_CMD=$(tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null)
        echo "stopping $name (pid $PID): $AUDIO_CMD" >> "$LOGFILE"
    fi
done
if [ -f /mnt/SDCARD/.tmp_update/script/stop_audioserver.sh ]; then
    . /mnt/SDCARD/.tmp_update/script/stop_audioserver.sh >> "$LOGFILE" 2>&1
fi
killall -9 audioserver audioserver.mod 2>/dev/null
sleep 0.3
echo "remaining audio processes:" >> "$LOGFILE"
ps 2>/dev/null | grep -i audio | grep -v grep >> "$LOGFILE" 2>&1
echo "----" >> "$LOGFILE"

# Games with System39.ain (such as the translated Rance II): xsystem35 only
# reads that file if xsystem35.gr has an "Ain System39.ain" line. Add it if
# missing, so nobody has to edit the file by hand.
GR="$APPDIR/game/xsystem35.gr"
AIN=$(ls "$APPDIR/game" 2>/dev/null | grep -i '^system39\.ain$' | head -1)
if [ -f "$GR" ] && [ -n "$AIN" ] && ! grep -qi '^Ain' "$GR"; then
    printf '\nAin %s\n' "$AIN" >> "$GR"
    echo "added 'Ain $AIN' to xsystem35.gr" >> "$LOGFILE"
fi

cd "$APPDIR/game" || exit 1
"$APPDIR/xsystem35" -savedir "$APPDIR/save" $FONT_OPTS >> "$LOGFILE" 2>&1
RC=$?
echo "xsystem35 exited with code $RC" >> "$LOGFILE"

# Start the audioserver again so the rest of OnionOS has sound.
if [ -f /mnt/SDCARD/.tmp_update/script/start_audioserver.sh ]; then
    . /mnt/SDCARD/.tmp_update/script/start_audioserver.sh >> "$LOGFILE" 2>&1
elif [ -n "$AUDIO_CMD" ]; then
    ( $AUDIO_CMD >/dev/null 2>&1 & )
fi
exit $RC
LAUNCH_EOF
chmod 755 "$APP/launch.sh"

##############################################################################
# 6. OnionOS shortcut (shows up in Ports after "~Import ports")
##############################################################################
# Onion's "~Import ports" looks for GameDataFile (or GameExecutable, if there
# is no GameDataFile) INSIDE Roms/PORTS/Games/<GameDir>/. That's why GameDir
# is just the folder name. If the file doesn't exist, the shortcut becomes
# .notfound.
cat > "$SHORTCUTS/$APP_NAME.port" <<PORT_EOF
#!/bin/sh
# main configuration :
GameName="$GAME_TITLE"
GameDir="$APP_NAME"
GameExecutable="xsystem35"
GameDataFile="$GAME_DATA_FILE"

cd "/mnt/SDCARD/Roms/PORTS/Games/\$GameDir"
exec sh ./launch.sh
PORT_EOF
chmod 755 "$SHORTCUTS/$APP_NAME.port"

##############################################################################
# 6b. Box art for the OnionOS library (Roms/PORTS/Imgs/<name>.png).
#     Uses the <FolderName>.png next to this script.
##############################################################################
BOX_ART="$HERE/$APP_NAME.png"
if [ "$RELEASE" = 1 ]; then
    echo "==> Release: no box art"
elif [ -f "$BOX_ART" ]; then
    mkdir -p "$PORTS/Imgs"
    cp "$BOX_ART" "$PORTS/Imgs/$APP_NAME.png"
    echo "==> Box art: $APP_NAME.png"
else
    echo "WARNING: no box art (put $APP_NAME.png in $HERE)"
fi

##############################################################################
# 7. Instructions
##############################################################################
if [ "$RELEASE" = 1 ]; then
    # The MIDI tool goes inside the port folder (Roms/.../tools/).
    if [ "$IS_MIDI" = 1 ]; then
        mkdir -p "$APP/tools"
        cp "$HERE/tools/prerender_midi.py" "$APP/tools/"
        echo "==> Release: tools/prerender_midi.py included (optional, MIDI music)"
        MIDI_NOTE="
MIDI MUSIC
  This game's music is MIDI, which is too heavy to play on the Miyoo while
  the game runs. The FIRST time you open the game, a screen converts the
  music to WAV files (in game/midi/). It takes a few minutes and needs free
  space on the SD card (Rance 1: about 5 min / 200 MB; Rance II and
  Rance III: about 12 min / 430 MB). Press Menu to stop: it continues the
  next time you open the game. After that the game starts directly.

  Optional, faster and smaller: convert the music to MP3 on a PC instead.
  Requirements: Linux, or Windows with WSL (Ubuntu), plus:
      sudo apt install python3 fluidsynth ffmpeg
  a. Move prerender_midi.py from  Roms/PORTS/Games/$APP_NAME/tools/
     into the folder with the game's .ALD files:
         Roms/PORTS/Games/$APP_NAME/game/
  b. Open a WSL terminal in that folder (in File Explorer, type  wsl  in
     the address bar and press Enter).
  c. Run:  python3 prerender_midi.py
  It creates a \"midi\" folder with one MP3 per track; the Miyoo then
  skips the conversion.
"
    else
        MIDI_NOTE=""
    fi
    if [ "$IS_RANCE2" = 1 ]; then
        GAME_STEPS="This package does NOT include the game or the translation. Both are free:
  - the Japanese Rance II (RanceII .tar.gz) from https://haniwa.technology/games/
  - velt211's English translation port from
    https://alicesoft.miraheze.org/wiki/User_blog:Velt211/Rance_II_translation_port_release

1. Extract this zip on your PC.

2. Extract the Japanese RanceII .tar.gz and copy everything from it
   (the .ALD files and the rest) into the zip's folder:
       Roms/PORTS/Games/$APP_NAME/game/

3. Extract the translation (\"Rance II [ENG]\") and copy ONLY these 3 files
   into the same game/ folder, replacing the Japanese ones:
       RANCE2SA.ALD
       RANCE2GA.ald
       System39.ain
   (The other files - SETUP.EXE, System39.exe, System39.ini,
   System39.ain_decrypted - are for Windows and are not needed.)
   The game only shows up in OnionOS once System39.ain is in place.
"
    else
        GAME_STEPS="This package does NOT include the game. Get it for free from
https://haniwa.technology/games/ (the English .tar.gz build).

1. Extract this zip on your PC.

2. Extract the game .tar.gz on your PC.

3. Copy everything from the game folder (the .ALD files and the rest)
   into the zip's folder:
       Roms/PORTS/Games/$APP_NAME/game/
"
    fi
    cat > "$APP/INSTALL.txt" <<RELEASE_EOF
$GAME_TITLE for Miyoo Mini / Miyoo Mini Plus (OnionOS)
============================================================
xsystem35-sdl2 port. Source and instructions: $REPO_URL

\${GAME_STEPS}
4. Copy the Roms folder to the ROOT of the SD card (it merges with
   the Roms folder already there).

5. In OnionOS, open Ports and run "~Import ports". The game shows up
   once its files are in place.
\${MIDI_NOTE}
CONTROLS
  D-pad ............ move the cursor (hold to accelerate)
  R1 (hold) ........ fast cursor
  L1 + D-pad ....... keyboard arrow keys
  A ................ left click
  B ................ right click (cancel / game menu)
  Start ............ Enter
  Select ........... toggle message skip
  Menu ............. pause menu: RESUME / RESTART / EXIT GAME
                     (A selects, B resumes; restart and exit ask
                     "ARE YOU SURE?", press A again to confirm)

If the game does not start, check:
       Roms/PORTS/Games/$APP_NAME/log/run.log
RELEASE_EOF
    # The placeholders in the text above were written literally; fill them in.
    python3 - "$APP/INSTALL.txt" "$MIDI_NOTE" "$GAME_STEPS" <<'PYEOF'
import sys
path, midi, steps = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read().replace("${MIDI_NOTE}", midi).replace("${GAME_STEPS}", steps)
open(path, "w").write(t)
PYEOF
else
cat > "$APP/INSTALL.txt" <<INSTALL_EOF
$GAME_TITLE (xsystem35-sdl2) for Miyoo Mini + OnionOS
=====================================================

1. Copy the "Roms" folder of this package to the ROOT of the Miyoo SD card
   (it merges with the Roms/ folder already there).

2. If the game files are not included yet, copy them (the .ALD files and
   the rest of the game folder) to:
       /Roms/PORTS/Games/$APP_NAME/game/

3. If the game has no fonts of its own, put a Japanese TrueType font in:
       /Roms/PORTS/Games/$APP_NAME/fonts/font.ttf

4. In OnionOS, open Ports and run "~Import ports".

CONTROLS
  D-pad ............ move the cursor (hold to accelerate)
  R1 (hold) ........ fast cursor
  L1 + D-pad ....... keyboard arrow keys
  A ................ left click
  B ................ right click (cancel / game menu)
  Start ............ Enter
  Select ........... toggle message skip
  Menu ............. pause menu: RESUME / RESTART / EXIT GAME
                     (A selects, B resumes; restart and exit ask
                     "ARE YOU SURE?", press A again to confirm)

If the game does not start, check:
       /Roms/PORTS/Games/$APP_NAME/log/run.log
INSTALL_EOF
fi

# If run with sudo, give the files back to your user.
chown -R "$OWNER" "$DIST" 2>/dev/null || true

echo
echo "==> Package ready in: $DIST/Roms"
du -sh "$DIST/Roms"
echo
echo "Layout:"
( cd "$DIST" && find Roms -maxdepth 4 | sort )
echo
if [ "$RELEASE" = 1 ]; then
    ZIP="$HERE/dist/$APP_NAME-miyoo-onion.zip"
    rm -f "$ZIP"
    python3 - "$DIST" "$ZIP" <<'PYEOF'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for d, dirs, files in os.walk(os.path.join(root, "Roms")):
        dirs.sort()
        rel = os.path.relpath(d, root)
        if not files and not dirs:
            z.write(d, rel + "/")
        for f in sorted(files):
            full = os.path.join(d, f)
            z.write(full, os.path.join(rel, f))
PYEOF
    chown "$OWNER" "$ZIP" 2>/dev/null || true
    echo "==> Release zip: $ZIP"
    du -h "$ZIP"
else
    echo "Copy the Roms folder to the root of the Miyoo Mini SD card."
fi
