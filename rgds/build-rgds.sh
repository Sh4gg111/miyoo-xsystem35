#!/bin/bash
# Uso:  sudo ./rgds/build-rgds.sh ~/xsystem35-sdl2
# Constroi a imagem Docker (com cache) e compila o xsystem35-sdl2 para o
# RG DS / RG DS Plus (aarch64). Resultado em <pasta-do-fonte>/build-rgds/
# O build do Miyoo (build-arm/) nao e tocado: os dois podem coexistir.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="${1:-$HOME/xsystem35-sdl2}"
IMAGE=xsystem35-rgds-toolchain

if [ ! -d "$SRC" ]; then
    echo "Pasta do fonte nao encontrada: $SRC"
    echo "Uso: ./rgds/build-rgds.sh /caminho/para/xsystem35-sdl2"
    exit 1
fi

echo "==> Aplicando o patch (o mesmo do Miyoo) no codigo do xsystem35..."
python3 "$REPO/miyoo/apply_patch.py" "$SRC"
if [ -n "${SUDO_UID:-}" ]; then
    chown "$SUDO_UID:$SUDO_GID" "$SRC/src/miyoo.c" "$SRC/src/miyoo.h" 2>/dev/null || true
fi

echo "==> Construindo a imagem (usa cache; so demora na primeira vez)..."
docker build -t "$IMAGE" "$HERE"

echo "==> Compilando xsystem35 para aarch64 (RG DS)..."
docker run --rm \
    --user "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" \
    -v "$SRC":/src \
    -v "$HERE":/toolchain:ro \
    "$IMAGE" \
    bash -c '
        set -e
        cmake -S /src -B /src/build-rgds \
            -DCMAKE_TOOLCHAIN_FILE=/toolchain/toolchain-rgds.cmake \
            -DCMAKE_BUILD_TYPE=Release \
            -DXSYSTEM35_SDL_VERSION=2 \
            -DENABLE_DEBUGGER=OFF \
            -DENABLE_WEBP=OFF \
            -DENABLE_PORTMIDI=OFF
        cmake --build /src/build-rgds -j"$(nproc)"
        B=/src/build-rgds/src/xsystem35
        echo
        file "$B"
        echo "Bibliotecas que o binario pede (todas tem que existir no aparelho):"
        aarch64-linux-gnu-readelf -d "$B" | sed -n "s/.*Shared library: \[\(.*\)\]/  \1/p"
        echo "Maior versao de glibc exigida:"
        aarch64-linux-gnu-objdump -T "$B" | grep -o "GLIBC_[0-9.]*" | sort -uV | tail -1
    '

echo "==> Pronto. Binario em: $SRC/build-rgds/src/xsystem35"
