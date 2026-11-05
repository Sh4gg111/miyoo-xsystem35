#!/bin/bash
# Monta o port (formato PortMaster) de um jogo System 3.x para o RG DS /
# RG DS Plus, com BananaOS ou ROCKNIX.
#
# Uso:
#   sudo ./rgds/package-rgds.sh [--release] <xsystem35-sdl2> <pasta do jogo> [NomeDaPasta] ["Nome no menu"] [fonte.ttf]
# Exemplos:
#   sudo ./rgds/package-rgds.sh ~/xsystem35-sdl2 ~/Rance1 Rance1 "Rance 1"
#   sudo ./rgds/package-rgds.sh --release ~/xsystem35-sdl2 ~/Rance1 Rance1 "Rance 1"
#
# --release: sem os arquivos do jogo, com instrucoes em ingles e um .zip em
#   dist/rgds/<NomeDaPasta>-rgds-portmaster.zip.
#
# Resultado em dist/rgds/<NomeDaPasta>/ports/ :
#   <NomeDaPasta>.sh          o que aparece em Ports
#   <nomedapasta>/            xsystem35, xsystem35.gptk, libs/, game/, save/, log/
#                             (+ midiconv e libs/libfluidsynth.so.3 se o jogo for MIDI)
# Copie o CONTEUDO dessa pasta "ports" para a pasta roms/ports do cartao.
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
    *[!A-Za-z0-9_-]*) echo "ERRO: NomeDaPasta so pode ter letras, numeros, - e _ (sem espacos): $APP_NAME"; exit 1 ;;
esac
GAME_TITLE="${GAME_TITLE:-$APP_NAME}"
DIR_NAME="$(echo "$APP_NAME" | tr 'A-Z' 'a-z')"
BIN="$SRC/build-rgds/src/xsystem35"
OWNER="${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}"

if [ ! -f "$BIN" ]; then
    echo "ERRO: binario nao encontrado em $BIN"
    echo "Rode antes:  sudo ./rgds/build-rgds.sh $SRC"
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERRO: imagem Docker '$IMAGE' nao existe. Rode ./rgds/build-rgds.sh primeiro."
    exit 1
fi
if [ "$RELEASE" = 1 ] && { [ -z "$GAME_SRC" ] || [ ! -d "$GAME_SRC" ]; }; then
    echo "ERRO: no modo --release a pasta do jogo e obrigatoria (para saber se a musica e MIDI)"
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
# 1. Binario, controles e (para jogos MIDI) o midiconv
##############################################################################
echo "==> Binario"
cp "$BIN" "$APP/xsystem35"
cp "$HERE/xsystem35.gptk" "$APP/xsystem35.gptk"
chmod 755 "$APP/xsystem35"
chown -R "$OWNER" "$APP" 2>/dev/null || true
docker run --rm --user "$OWNER" -v "$DIST":/dist "$IMAGE" \
    aarch64-linux-gnu-strip -s "/dist/ports/$DIR_NAME/xsystem35"

if [ "$IS_MIDI" = 1 ]; then
    echo "==> Conversor de musica MIDI (midiconv + libfluidsynth)"
    docker run --rm --user "$OWNER" -v "$REPO":/repo:ro -v "$DIST":/dist "$IMAGE" bash -c '
        set -e
        OUT=/dist/ports/'"$DIR_NAME"'
        aarch64-linux-gnu-gcc -O2 -mcpu=cortex-a55 -o "$OUT/midiconv" /repo/tools/midiconv.c \
            -I/opt/fluid/include $(pkg-config --cflags sdl2) \
            -L/opt/fluid/lib -lfluidsynth $(pkg-config --libs sdl2) -lm \
            -Wl,-rpath,"\$ORIGIN/libs"
        aarch64-linux-gnu-strip -s "$OUT/midiconv"
        cp -L /opt/fluid/lib/libfluidsynth.so.3 "$OUT/libs/"
        aarch64-linux-gnu-strip --strip-unneeded "$OUT/libs/libfluidsynth.so.3"
        echo "  libfluidsynth pede:"
        aarch64-linux-gnu-readelf -d "$OUT/libs/libfluidsynth.so.3" | sed -n "s/.*Shared library: \[\(.*\)\]/    \1/p"
    '
fi

##############################################################################
# 2. Fonte e jogo
##############################################################################
if [ -n "$FONT_SRC" ]; then
    if [ -f "$FONT_SRC" ]; then cp "$FONT_SRC" "$APP/fonts/font.ttf"; else echo "AVISO: fonte nao encontrada: $FONT_SRC"; fi
fi
if [ "$RELEASE" = 1 ]; then
    echo "==> Release: sem os arquivos do jogo"
    printf '%s\n' "Copy the game files here (the .ALD files and everything else from the" \
        "game folder). See ../INSTALL.txt." > "$APP/game/PUT_GAME_FILES_HERE.txt"
elif [ -n "$GAME_SRC" ] && [ -d "$GAME_SRC" ]; then
    echo "==> Copiando o jogo de $GAME_SRC (pode demorar)"
    cp -r "$GAME_SRC"/. "$APP/game/"
fi

##############################################################################
# 3. Script do PortMaster (o que aparece em Ports)
##############################################################################
cat > "$PORTS/$APP_NAME.sh" <<'PORT_EOF'
#!/bin/bash
# __TITLE__ - xsystem35-sdl2 (AliceSoft System 3.x) para RG DS / RG DS Plus
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

# A pasta do jogo fica ao lado deste script (roms/ports/__DIR__).
GAMEDIR="$(cd "$(dirname "$0")" && pwd)/__DIR__"
[ -d "$GAMEDIR" ] || GAMEDIR="/$directory/ports/__DIR__"
cd "$GAMEDIR" || exit 1
mkdir -p "$GAMEDIR/save" "$GAMEDIR/log"
LOGFILE="$GAMEDIR/log/run.log"
> "$LOGFILE" && exec > >(tee "$LOGFILE") 2>&1

export LD_LIBRARY_PATH="$GAMEDIR/libs:${LD_LIBRARY_PATH:-}"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
# 640x480 esticado para a tela inteira: suavizado fica melhor que pixel duro
# (1024x768 no Plus = 1,6x). Mude para 0 se preferir pixels nitidos.
export SDL_RENDER_SCALE_QUALITY=1
# Mude para 1 para gravar no log/run.log os quadros por segundo do cursor.
export MIYOO_FPS_LOG=0

echo "== __TITLE__ @ $(date)"
echo "CFW: ${CFW_NAME:-?}  aparelho: ${DEVICE_NAME:-?}  tela: ${DISPLAY_WIDTH:-?}x${DISPLAY_HEIGHT:-?}"
echo "arquivos do jogo:"; ls "$GAMEDIR/game" | head -20; echo "----"

# Botoes -> teclas (as mesmas do Miyoo). Select+Start fecha o jogo na marra.
$GPTOKEYB "xsystem35" -c "$GAMEDIR/xsystem35.gptk" &
pm_platform_helper "$GAMEDIR/xsystem35" > /dev/null 2>&1

# Musica MIDI: o SDL2_mixer do aparelho nao toca MIDI, entao na primeira vez
# as musicas sao convertidas para WAV (game/midi/). Menu/X cancela; continua
# da proxima vez.
SF2=$(ls "$GAMEDIR"/game/*.sf2 "$GAMEDIR"/game/*.SF2 2>/dev/null | head -1)
if [ -n "$SF2" ] && [ -x "$GAMEDIR/midiconv" ] && [ ! -f "$GAMEDIR/game/midi/.done" ]; then
    echo "== midiconv"
    "$GAMEDIR/midiconv" "$GAMEDIR/game" 22050 >> "$GAMEDIR/log/midiconv.log" 2>&1
    MRC=$?
    echo "midiconv terminou com codigo $MRC"
    sync
    if [ "$MRC" = 3 ]; then
        pm_finish
        exit 0
    fi
fi

FONT_OPTS=""
if [ -f "$GAMEDIR/fonts/font.ttf" ]; then
    FONT_OPTS="-ttfont_mincho $GAMEDIR/fonts/font.ttf -ttfont_gothic $GAMEDIR/fonts/font.ttf"
fi

cd "$GAMEDIR/game" || exit 1
"$GAMEDIR/xsystem35" -savedir "$GAMEDIR/save" $FONT_OPTS
echo "xsystem35 terminou com codigo $?"
pm_finish
PORT_EOF
sed -i "s|__TITLE__|$GAME_TITLE|g; s|__DIR__|$DIR_NAME|g; s|__REPO__|$REPO_URL|g" "$PORTS/$APP_NAME.sh"
chmod 755 "$PORTS/$APP_NAME.sh"

##############################################################################
# 4. Instrucoes
##############################################################################
if [ "$IS_MIDI" = 1 ]; then
    mkdir -p "$APP/tools"
    cp "$REPO/tools/prerender_midi.py" "$APP/tools/"
    MIDI_NOTE="
MIDI MUSIC
  This game's music is MIDI. The FIRST time you open it, a screen converts
  the music to WAV files (in game/midi/), using the game's own sound bank.
  Press X (or the Menu/Function key) to stop; it continues next time.
  Faster and smaller: run tools/prerender_midi.py on a PC first (see the
  README in $REPO_URL); the handheld then skips the conversion.
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
  X (or Menu) ....... quit dialog (A confirms, B cancels)
  Select + Start .... force quit
  If A and B are swapped on your device, swap the "a" and "b" lines in
  ports/$DIR_NAME/xsystem35.gptk.

If the game does not start, check ports/$DIR_NAME/log/run.log
INSTALL_EOF

chown -R "$OWNER" "$DIST" 2>/dev/null || true
echo
echo "==> Pacote pronto em: $PORTS"
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
                z.writestr(info, fh.read())  # mantem a permissao de execucao
PYEOF
    chown "$OWNER" "$ZIP" 2>/dev/null || true
    echo "==> Zip do Release: $ZIP"
fi
