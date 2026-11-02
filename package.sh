#!/bin/bash
# Monta a pasta de "port" do Onion para um jogo System 3.x (xsystem35-sdl2).
# O mesmo binario serve para qualquer jogo suportado; so muda a pasta.
#
# Uso:
#   sudo ./package.sh [--release] <xsystem35-sdl2> <pasta do jogo> [NomeDaPasta] ["Nome no menu"] [fonte.ttf]
#
# --release: monta o pacote PUBLICO (para os Releases do GitHub): sem os
#   arquivos do jogo, sem capa, com instrucoes em ingles e um .zip pronto em
#   dist/<NomeDaPasta>-miyoo-onion.zip. A pasta do jogo ainda e necessaria:
#   o script le dela o nome do arquivo *SA.ALD e se a musica e MIDI (.sf2).
# Exemplos:
#   sudo ./package.sh ~/xsystem35-sdl2 ~/KichikuouRance KichikuouRance "Kichikuou Rance"
#   sudo ./package.sh ~/xsystem35-sdl2 ~/Rance1 Rance1 "Rance 1"
# NomeDaPasta (sem espacos) vira o nome da pasta, do atalho e da capa.
# Se omitido, usa o nome da pasta do jogo.
#
# O resultado fica em ./dist/<NomeDaPasta>/Roms/... : copie essa pasta "Roms"
# para a raiz do cartao SD (ela se mistura com a Roms/ que ja existe).
#
# Estrutura gerada:
#   Roms/PORTS/Games/<NomeDaPasta>/   binario, launch.sh, lib/, fonts/, game/, save/
#   Roms/PORTS/Shortcuts/Adventure/<NomeDaPasta>.port
#   Roms/PORTS/Imgs/<NomeDaPasta>.png   (capa, se existir <NomeDaPasta>.png ao lado do script)
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
    *[!A-Za-z0-9_-]*) echo "ERRO: NomeDaPasta so pode ter letras, numeros, - e _ (sem espacos): $APP_NAME"; exit 1 ;;
esac
GAME_TITLE="${GAME_TITLE:-$APP_NAME}"
BIN="$SRC/build-arm/src/xsystem35"
OWNER="${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}"

if [ ! -f "$BIN" ]; then
    echo "ERRO: binario nao encontrado em $BIN"
    echo "Rode antes:  sudo ./build.sh $SRC"
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "ERRO: imagem Docker '$IMAGE' nao existe. Rode ./build.sh primeiro."
    exit 1
fi

GAME_DATA_FILE="xsystem35"
IS_MIDI=0
if [ "$RELEASE" = 1 ]; then
    if [ -z "$GAME_SRC" ] || [ ! -d "$GAME_SRC" ]; then
        echo "ERRO: no modo --release a pasta do jogo e obrigatoria (para achar o *SA.ALD)"
        exit 1
    fi
    SA="$(find "$GAME_SRC" -maxdepth 1 -iname '*SA.ALD' -printf '%f\n' | head -1)"
    if [ -z "$SA" ]; then
        echo "ERRO: nao achei o arquivo *SA.ALD em $GAME_SRC"
        exit 1
    fi
    # O Onion so mostra o port quando este arquivo existir (jogo instalado).
    GAME_DATA_FILE="game/$SA"
    if [ -n "$(find "$GAME_SRC" -maxdepth 1 -iname '*.sf2' -print -quit)" ]; then
        IS_MIDI=1
    fi
fi

DIST="$HERE/dist/$APP_NAME"
PORTS="$DIST/Roms/PORTS"
APP="$PORTS/Games/$APP_NAME"
SHORTCUTS="$PORTS/Shortcuts/Adventure"

rm -rf "$DIST"
mkdir -p "$APP/lib" "$APP/fonts" "$APP/game" "$APP/save" "$APP/log" "$SHORTCUTS"
# O script roda como root (sudo), mas o Docker usa o seu usuario: as pastas
# precisam ser suas, senao o strip/cp dentro do container nao consegue gravar.
chown -R "$OWNER" "$DIST" 2>/dev/null || true

##############################################################################
# 1. Binario (sem simbolos de debug, para ficar menor)
##############################################################################
echo "==> Binario"
cp "$BIN" "$APP/xsystem35"
chmod 755 "$APP/xsystem35"
chown "$OWNER" "$APP/xsystem35" 2>/dev/null || true
docker run --rm --user "$OWNER" -v "$DIST":/dist "$IMAGE" \
    arm-linux-gnueabihf-strip -s "/dist/Roms/PORTS/Games/$APP_NAME/xsystem35"

##############################################################################
# 2. Bibliotecas: SDL2 do Miyoo + EGL/GLES virtuais (guardados na imagem em
#    /opt/miyoo-runtime), json-c, zlib e freetype do sysroot. As libs da
#    SigmaStar (libmi_*, libshmvar) NAO vao: o aparelho ja tem as dele
#    (testado sem elas).
##############################################################################
echo "==> Bibliotecas"
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
            echo "  ERRO: $f nao esta na imagem. Rode ./build.sh de novo."
            exit 1
        fi
    done

    # MIDI (opcional): o SDL2_mixer carrega esta lib so se o jogo usar MIDI.
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
            echo "  AVISO: $1 nao encontrada no sysroot (o aparelho precisa ter)"
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
# 3. Fonte (opcional agora, mas necessaria para exibir os kanji no aparelho)
##############################################################################
if [ -n "$FONT_SRC" ]; then
    if [ -f "$FONT_SRC" ]; then
        echo "==> Fonte: $FONT_SRC"
        cp "$FONT_SRC" "$APP/fonts/font.ttf"
    else
        echo "AVISO: fonte nao encontrada: $FONT_SRC"
    fi
else
    echo "==> Sem fonte extra (ok se o jogo trouxer as suas, como MTLc3m.ttf e mincho.otf)"
fi

##############################################################################
# 4. Arquivos do jogo (opcional: voce tambem pode copiar direto pro cartao SD)
##############################################################################
if [ "$RELEASE" = 0 ] && [ -n "$GAME_SRC" ] && [ -d "$GAME_SRC" ]; then
    # Jogos com musica MIDI (trazem um .sf2): grava as musicas em MP3 uma vez,
    # porque sintetizar MIDI no Miyoo e pesado demais.
    if [ -n "$(find "$GAME_SRC" -maxdepth 1 -iname '*.sf2' -print -quit)" ] && [ ! -d "$GAME_SRC/midi" ]; then
        echo "==> Jogo com musica MIDI: gravando as musicas em MP3 (so na primeira vez)"
        if ! python3 "$HERE/tools/prerender_midi.py" "$GAME_SRC"; then
            echo "ERRO: falhou ao gravar as musicas. Instale: sudo apt install fluidsynth ffmpeg"
            rm -rf "$GAME_SRC/midi"
            exit 1
        fi
        chown -R "$OWNER" "$GAME_SRC/midi" 2>/dev/null || true
    fi
fi

if [ "$RELEASE" = 1 ]; then
    echo "==> Release: sem os arquivos do jogo"
    cat > "$APP/game/PUT_GAME_FILES_HERE.txt" <<PLACEHOLDER_EOF
Copy the game files here (the .ALD files and everything else from the
game folder). See ../INSTALL.txt.
PLACEHOLDER_EOF
elif [ -n "$GAME_SRC" ]; then
    if [ -d "$GAME_SRC" ]; then
        echo "==> Copiando o jogo de $GAME_SRC (pode demorar)"
        cp -r "$GAME_SRC"/. "$APP/game/"
    else
        echo "AVISO: pasta do jogo nao encontrada: $GAME_SRC"
    fi
fi

##############################################################################
# 5. launch.sh
##############################################################################
cat > "$APP/launch.sh" <<'LAUNCH_EOF'
#!/bin/sh
# Launcher de jogo System 3.x (xsystem35-sdl2) para Miyoo Mini / OnionOS.
APPDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$APPDIR"
mkdir -p "$APPDIR/save" "$APPDIR/log"
LOGFILE="$APPDIR/log/run.log"

# Bibliotecas: as nossas primeiro; depois as do firmware do aparelho
# (libmi_*, libshmvar, libjson-c) e as do Onion.
export LD_LIBRARY_PATH="$APPDIR/lib:/config/lib:/customer/lib:/mnt/SDCARD/miyoo/lib:/mnt/SDCARD/.tmp_update/lib:${LD_LIBRARY_PATH:-}"

# Drivers do SDL2 do Miyoo Mini (steward-fu/sdl2). Os nomes vem dos
# VideoBootStrap/AudioBootStrap do codigo: video "Mini", audio "Miyoo Mini".
export SDL_VIDEODRIVER="Mini"
export SDL_AUDIODRIVER="Miyoo Mini"

# Musica MIDI: usa o banco de sons (.sf2) que vier com o jogo.
SF2=$(ls "$APPDIR"/game/*.sf2 "$APPDIR"/game/*.SF2 2>/dev/null | head -1)
if [ -n "$SF2" ]; then
    export SDL_SOUNDFONTS="$SF2"
fi

FONT_OPTS=""
if [ -f "$APPDIR/fonts/font.ttf" ]; then
    FONT_OPTS="-ttfont_mincho $APPDIR/fonts/font.ttf -ttfont_gothic $APPDIR/fonts/font.ttf"
fi

{
    echo "== $(basename "$APPDIR") @ $(date)"
    echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
    echo "fonte: ${FONT_OPTS:-nenhuma}"
    echo "soundfont (MIDI): ${SDL_SOUNDFONTS:-nenhum}"
    echo "arquivos do jogo:"
    ls "$APPDIR/game" 2>&1 | head -20
    echo "----"
} > "$LOGFILE" 2>&1

# --- Audio -----------------------------------------------------------------
# O Onion roda um "audioserver" que segura o dispositivo de som (MI_AO). Com
# ele ativo, o driver do SDL falha com "MI_AO_SetPubAttr ... 0xa0052009".
# Os ports oficiais do Onion fazem o mesmo (opcao KillAudioserver=1):
# paramos o audioserver durante o jogo e religamos depois.
unset LD_PRELOAD
AUDIO_CMD=""
for name in audioserver audioserver.mod; do
    PID=$(pidof "$name" 2>/dev/null | awk '{print $1}')
    if [ -n "$PID" ]; then
        AUDIO_CMD=$(tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null)
        echo "parando $name (pid $PID): $AUDIO_CMD" >> "$LOGFILE"
    fi
done
if [ -f /mnt/SDCARD/.tmp_update/script/stop_audioserver.sh ]; then
    . /mnt/SDCARD/.tmp_update/script/stop_audioserver.sh >> "$LOGFILE" 2>&1
fi
killall -9 audioserver audioserver.mod 2>/dev/null
sleep 0.3
echo "processos de audio restantes:" >> "$LOGFILE"
ps 2>/dev/null | grep -i audio | grep -v grep >> "$LOGFILE" 2>&1
echo "----" >> "$LOGFILE"

cd "$APPDIR/game" || exit 1
"$APPDIR/xsystem35" -savedir "$APPDIR/save" $FONT_OPTS >> "$LOGFILE" 2>&1
RC=$?
echo "xsystem35 terminou com codigo $RC" >> "$LOGFILE"

# Religar o audioserver para o resto do Onion voltar a ter som.
if [ -f /mnt/SDCARD/.tmp_update/script/start_audioserver.sh ]; then
    . /mnt/SDCARD/.tmp_update/script/start_audioserver.sh >> "$LOGFILE" 2>&1
elif [ -n "$AUDIO_CMD" ]; then
    ( $AUDIO_CMD >/dev/null 2>&1 & )
fi
exit $RC
LAUNCH_EOF
chmod 755 "$APP/launch.sh"

##############################################################################
# 6. Atalho do Onion (aparece na biblioteca de jogos depois de "Refresh roms")
##############################################################################
# O "~Import ports" do Onion procura GameDataFile (ou GameExecutable, se nao
# houver GameDataFile) DENTRO de Roms/PORTS/Games/<GameDir>/. Por isso GameDir
# e so o nome da pasta. Se o arquivo nao existe, o atalho vira .notfound.
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
# 6b. Capa do jogo na biblioteca do Onion (Roms/PORTS/Imgs/<nome>.png).
#     Usa a <NomeDaPasta>.png que estiver na mesma pasta deste script.
##############################################################################
BOX_ART="$HERE/$APP_NAME.png"
if [ "$RELEASE" = 1 ]; then
    echo "==> Release: sem capa"
elif [ -f "$BOX_ART" ]; then
    mkdir -p "$PORTS/Imgs"
    cp "$BOX_ART" "$PORTS/Imgs/$APP_NAME.png"
    echo "==> Capa: $APP_NAME.png"
else
    echo "AVISO: sem capa (coloque $APP_NAME.png em $HERE)"
fi

##############################################################################
# 7. Instrucoes
##############################################################################
if [ "$RELEASE" = 1 ]; then
    # A ferramenta de MIDI vai dentro da pasta do port (Roms/.../tools/).
    if [ "$IS_MIDI" = 1 ]; then
        mkdir -p "$APP/tools"
        cp "$HERE/tools/prerender_midi.py" "$APP/tools/"
        echo "==> Release: tools/prerender_midi.py incluido (musica MIDI)"
        MIDI_STEP="
4. This game's music is MIDI, which is too heavy to synthesize on the
   Miyoo. Convert it to MP3 once, on the PC:

   Requirements: Linux, or Windows with WSL (Ubuntu), plus:
       sudo apt install python3 fluidsynth ffmpeg

   a. Move prerender_midi.py from
          Roms/PORTS/Games/$APP_NAME/tools/
      into the folder with the game's .ALD files:
          Roms/PORTS/Games/$APP_NAME/game/
   b. Open a WSL terminal in that game folder. On Windows: open the
      folder in File Explorer, type  wsl  in the address bar, press Enter.
   c. Run:
          python3 prerender_midi.py

   It creates a \"midi\" folder there, with one MP3 per track.
"
        NEXT=5
    else
        MIDI_STEP=""
        NEXT=4
    fi
    cat > "$APP/INSTALL.txt" <<RELEASE_EOF
$GAME_TITLE for Miyoo Mini / Miyoo Mini Plus (OnionOS)
============================================================
xsystem35-sdl2 port. Source and instructions: $REPO_URL

This package does NOT include the game. Get it for free from
https://haniwa.technology/games/ (the English .tar.gz build).

1. Extract this zip on your PC.

2. Extract the game .tar.gz on your PC.

3. Copy everything from the game folder (the .ALD files and the rest)
   into the zip's folder:
       Roms/PORTS/Games/$APP_NAME/game/
\${MIDI_STEP}
\${NEXT}. Copy the Roms folder to the ROOT of the SD card (it merges with
   the Roms folder already there).

$((NEXT+1)). In OnionOS, open Ports and run "~Import ports". The game shows up
   once its files are in place.

CONTROLS
  D-pad ............ move the cursor (hold to accelerate)
  R1 (hold) ........ fast cursor
  L1 + D-pad ....... keyboard arrow keys
  A ................ left click
  B ................ right click (cancel / game menu)
  Start ............ Enter
  Select ........... toggle message skip
  Menu ............. quit dialog (A confirms, B cancels)

If the game does not start, check:
       Roms/PORTS/Games/$APP_NAME/log/run.log
RELEASE_EOF
    # As variaveis do texto acima foram escritas literalmente; trocar agora.
    python3 - "$APP/INSTALL.txt" "$MIDI_STEP" "$NEXT" <<'PYEOF'
import sys
path, midi, nxt = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read().replace("${MIDI_STEP}", midi).replace("${NEXT}", nxt)
open(path, "w").write(t)
PYEOF
else
cat > "$APP/INSTALL.txt" <<INSTALL_EOF
$GAME_TITLE (xsystem35-sdl2) para Miyoo Mini + OnionOS
=====================================================

1. Copie a pasta "Roms" deste pacote para a RAIZ do cartao SD do Miyoo
   (ela se mistura com a Roms/ que ja existe).

2. Copie os arquivos do jogo (os .ALD e demais arquivos da instalacao
   original) para:
       /Roms/PORTS/Games/$APP_NAME/game/

3. Para exibir os kanji, coloque uma fonte TrueType japonesa em:
       /Roms/PORTS/Games/$APP_NAME/fonts/font.ttf

4. No Onion, rode "Refresh roms". O jogo aparece na biblioteca.

CONTROLES
  D-pad ............ move o cursor (segure para acelerar)
  R1 (segurar) ..... cursor rapido
  L1 + D-pad ....... setas do teclado
  A ................ clique esquerdo
  B ................ clique direito (cancelar / menu do jogo)
  Start ............ Enter
  Select ........... liga/desliga o pulo de mensagens
  Menu ............. pergunta se quer sair (A confirma, B cancela)

Se nao abrir, veja o arquivo:
       /Roms/PORTS/Games/$APP_NAME/log/run.log
INSTALL_EOF
fi

# Se rodou com sudo, devolver os arquivos para o seu usuario.
chown -R "$OWNER" "$DIST" 2>/dev/null || true

echo
echo "==> Pacote pronto em: $DIST/Roms"
du -sh "$DIST/Roms"
echo
echo "Estrutura:"
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
    echo "==> Zip do Release: $ZIP"
    du -h "$ZIP"
else
    echo "Copie a pasta Roms para a raiz do cartao SD do Miyoo Mini."
fi
