# Cross-compilation image of xsystem35-sdl2 for the RG DS / RG DS Plus
# (BananaOS and ROCKNIX, via PortMaster). aarch64, Cortex-A55 (RK3566).
#
# Debian bookworm with multiarch: builds on x86-64 against Debian's own arm64
# libraries. The binary uses the DEVICE's SDL2, freetype and zlib (BananaOS and
# ROCKNIX ship them); bookworm's glibc (2.36) is older than theirs, so the
# binary runs on both.
#
# Build:  docker build -t xsystem35-rgds-toolchain rgds/
# (rgds/build-rgds.sh does this by itself)

FROM debian:bookworm

RUN dpkg --add-architecture arm64 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        crossbuild-essential-arm64 cmake pkg-config git ca-certificates \
        python3 file binutils-aarch64-linux-gnu \
        libsdl2-dev:arm64 libsdl2-mixer-dev:arm64 \
        libfreetype-dev:arm64 zlib1g-dev:arm64 && \
    rm -rf /var/lib/apt/lists/*

# pkg-config and CMake only look at the arm64 libraries.
ENV PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig

# FluidSynth, so the SDL2_mixer below can play MIDI music live.
# Without GLib (osal=cpp11), like the Miyoo build; shipped as libs/libfluidsynth.so.3.
ENV GIT_TERMINAL_PROMPT=0
RUN git clone --depth 1 --branch v2.5.7 https://github.com/FluidSynth/fluidsynth /tmp/fluidsynth && \
    cd /tmp/fluidsynth && git submodule update --init --depth 1 gcem && \
    printf '%s\n' \
        'set(CMAKE_SYSTEM_NAME Linux)' \
        'set(CMAKE_SYSTEM_PROCESSOR aarch64)' \
        'set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)' \
        'set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)' \
        'set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)' \
        > /tmp/aarch64.cmake && \
    cmake -S . -B build \
        -DCMAKE_TOOLCHAIN_FILE=/tmp/aarch64.cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/fluid \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_C_FLAGS="-mcpu=cortex-a55 -O2" \
        -DCMAKE_CXX_FLAGS="-mcpu=cortex-a55 -O2" \
        -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++ -static-libgcc" \
        -Dosal=cpp11 -Denable-floats=1 \
        -Denable-libinstpatch=0 -Denable-libsndfile=0 -Denable-alsa=0 \
        -Denable-pulseaudio=0 -Denable-pipewire=0 -Denable-jack=0 -Denable-dbus=0 \
        -Denable-readline=0 -Denable-sdl2=0 -Denable-sdl3=0 -Denable-openmp=0 -Denable-network=0 \
        -Denable-ipv6=0 -Denable-oss=0 -Denable-systemd=0 -Denable-midishare=0 \
        -Denable-ladspa=0 -Denable-aufile=0 -Denable-native-dls=0 && \
    cmake --build build -j"$(nproc)" && cmake --install build && \
    test -e /opt/fluid/lib/libfluidsynth.so.3 && \
    rm -rf /tmp/fluidsynth

# Our own SDL2_mixer, with MIDI through the FluidSynth above: BananaOS's
# SDL2_mixer can't play MIDI. It ships in the port as libs/libSDL2_mixer-2.0.so.0
# and plays MIDI music in real time (the RK3566 can handle it), no conversion.
# Built-in MP3 (minimp3), OGG (stb_vorbis) and WAV; everything else off.
# FluidSynth_DIR points to OUR FluidSynth: Debian's libsdl2-mixer-dev brings
# its own (arm64) and CMake used to pick that one.
RUN git clone --depth 1 --branch release-2.8.1 https://github.com/libsdl-org/SDL_mixer /tmp/mixer && \
    cd /tmp/mixer && \
    cmake -S . -B build \
        -DCMAKE_TOOLCHAIN_FILE=/tmp/aarch64.cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/mixer \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_C_FLAGS="-mcpu=cortex-a55 -O2" \
        -DBUILD_SHARED_LIBS=ON \
        -DSDL2MIXER_VENDORED=OFF -DSDL2MIXER_SAMPLES=OFF \
        -DSDL2MIXER_DEPS_SHARED=OFF \
        -DSDL2MIXER_MIDI=ON -DSDL2MIXER_MIDI_FLUIDSYNTH=ON \
        -DSDL2MIXER_MIDI_TIMIDITY=OFF -DSDL2MIXER_MIDI_NATIVE=OFF \
        -DFluidSynth_DIR=/opt/fluid/lib/cmake/fluidsynth \
        -DFluidSynth_LIBRARY=/opt/fluid/lib/libfluidsynth.so \
        -DFluidSynth_INCLUDE_PATH=/opt/fluid/include \
        -DSDL2MIXER_MP3=ON -DSDL2MIXER_MP3_MINIMP3=ON -DSDL2MIXER_MP3_MPG123=OFF \
        -DSDL2MIXER_VORBIS=STB -DSDL2MIXER_WAVE=ON \
        -DSDL2MIXER_FLAC=OFF -DSDL2MIXER_MOD=OFF -DSDL2MIXER_OPUS=OFF \
        -DSDL2MIXER_WAVPACK=OFF -DSDL2MIXER_GME=OFF && \
    cmake --build build -j"$(nproc)" && cmake --install build && \
    test -e /opt/mixer/lib/libSDL2_mixer-2.0.so.0 && \
    aarch64-linux-gnu-readelf -d /opt/mixer/lib/libSDL2_mixer-2.0.so.0 | grep -q 'libfluidsynth.so.3' && \
    rm -rf /tmp/mixer

WORKDIR /src
