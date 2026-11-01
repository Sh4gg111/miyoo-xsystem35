#!/bin/bash
# Prepara o sysroot do Miyoo Mini para compilar o xsystem35-sdl2:
#  1) cabeçalhos / sdl2-config / sdl2.pc do SDL2 (repositório steward-fu/sdl2)
#  2) o libSDL2 PRÉ-COMPILADO do Miyoo Mini (prebuilt/640x480) + libs da SigmaStar
#  3) SDL2_mixer 2.6.3 (MP3 e Ogg embutidos)
# freetype e zlib já existem no sysroot da toolchain.
#
# Roda DENTRO do Docker durante o "docker build".
# O repositório e o tarball do mixer já foram baixados pelo Dockerfile.

set -euo pipefail

PREFIX=$(arm-linux-gnueabihf-gcc -print-sysroot)/usr
HOST_TRIPLE=arm-linux-gnueabihf
SDL_SRC=/opt/steward-sdl2
RUNTIME_DIR=/opt/miyoo-runtime
NPROC=$(nproc)

export CC="${HOST_TRIPLE}-gcc"
export CXX="${HOST_TRIPLE}-g++"
export AR="${HOST_TRIPLE}-ar"
export RANLIB="${HOST_TRIPLE}-ranlib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
COMMON_CFLAGS="-marm -mtune=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard -march=armv7ve -O2"

##############################################################################
# Os .pc da toolchain usam "prefix=/usr" (relativo ao sysroot). Trocar por
# caminho absoluto para o pkg-config funcionar sem PKG_CONFIG_SYSROOT_DIR.
##############################################################################
echo "==[ ajustando prefix dos .pc existentes ]======================"
for f in "$PREFIX"/lib/pkgconfig/*.pc; do
    [ -f "$f" ] || continue
    sed -i "s|^prefix=/usr$|prefix=$PREFIX|" "$f"
done

##############################################################################
# 1) Cabeçalhos e arquivos de configuração do SDL2.
#    So rodamos o configure (com os mesmos flags do Makefile do autor) para
#    gerar SDL_config.h, sdl2-config e sdl2.pc; NAO compilamos o SDL2.
##############################################################################
echo "==[ SDL2: cabecalhos e sdl2-config ]============================"
for d in sdl2 mini prebuilt/640x480; do
    [ -e "$SDL_SRC/$d" ] || { echo "Faltou $SDL_SRC/$d"; ls "$SDL_SRC"; exit 1; }
done
cd "$SDL_SRC/sdl2"

# SDL_revision.h normalmente vem do git; garantir um stub.
mkdir -p include
cat > include/SDL_revision.h <<'REV_EOF'
#define SDL_REVISION "xsystem35-miyoo-sdl2"
#define SDL_REVISION_NUMBER 0
REV_EOF

./autogen.sh

# O configure do driver "mini" ja injeta seus proprios -mcpu/-mfpu em EXTRA_CFLAGS;
# rodar sem CFLAGS nossos para nao misturar -march com -mcpu.
(
    unset CFLAGS CXXFLAGS
    ./configure \
        --host=$HOST_TRIPLE \
        --prefix="$PREFIX" \
        --disable-oss --disable-alsa \
        --disable-video-opengl --disable-video-opengles --disable-video-opengles2 \
        --disable-video-x11 --disable-video-wayland --disable-video-kmsdrm \
        --disable-video-vulkan --disable-pulseaudio --disable-jack --disable-sndio \
        --disable-dbus --disable-ime --disable-fcitx --disable-libudev --disable-hidapi \
        --enable-audio-mini --enable-video-mini
)

make install-hdrs
make install-bin
make install-data || echo "AVISO: make install-data falhou (pkg-config/cmake do SDL2 podem faltar)"

[ -f "$PREFIX/include/SDL2/SDL.h" ]  || { echo "SDL.h nao foi instalado";  exit 1; }
[ -x "$PREFIX/bin/sdl2-config" ]     || { echo "sdl2-config nao foi instalado"; exit 1; }

##############################################################################
# 2) SDL2 pré-compilado (640x480, a resolução do Kichikuou Rance) e as libs
#    de que ele depende. Elas ficam tambem em $RUNTIME_DIR para empacotar.
##############################################################################
echo "==[ SDL2 pre-compilado + libs SigmaStar ]======================="
cd "$SDL_SRC"
mkdir -p "$RUNTIME_DIR"
cp prebuilt/640x480/libSDL2-2.0.so.0 prebuilt/640x480/libEGL.so prebuilt/640x480/libGLESv2.so "$RUNTIME_DIR/"
chmod 755 "$RUNTIME_DIR"/*.so*
cp mini/lib/*.so "$RUNTIME_DIR/" 2>/dev/null || true

cp "$RUNTIME_DIR"/*.so* "$PREFIX/lib/"
ln -sf libSDL2-2.0.so.0 "$PREFIX/lib/libSDL2.so"

echo "Bibliotecas de que o libSDL2 pre-compilado depende:"
${HOST_TRIPLE}-readelf -d "$PREFIX/lib/libSDL2-2.0.so.0" | grep -E "NEEDED|SONAME" || true

# Tirar o "-I${includedir}" redundante do sdl2.pc (atrapalha headers do C++).
sf="$PREFIX/lib/pkgconfig/sdl2.pc"
if [ -f "$sf" ]; then
    sed -i 's|-I\${includedir} \(-I\${includedir}/SDL2\)|\1|' "$sf"
fi

##############################################################################
# 3) SDL2_mixer — MP3 (minimp3) e Ogg (stb_vorbis) embutidos. Sem MIDI.
##############################################################################
echo "==[ SDL2_mixer ]==============================================="
export CFLAGS="$COMMON_CFLAGS"
export CXXFLAGS="$COMMON_CFLAGS"
# Algumas libs do SDL2 pre-compilado (json-c, libmi_*) so existem no aparelho;
# nao deixar o linker reclamar delas durante os testes do configure.
export LDFLAGS="-L$PREFIX/lib -Wl,--allow-shlib-undefined -Wl,-rpath-link,$PREFIX/lib"

BUILD_DIR=/tmp/build-deps
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
tar xf /opt/SDL2_mixer-2.6.3.tar.gz
cd SDL2_mixer-2.6.3
./configure \
    --host=$HOST_TRIPLE \
    --prefix="$PREFIX" \
    --with-sdl-prefix="$PREFIX" \
    --disable-sdltest \
    --enable-static --disable-shared \
    --enable-music-mp3-minimp3 \
    --enable-music-ogg-stb \
    --disable-music-cmd --disable-music-midi \
    --disable-music-mod --disable-music-flac --disable-music-opus
make -j$NPROC
make install

##############################################################################
# Teste de link: um programa minimo usando SDL2 + SDL2_mixer.
##############################################################################
echo "==[ teste de link ]============================================"
cat > /tmp/t.c <<'T_EOF'
#include <SDL.h>
#include <SDL_mixer.h>
int main(void) { SDL_Init(0); Mix_Init(0); return 0; }
T_EOF
${HOST_TRIPLE}-gcc $COMMON_CFLAGS /tmp/t.c -o /tmp/t \
    -I"$PREFIX/include/SDL2" -D_REENTRANT -L"$PREFIX/lib" \
    -lSDL2_mixer -lSDL2 -lm -ldl -lpthread \
    -Wl,--allow-shlib-undefined -Wl,-rpath-link,"$PREFIX/lib" \
    || { echo "TESTE DE LINK FALHOU"; exit 1; }
echo "teste de link OK"

rm -rf "$BUILD_DIR"
echo "==[ verificacao ]=============================================="
ls -la "$PREFIX/lib" | grep -i -E "sdl|freetype|EGL|GLES|libmi_" || true
ls -la "$PREFIX/lib/pkgconfig/"
echo "==[ pronto ]==================================================="
