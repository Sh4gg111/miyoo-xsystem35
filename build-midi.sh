#!/bin/bash
# MIDI music support (games such as Rance 1 store their soundtrack as MIDI
# and ship a .sf2 sound bank).
#
#  1) FluidSynth 2.5.7 without GLib (osal=cpp11) -> libfluidsynth.so.3
#  2) SDL2_mixer 2.6.3 rebuilt with MIDI through FluidSynth, loaded at run
#     time (if the library is missing, the game runs without MIDI music)
#  3) Performance tweaks for the Miyoo: no reverb/chorus, lower polyphony
#
# Runs INSIDE Docker during "docker build" (after build-deps.sh).

set -euo pipefail

PREFIX=$(arm-linux-gnueabihf-gcc -print-sysroot)/usr
HOST_TRIPLE=arm-linux-gnueabihf
RUNTIME_DIR=/opt/miyoo-runtime
NPROC=$(nproc)
COMMON_CFLAGS="-marm -mtune=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard -march=armv7ve -O2"
BUILD_DIR=/tmp/build-midi
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

##############################################################################
# 1) FluidSynth
##############################################################################
echo "==[ FluidSynth 2.5.7 ]========================================"
cd "$BUILD_DIR"
git clone --depth 1 --branch v2.5.7 https://github.com/FluidSynth/fluidsynth fluidsynth
cd fluidsynth
# GCEM (a math library) comes as a submodule.
git submodule update --init --depth 1 gcem

cat > "$BUILD_DIR/arm.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER ${HOST_TRIPLE}-gcc)
set(CMAKE_CXX_COMPILER ${HOST_TRIPLE}-g++)
set(CMAKE_FIND_ROOT_PATH $(arm-linux-gnueabihf-gcc -print-sysroot))
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

/opt/cmake/bin/cmake -S . -B build \
    -DCMAKE_TOOLCHAIN_FILE="$BUILD_DIR/arm.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_CXX_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc" \
    -Dosal=cpp11 \
    -Denable-floats=1 \
    -Denable-libinstpatch=0 -Denable-libsndfile=0 -Denable-alsa=0 \
    -Denable-pulseaudio=0 -Denable-pipewire=0 -Denable-jack=0 -Denable-dbus=0 \
    -Denable-readline=0 -Denable-sdl3=0 -Denable-openmp=0 -Denable-network=0 \
    -Denable-ipv6=0 -Denable-oss=0 -Denable-systemd=0 -Denable-midishare=0 \
    -Denable-ladspa=0 -Denable-aufile=0 -Denable-native-dls=0
/opt/cmake/bin/cmake --build build -j"$NPROC"
/opt/cmake/bin/cmake --install build

[ -e "$PREFIX/lib/libfluidsynth.so.3" ] || { echo "libfluidsynth.so.3 was not installed"; ls "$PREFIX/lib" | grep -i fluid; exit 1; }
cp -L "$PREFIX/lib/libfluidsynth.so.3" "$RUNTIME_DIR/"
${HOST_TRIPLE}-strip --strip-unneeded "$RUNTIME_DIR/libfluidsynth.so.3"
echo "libfluidsynth dependencies:"
${HOST_TRIPLE}-readelf -d "$RUNTIME_DIR/libfluidsynth.so.3" | grep NEEDED || true

##############################################################################
# 2) SDL2_mixer with MIDI (FluidSynth loaded dynamically)
##############################################################################
echo "==[ SDL2_mixer + MIDI ]========================================"
cd "$BUILD_DIR"
tar xf /opt/SDL2_mixer-2.6.3.tar.gz
cd SDL2_mixer-2.6.3

# Tweaks for the Miyoo CPU: no reverb/chorus, polyphony 64.
python3 - <<'PYEOF'
import pathlib
p = pathlib.Path('src/codecs/music_fluidsynth.c')
s = p.read_text()
s = s.replace(
    '    int (*fluid_settings_setnum)(fluid_settings_t*, const char*, double);\n',
    '    int (*fluid_settings_setnum)(fluid_settings_t*, const char*, double);\n'
    '    int (*fluid_settings_setint)(fluid_settings_t*, const char*, int);\n', 1)
s = s.replace(
    '        FUNCTION_LOADER(fluid_settings_setnum, int (*)(fluid_settings_t*, const char*, double))\n',
    '        FUNCTION_LOADER(fluid_settings_setnum, int (*)(fluid_settings_t*, const char*, double))\n'
    '        FUNCTION_LOADER(fluid_settings_setint, int (*)(fluid_settings_t*, const char*, int))\n', 1)
anchor = '    fluidsynth.fluid_settings_setnum(music->settings, "synth.sample-rate", (double) music_spec.freq);\n'
assert anchor in s, 'sample-rate anchor not found'
s = s.replace(anchor, anchor +
    '    /* Miyoo Mini: save CPU */\n'
    '    fluidsynth.fluid_settings_setint(music->settings, "synth.reverb.active", 0);\n'
    '    fluidsynth.fluid_settings_setint(music->settings, "synth.chorus.active", 0);\n'
    '    fluidsynth.fluid_settings_setint(music->settings, "synth.polyphony", 64);\n', 1)
assert 'fluid_settings_setint)(' in s and 'FUNCTION_LOADER(fluid_settings_setint' in s
p.write_text(s)
print('music_fluidsynth.c patched')
PYEOF

export CC="${HOST_TRIPLE}-gcc"
export CFLAGS="$COMMON_CFLAGS"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export LDFLAGS="-L$PREFIX/lib -Wl,--allow-shlib-undefined -Wl,-rpath-link,$PREFIX/lib"
./configure \
    --host=$HOST_TRIPLE \
    --prefix="$PREFIX" \
    --with-sdl-prefix="$PREFIX" \
    --disable-sdltest \
    --enable-static --disable-shared \
    --enable-music-mp3-minimp3 \
    --enable-music-ogg-stb \
    --enable-music-midi \
    --enable-music-midi-fluidsynth --enable-music-midi-fluidsynth-shared \
    --disable-music-midi-timidity --disable-music-midi-native \
    --disable-music-cmd \
    --disable-music-mod --disable-music-flac --disable-music-opus \
    | tee /tmp/mixer-configure.log
grep -q "dynamic libfluidsynth" /tmp/mixer-configure.log || {
    echo "ERROR: SDL2_mixer did not find libfluidsynth"; exit 1; }
make -j"$NPROC"
make install

rm -rf "$BUILD_DIR"
echo "==[ MIDI done ]==============================================="
