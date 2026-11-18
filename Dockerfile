# Cross-compilation image of xsystem35-sdl2 for the Miyoo Mini (OnionOS).
# Based on OpenRCT2mini's recipe (Packaging/miyoo_mini/Dockerfile).
#
# Build:  docker build -t xsystem35-miyoo-toolchain .
# (build.sh does this by itself the first time)

FROM ghcr.io/onionui/miyoomini-toolchain:latest

# Debian "buster" was archived: point apt to archive.debian.org.
RUN sed -i 's|deb.debian.org|archive.debian.org|g; s|security.debian.org|archive.debian.org|g; /buster-updates/d' \
        /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until && \
    apt-get -o Acquire::AllowInsecureRepositories=true update && \
    apt-get install -y --allow-unauthenticated \
        pkg-config wget tar git autoconf automake libtool gettext && \
    rm -rf /var/lib/apt/lists/*

# Downloads in separate layers: they stay cached and are not redone when
# only build-deps.sh changes.
ENV GIT_TERMINAL_PROMPT=0
RUN git clone --depth 1 https://github.com/steward-fu/sdl2 /opt/steward-sdl2
RUN wget -q -O /opt/SDL2_mixer-2.6.3.tar.gz \
    https://github.com/libsdl-org/SDL_mixer/releases/download/release-2.6.3/SDL2_mixer-2.6.3.tar.gz

# Installs the SDL2 headers (from Steward Fu's repository), the prebuilt Miyoo
# Mini SDL2 and SDL2_mixer into the toolchain sysroot.
COPY build-deps.sh /opt/build-deps.sh
RUN chmod +x /opt/build-deps.sh && bash -lc /opt/build-deps.sh

# Newer CMake: Debian buster's (3.13) is too old for xsystem35, which uses
# "add_library(... ALIAS ...)" on imported targets (needs 3.18+).
RUN mkdir -p /opt/cmake && \
    wget -q -O /tmp/cmake.tar.gz \
        https://github.com/Kitware/CMake/releases/download/v3.27.9/cmake-3.27.9-linux-x86_64.tar.gz && \
    tar xzf /tmp/cmake.tar.gz --strip-components=1 -C /opt/cmake && \
    rm /tmp/cmake.tar.gz

# MIDI music: FluidSynth (without GLib) + SDL2_mixer rebuilt with MIDI.
COPY build-midi.sh /opt/build-midi.sh
RUN apt-get -o Acquire::AllowInsecureRepositories=true update && \
    apt-get install -y --allow-unauthenticated python3 && \
    rm -rf /var/lib/apt/lists/* && \
    chmod +x /opt/build-midi.sh && bash -lc /opt/build-midi.sh

# json-c 0.15 (libjson-c.so.5): the Miyoo SDL2 depends on it and the device
# doesn't have it. The steward-fu/sdl2 README lists json-c-0.15 as a dependency.
RUN SYSROOT=$(/opt/miyoomini-toolchain/usr/bin/arm-linux-gnueabihf-gcc -print-sysroot) && \
    wget -q -O /tmp/jsonc.tar.gz \
        https://github.com/json-c/json-c/archive/refs/tags/json-c-0.15-20200726.tar.gz && \
    mkdir -p /tmp/jsonc/build && \
    tar xzf /tmp/jsonc.tar.gz --strip-components=1 -C /tmp/jsonc && \
    cd /tmp/jsonc/build && \
    /opt/cmake/bin/cmake .. \
        -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
        -DCMAKE_C_COMPILER=/opt/miyoomini-toolchain/usr/bin/arm-linux-gnueabihf-gcc \
        -DCMAKE_C_FLAGS="-marm -mtune=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard -march=armv7ve -O2" \
        -DCMAKE_INSTALL_PREFIX="$SYSROOT/usr" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF \
        -DBUILD_TESTING=OFF -DDISABLE_WERROR=ON && \
    make -j"$(nproc)" && make install && \
    cp -L "$SYSROOT/usr/lib/libjson-c.so.5" /opt/miyoo-runtime/ && \
    ls -la /opt/miyoo-runtime/libjson-c.so.5 && \
    rm -rf /tmp/jsonc /tmp/jsonc.tar.gz

# xsystem35's CMake asks for "sdl2>=2.18.0", but SDL2 never had a 2.18.x: the
# numbering went from 2.0.22 straight to 2.24.0. The Miyoo SDL2 is 2.0.20 and
# pkg-config considers it "too old". Only the version label in sdl2.pc is
# changed. If an SDL function is missing, the compiler will say so.
RUN sed -i 's|^Version:.*|Version: 2.28.0|' \
    /opt/miyoomini-toolchain/arm-linux-gnueabihf/libc/usr/lib/pkgconfig/sdl2.pc && \
    grep -n '^Version' /opt/miyoomini-toolchain/arm-linux-gnueabihf/libc/usr/lib/pkgconfig/sdl2.pc

# The toolchain .pc files (e.g. freetype2.pc) have fixed paths such as
# "includedir=/usr/include/freetype2", only valid inside the sysroot. CMake
# looks for them in the container's /usr and fails. Rewrite to absolute paths.
RUN P=/opt/miyoomini-toolchain/arm-linux-gnueabihf/libc/usr && \
    for f in $P/lib/pkgconfig/*.pc; do \
        sed -i -E "s#^([A-Za-z_]+)=/usr(/|\$)#\1=$P\2#; s#-I/usr/#-I$P/#g; s#-L/usr/#-L$P/#g" "$f"; \
    done && \
    grep -H -E "^(prefix|libdir|includedir)=|^Cflags" $P/lib/pkgconfig/freetype2.pc || true

# pkg-config must search inside the ARM sysroot.
ENV PKG_CONFIG_LIBDIR=/opt/miyoomini-toolchain/arm-linux-gnueabihf/libc/usr/lib/pkgconfig

# The ARM compiler is only added to PATH by .bashrc; make it permanent.
# /opt/cmake/bin comes first so the newer CMake is used.
ENV PATH=/opt/cmake/bin:/opt/miyoomini-toolchain/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /src
