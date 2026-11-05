# Imagem de cross-compilacao do xsystem35-sdl2 para o RG DS / RG DS Plus
# (BananaOS e ROCKNIX, via PortMaster). aarch64, Cortex-A55 (RK3566).
#
# Debian bookworm com multiarch: compila em x86-64 contra as bibliotecas
# arm64 do proprio Debian. O binario usa o SDL2, SDL2_mixer, freetype e zlib
# do APARELHO (o BananaOS e o ROCKNIX ja tem); a glibc do bookworm (2.36)
# e mais velha que a deles, entao o binario roda nos dois.
#
# Construir:  docker build -t xsystem35-rgds-toolchain rgds/
# (o rgds/build-rgds.sh faz isso sozinho)

FROM debian:bookworm

RUN dpkg --add-architecture arm64 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        crossbuild-essential-arm64 cmake pkg-config git ca-certificates \
        python3 file binutils-aarch64-linux-gnu \
        libsdl2-dev:arm64 libsdl2-mixer-dev:arm64 \
        libfreetype-dev:arm64 zlib1g-dev:arm64 && \
    rm -rf /var/lib/apt/lists/*

# pkg-config e CMake procurando so as bibliotecas arm64.
ENV PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig

# FluidSynth so para o midiconv (converte a musica MIDI uma vez, no aparelho).
# Sem GLib (osal=cpp11), como no build do Miyoo; vai como libs/libfluidsynth.so.3.
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

WORKDIR /src
