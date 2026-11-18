#!/bin/bash
# Prepares the Miyoo Mini sysroot to build xsystem35-sdl2:
#  1) SDL2 headers / sdl2-config / sdl2.pc (steward-fu/sdl2 repository)
#  2) the PREBUILT Miyoo Mini libSDL2 (prebuilt/640x480) + SigmaStar libraries
#  3) SDL2_mixer 2.6.3 (built-in MP3 and Ogg)
# freetype and zlib already exist in the toolchain sysroot.
#
# Runs INSIDE Docker during "docker build".
# The repository and the mixer tarball were already downloaded by the Dockerfile.

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
# The toolchain .pc files use "prefix=/usr" (relative to the sysroot). Use an
# absolute path so pkg-config works without PKG_CONFIG_SYSROOT_DIR.
##############################################################################
echo "==[ fixing the prefix of existing .pc files ]================="
for f in "$PREFIX"/lib/pkgconfig/*.pc; do
    [ -f "$f" ] || continue
    sed -i "s|^prefix=/usr$|prefix=$PREFIX|" "$f"
done

##############################################################################
# 1) SDL2 headers and configuration files.
#    Only configure runs (with the same flags as the author's Makefile) to
#    generate SDL_config.h, sdl2-config and sdl2.pc; SDL2 is NOT compiled.
##############################################################################
echo "==[ SDL2: headers and sdl2-config ]============================"
for d in sdl2 mini prebuilt/640x480; do
    [ -e "$SDL_SRC/$d" ] || { echo "Missing $SDL_SRC/$d"; ls "$SDL_SRC"; exit 1; }
done
cd "$SDL_SRC/sdl2"

# SDL_revision.h normally comes from git; provide a stub.
mkdir -p include
cat > include/SDL_revision.h <<'REV_EOF'
#define SDL_REVISION "xsystem35-miyoo-sdl2"
#define SDL_REVISION_NUMBER 0
REV_EOF

./autogen.sh

# The "mini" driver configure already adds its own -mcpu/-mfpu to EXTRA_CFLAGS;
# run without our CFLAGS so -march and -mcpu don't get mixed.
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
make install-data || echo "WARNING: make install-data failed (SDL2 pkg-config/cmake files may be missing)"

[ -f "$PREFIX/include/SDL2/SDL.h" ]  || { echo "SDL.h was not installed";  exit 1; }
[ -x "$PREFIX/bin/sdl2-config" ]     || { echo "sdl2-config was not installed"; exit 1; }

##############################################################################
# 2) Prebuilt SDL2 (640x480, Kichikuou Rance's resolution) and the libraries
#    it depends on. They also go to $RUNTIME_DIR for packaging.
##############################################################################
echo "==[ prebuilt SDL2 + SigmaStar libraries ]======================"
cd "$SDL_SRC"
mkdir -p "$RUNTIME_DIR"
cp prebuilt/640x480/libSDL2-2.0.so.0 prebuilt/640x480/libEGL.so prebuilt/640x480/libGLESv2.so "$RUNTIME_DIR/"
chmod 755 "$RUNTIME_DIR"/*.so*
cp mini/lib/*.so "$RUNTIME_DIR/" 2>/dev/null || true

cp "$RUNTIME_DIR"/*.so* "$PREFIX/lib/"
ln -sf libSDL2-2.0.so.0 "$PREFIX/lib/libSDL2.so"

echo "Libraries the prebuilt libSDL2 depends on:"
${HOST_TRIPLE}-readelf -d "$PREFIX/lib/libSDL2-2.0.so.0" | grep -E "NEEDED|SONAME" || true

# Remove the redundant "-I${includedir}" from sdl2.pc (it confuses C++ headers).
sf="$PREFIX/lib/pkgconfig/sdl2.pc"
if [ -f "$sf" ]; then
    sed -i 's|-I\${includedir} \(-I\${includedir}/SDL2\)|\1|' "$sf"
fi

##############################################################################
# 3) SDL2_mixer - built-in MP3 (minimp3) and Ogg (stb_vorbis). No MIDI.
##############################################################################
echo "==[ SDL2_mixer ]==============================================="
export CFLAGS="$COMMON_CFLAGS"
export CXXFLAGS="$COMMON_CFLAGS"
# Some libraries of the prebuilt SDL2 (json-c, libmi_*) only exist on the device;
# keep the linker from complaining about them during configure tests.
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
# Link test: a minimal program using SDL2 + SDL2_mixer.
##############################################################################
echo "==[ link test ]==============================================="
cat > /tmp/t.c <<'T_EOF'
#include <SDL.h>
#include <SDL_mixer.h>
int main(void) { SDL_Init(0); Mix_Init(0); return 0; }
T_EOF
${HOST_TRIPLE}-gcc $COMMON_CFLAGS /tmp/t.c -o /tmp/t \
    -I"$PREFIX/include/SDL2" -D_REENTRANT -L"$PREFIX/lib" \
    -lSDL2_mixer -lSDL2 -lm -ldl -lpthread \
    -Wl,--allow-shlib-undefined -Wl,-rpath-link,"$PREFIX/lib" \
    || { echo "LINK TEST FAILED"; exit 1; }
echo "link test OK"

rm -rf "$BUILD_DIR"
echo "==[ check ]==================================================="
ls -la "$PREFIX/lib" | grep -i -E "sdl|freetype|EGL|GLES|libmi_" || true
ls -la "$PREFIX/lib/pkgconfig/"
echo "==[ done ]===================================================="
