#!/bin/bash
# Monta a pasta de "port" do Onion para um jogo System 3.x (xsystem35-sdl2).
# O mesmo binario serve para qualquer jogo suportado; so muda a pasta.
#
# Uso:
#   sudo ./package.sh <xsystem35-sdl2> <pasta do jogo> [NomeDaPasta] ["Nome no menu"] [fonte.ttf]
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
#    SigmaStar (libmi_*, libshmvar) vao em lib/fallback/, que fica no FIM do
#    LD_LIBRARY_PATH: so sao usadas se o aparelho nao tiver as dele.
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

    mkdir -p "$OUT/fallback"
    for f in /opt/miyoo-runtime/libmi_*.so /opt/miyoo-runtime/libshmvar.so; do
        [ -e "$f" ] || continue
        cp -L "$f" "$OUT/fallback/"
        echo "  lib (reserva): $(basename "$f")"
    done

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
if [ -n "$GAME_SRC" ]; then
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
export LD_LIBRARY_PATH="$APPDIR/lib:/config/lib:/customer/lib:/mnt/SDCARD/miyoo/lib:/mnt/SDCARD/.tmp_update/lib:${LD_LIBRARY_PATH:-}:$APPDIR/lib/fallback"

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
GameDataFile="xsystem35"

cd "/mnt/SDCARD/Roms/PORTS/Games/\$GameDir"
exec sh ./launch.sh
PORT_EOF
chmod 755 "$SHORTCUTS/$APP_NAME.port"

##############################################################################
# 6b. Capa do jogo na biblioteca do Onion (Roms/PORTS/Imgs/<nome>.png).
#     Usa a <NomeDaPasta>.png que estiver na mesma pasta deste script.
##############################################################################
BOX_ART="$HERE/$APP_NAME.png"
if [ -f "$BOX_ART" ]; then
    mkdir -p "$PORTS/Imgs"
    cp "$BOX_ART" "$PORTS/Imgs/$APP_NAME.png"
    echo "==> Capa: $APP_NAME.png"
else
    echo "AVISO: sem capa (coloque $APP_NAME.png em $HERE)"
fi

##############################################################################
# 7. Instrucoes
##############################################################################
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

# Se rodou com sudo, devolver os arquivos para o seu usuario.
chown -R "$OWNER" "$DIST" 2>/dev/null || true

echo
echo "==> Pacote pronto em: $DIST/Roms"
du -sh "$DIST/Roms"
echo
echo "Estrutura:"
( cd "$DIST" && find Roms -maxdepth 4 | sort )
echo
echo "Copie a pasta Roms para a raiz do cartao SD do Miyoo Mini."
