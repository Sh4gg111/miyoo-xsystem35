#!/bin/bash
# Builds the port (PortMaster format) of a System 3.x game for the RG DS /
# RG DS Plus, running BananaOS or ROCKNIX.
#
# Usage:
#   sudo ./rgds/package-rgds.sh [--release] <xsystem35-sdl2> <game folder> [FolderName] ["Menu name"] [font.ttf]
# Examples:
#   sudo ./rgds/package-rgds.sh ~/xsystem35-sdl2 ~/Rance1 Rance1 "Rance 1"
#   sudo ./rgds/package-rgds.sh --release ~/xsystem35-sdl2 ~/Rance1 Rance1 "Rance 1"
#
# --release: without the game files, with install instructions and a .zip in
#   dist/rgds/<FolderName>-rgds-portmaster.zip.
#
# Output in dist/rgds/<FolderName>/ports/ :
#   <FolderName>.sh           what shows up in Ports
#   <foldername>/             xsystem35, xsystem35.gptk, game/, save/, log/,
#                             libs/ (SDL2_mixer with MIDI + FluidSynth)
# Copy the CONTENTS of that "ports" folder to roms/ports on the SD card.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
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
IMAGE=xsystem35-rgds-toolchain

if [ -z "$APP_NAME" ]; then
    if [ -n "$GAME_SRC" ]; then APP_NAME="$(basename "$GAME_SRC")"; else APP_NAME=KichikuouRance; fi
fi
case "$APP_NAME" in
    *[!A-Za-z0-9_-]*) echo "ERROR: FolderName may only contain letters, digits, - and _ (no spaces): $APP_NAME"; exit 1 ;;
esac
GAME_TITLE="${GAME_TITLE:-$APP_NAME}"
DIR_NAME="$(echo "$APP_NAME" | tr 'A-Z' 'a-z')"
BIN="$SRC/build-rgds/src/xsystem35"
OWNER="${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}"

if [ ! -f "$BIN" ]; then
    echo "ERROR: binary not found: $BIN"
    echo "Run first:  sudo ./rgds/build-rgds.sh $SRC"
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERROR: Docker image '$IMAGE' does not exist. Run ./rgds/build-rgds.sh first."
    exit 1
fi
if [ "$RELEASE" = 1 ] && { [ -z "$GAME_SRC" ] || [ ! -d "$GAME_SRC" ]; }; then
    echo "ERROR: --release needs the game folder (to know whether the music is MIDI)"
    exit 1
fi

IS_MIDI=0
if [ -n "$GAME_SRC" ] && [ -d "$GAME_SRC" ] && \
   [ -n "$(find "$GAME_SRC" -maxdepth 1 -iname '*.sf2' -print -quit)" ]; then
    IS_MIDI=1
fi

DIST="$HERE/../dist/rgds/$APP_NAME"
DIST="$(mkdir -p "$DIST" && cd "$DIST" && pwd)"
rm -rf "$DIST"
PORTS="$DIST/ports"
APP="$PORTS/$DIR_NAME"
mkdir -p "$APP/libs" "$APP/fonts" "$APP/game" "$APP/save" "$APP/log"
chown -R "$OWNER" "$DIST" 2>/dev/null || true

##############################################################################
# 1. Binary, controls and audio libraries
##############################################################################
echo "==> Binary"
cp "$BIN" "$APP/xsystem35"
cp "$HERE/xsystem35.gptk" "$APP/xsystem35.gptk"
chmod 755 "$APP/xsystem35"
chown -R "$OWNER" "$APP" 2>/dev/null || true
docker run --rm --user "$OWNER" -v "$DIST":/dist "$IMAGE" \
    aarch64-linux-gnu-strip -s "/dist/ports/$DIR_NAME/xsystem35"

echo "==> Libraries: SDL2_mixer with MIDI (FluidSynth)"
docker run --rm --user "$OWNER" -v "$DIST":/dist "$IMAGE" bash -c '
    set -e
    OUT=/dist/ports/'"$DIR_NAME"'/libs
    cp -L /opt/mixer/lib/libSDL2_mixer-2.0.so.0 /opt/fluid/lib/libfluidsynth.so.3 "$OUT/"
    for f in "$OUT"/*.so.*; do
        aarch64-linux-gnu-strip --strip-unneeded "$f"
        echo "  $(basename "$f") needs:"
        aarch64-linux-gnu-readelf -d "$f" | sed -n "s/.*Shared library: \[\(.*\)\]/    \1/p"
    done
'

##############################################################################
# 2. Font and game
##############################################################################
if [ -n "$FONT_SRC" ]; then
    if [ -f "$FONT_SRC" ]; then cp "$FONT_SRC" "$APP/fonts/font.ttf"; else echo "WARNING: font not found: $FONT_SRC"; fi
fi
if [ "$RELEASE" = 1 ]; then
    echo "==> Release: without the game files"
    printf '%s\n' "Copy the game files here (the .ALD files and everything else from the" \
        "game folder). See ../INSTALL.txt." > "$APP/game/PUT_GAME_FILES_HERE.txt"
elif [ -n "$GAME_SRC" ] && [ -d "$GAME_SRC" ]; then
    echo "==> Copying the game from $GAME_SRC (may take a while)"
    cp -r "$GAME_SRC"/. "$APP/game/"
    # Pre-rendered music from the Miyoo port: here MIDI plays live.
    for m in "$APP"/game/midi "$APP"/game/MIDI; do
        [ -d "$m" ] && rm -rf "$m" && echo "  (Miyoo midi/ folder skipped)"
    done
fi

##############################################################################
# 3. PortMaster script (what shows up in Ports)
##############################################################################
cat > "$PORTS/$APP_NAME.sh" <<'PORT_EOF'
#!/bin/bash
# __TITLE__ - xsystem35-sdl2 (AliceSoft System 3.x) for RG DS / RG DS Plus
# __REPO__

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source "$controlfolder/control.txt"
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

# The game folder is next to this script (roms/ports/__DIR__).
GAMEDIR="$(cd "$(dirname "$0")" && pwd)/__DIR__"
[ -d "$GAMEDIR" ] || GAMEDIR="/$directory/ports/__DIR__"
cd "$GAMEDIR" || exit 1
mkdir -p "$GAMEDIR/save" "$GAMEDIR/log"
LOGFILE="$GAMEDIR/log/run.log"
> "$LOGFILE" && exec > >(tee "$LOGFILE") 2>&1

export LD_LIBRARY_PATH="$GAMEDIR/libs:${LD_LIBRARY_PATH:-}"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
# 640x480 stretched to the whole screen: smoothing looks better than hard
# pixels (1024x768 on the Plus = 1.6x). Set to 0 for sharp pixels.
export SDL_RENDER_SCALE_QUALITY=1
# Set to 1 to log the cursor frame rate to log/run.log.
export MIYOO_FPS_LOG=0
# Set to 1 to log the analog stick movement to log/run.log.
export RGDS_STICK_LOG=0

# Audio: BananaOS has no sound server, SDL goes straight to ALSA.
if [ "${CFW_NAME:-}" = "BananaOS" ]; then
    export SDL_AUDIODRIVER=alsa
fi
# MIDI music played live by FluidSynth, with the game's own sound bank.
SF2=$(ls "$GAMEDIR"/game/*.sf2 "$GAMEDIR"/game/*.SF2 2>/dev/null | head -1)
[ -n "$SF2" ] && export SDL_SOUNDFONTS="$SF2"

echo "== __TITLE__ @ $(date)"
echo "CFW: ${CFW_NAME:-?}  device: ${DEVICE_NAME:-?}  screen: ${DISPLAY_WIDTH:-?}x${DISPLAY_HEIGHT:-?}"
echo "audio: SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-(default)}  MIDI sound bank: ${SDL_SOUNDFONTS:-none}"
echo "sound cards:"; cat /proc/asound/cards 2>&1
echo "game files:"; ls "$GAMEDIR/game" | head -20; echo "----"

# Buttons -> keys (the same as on the Miyoo). Select+Start force-quits the game.
$GPTOKEYB "xsystem35" -c "$GAMEDIR/xsystem35.gptk" &
pm_platform_helper "$GAMEDIR/xsystem35" > /dev/null 2>&1

FONT_OPTS=""
if [ -f "$GAMEDIR/fonts/font.ttf" ]; then
    FONT_OPTS="-ttfont_mincho $GAMEDIR/fonts/font.ttf -ttfont_gothic $GAMEDIR/fonts/font.ttf"
fi

cd "$GAMEDIR/game" || exit 1
"$GAMEDIR/xsystem35" -savedir "$GAMEDIR/save" $FONT_OPTS
echo "xsystem35 exited with code $?"
pm_finish
PORT_EOF
sed -i "s|__TITLE__|$GAME_TITLE|g; s|__DIR__|$DIR_NAME|g; s|__REPO__|$REPO_URL|g" "$PORTS/$APP_NAME.sh"
chmod 755 "$PORTS/$APP_NAME.sh"

##############################################################################
# 4. Instructions
##############################################################################
if [ "$IS_MIDI" = 1 ]; then
    MIDI_NOTE="
MIDI MUSIC
  This game's music is MIDI. It is played live with FluidSynth and the
  game's own sound bank (no conversion needed). A game/midi folder from the
  Miyoo port is not used here and can be deleted.
"
else
    MIDI_NOTE=""
fi
cat > "$APP/INSTALL.txt" <<INSTALL_EOF
$GAME_TITLE for RG DS / RG DS Plus (BananaOS or ROCKNIX, PortMaster)
=====================================================================
xsystem35-sdl2 port. Source and instructions: $REPO_URL

This package does NOT include the game. Get it for free from
https://haniwa.technology/games/ (the English .tar.gz build).

1. Copy everything from the game folder (the .ALD files and the rest) into
       ports/$DIR_NAME/game/
2. Copy the CONTENTS of the "ports" folder ($APP_NAME.sh and $DIR_NAME/)
   into roms/ports on the SD card (BananaOS: the games card, or over
   Wi-Fi with File sharing).
3. Open Ports and start "$APP_NAME".
$MIDI_NOTE
CONTROLS
  D-pad / left stick  move the cursor (hold to accelerate)
  R1 (hold) ......... fast cursor
  L1 + D-pad ........ keyboard arrow keys
  A ................. left click
  B ................. right click (cancel / game menu)
  Start ............. Enter
  Select ............ toggle message skip
  Select + Start .... quit (save first!)
  If A and B are swapped on your device, swap the "a" and "b" lines in
  ports/$DIR_NAME/xsystem35.gptk.

If the game does not start, check ports/$DIR_NAME/log/run.log
INSTALL_EOF

chown -R "$OWNER" "$DIST" 2>/dev/null || true
echo
echo "==> Package ready in: $PORTS"
( cd "$DIST" && find ports -maxdepth 2 | sort )

if [ "$RELEASE" = 1 ]; then
    ZIP="$(cd "$DIST/.." && pwd)/$APP_NAME-rgds-portmaster.zip"
    rm -f "$ZIP"
    python3 - "$DIST" "$ZIP" <<'PYEOF'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for d, dirs, files in os.walk(os.path.join(root, "ports")):
        dirs.sort()
        rel = os.path.relpath(d, root)
        if not files and not dirs:
            z.write(d, rel + "/")
        for f in sorted(files):
            full = os.path.join(d, f)
            info = zipfile.ZipInfo.from_file(full, os.path.join(rel, f))
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as fh:
                z.writestr(info, fh.read())  # keeps the executable permission
PYEOF
    chown "$OWNER" "$ZIP" 2>/dev/null || true
    echo "==> Release zip: $ZIP"
fi
