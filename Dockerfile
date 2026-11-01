# Imagem de cross-compilação do xsystem35-sdl2 para Miyoo Mini (OnionOS).
# Baseada na receita do OpenRCT2mini (Packaging/miyoo_mini/Dockerfile).
#
# Construir:  docker build -t xsystem35-miyoo-toolchain .
# (o build.sh faz isso sozinho na primeira vez)

FROM ghcr.io/onionui/miyoomini-toolchain:latest

# O Debian "buster" foi arquivado: apontar o apt para archive.debian.org.
RUN sed -i 's|deb.debian.org|archive.debian.org|g; s|security.debian.org|archive.debian.org|g; /buster-updates/d' \
        /etc/apt/sources.list && \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until && \
    apt-get -o Acquire::AllowInsecureRepositories=true update && \
    apt-get install -y --allow-unauthenticated \
        pkg-config wget tar git autoconf automake libtool gettext && \
    rm -rf /var/lib/apt/lists/*

# Downloads em camadas separadas: ficam em cache e não são refeitos quando
# só o build-deps.sh muda.
ENV GIT_TERMINAL_PROMPT=0
RUN git clone --depth 1 https://github.com/steward-fu/sdl2 /opt/steward-sdl2
RUN wget -q -O /opt/SDL2_mixer-2.6.3.tar.gz \
    https://github.com/libsdl-org/SDL_mixer/releases/download/release-2.6.3/SDL2_mixer-2.6.3.tar.gz

# Instala cabeçalhos do SDL2 (do repositório do Steward Fu), o SDL2 pré-compilado
# do Miyoo Mini e o SDL2_mixer no sysroot da toolchain.
COPY build-deps.sh /opt/build-deps.sh
RUN chmod +x /opt/build-deps.sh && bash -lc /opt/build-deps.sh

# CMake mais novo: o do Debian buster (3.13) nao serve para o xsystem35,
# que usa "add_library(... ALIAS ...)" em alvos importados (precisa de 3.18+).
RUN mkdir -p /opt/cmake && \
    wget -q -O /tmp/cmake.tar.gz \
        https://github.com/Kitware/CMake/releases/download/v3.27.9/cmake-3.27.9-linux-x86_64.tar.gz && \
    tar xzf /tmp/cmake.tar.gz --strip-components=1 -C /opt/cmake && \
    rm /tmp/cmake.tar.gz

# Musica MIDI: FluidSynth (sem GLib) + SDL2_mixer recompilado com MIDI.
COPY build-midi.sh /opt/build-midi.sh
RUN apt-get -o Acquire::AllowInsecureRepositories=true update && \
    apt-get install -y --allow-unauthenticated python3 && \
    rm -rf /var/lib/apt/lists/* && \
    chmod +x /opt/build-midi.sh && bash -lc /opt/build-midi.sh

# json-c 0.15 (libjson-c.so.5): o SDL2 do Miyoo depende dela e o aparelho nao
# a tem. O README do steward-fu/sdl2 lista json-c-0.15 como dependencia.
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

# O CMake do xsystem35 pede "sdl2>=2.18.0", mas o SDL2 nunca teve 2.18.x: a
# numeracao foi de 2.0.22 direto para 2.24.0. O SDL2 do Miyoo e o 2.0.20 e o
# pkg-config o considera "velho". Trocamos so o rotulo de versao no sdl2.pc.
# Se faltar alguma funcao do SDL na compilacao, o erro vai aparecer la.
RUN sed -i 's|^Version:.*|Version: 2.28.0|' \
    /opt/miyoomini-toolchain/arm-linux-gnueabihf/libc/usr/lib/pkgconfig/sdl2.pc && \
    grep -n '^Version' /opt/miyoomini-toolchain/arm-linux-gnueabihf/libc/usr/lib/pkgconfig/sdl2.pc

# Os .pc da toolchain (ex.: freetype2.pc) trazem caminhos fixos como
# "includedir=/usr/include/freetype2", validos so dentro do sysroot. O CMake os
# procura no /usr do container e falha. Reescrever para o caminho absoluto.
RUN P=/opt/miyoomini-toolchain/arm-linux-gnueabihf/libc/usr && \
    for f in $P/lib/pkgconfig/*.pc; do \
        sed -i -E "s#^([A-Za-z_]+)=/usr(/|\$)#\1=$P\2#; s#-I/usr/#-I$P/#g; s#-L/usr/#-L$P/#g" "$f"; \
    done && \
    grep -H -E "^(prefix|libdir|includedir)=|^Cflags" $P/lib/pkgconfig/freetype2.pc || true

# pkg-config precisa procurar dentro do sysroot ARM.
ENV PKG_CONFIG_LIBDIR=/opt/miyoomini-toolchain/arm-linux-gnueabihf/libc/usr/lib/pkgconfig

# O compilador ARM só entra no PATH via .bashrc; deixar fixo na imagem.
# /opt/cmake/bin vem primeiro para usar o CMake novo.
ENV PATH=/opt/cmake/bin:/opt/miyoomini-toolchain/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /src
