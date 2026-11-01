#!/bin/bash
# Uso:  ./build.sh ~/xsystem35-sdl2
# Constrói a imagem Docker (com cache) e compila o xsystem35-sdl2
# para o Miyoo Mini. Resultado em <pasta-do-fonte>/build-arm/
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HOME/xsystem35-sdl2}"
IMAGE=xsystem35-miyoo-toolchain

if [ ! -d "$SRC" ]; then
    echo "Pasta do fonte nao encontrada: $SRC"
    echo "Uso: ./build.sh /caminho/para/xsystem35-sdl2"
    exit 1
fi

echo "==> Aplicando o modo Miyoo Mini no codigo do xsystem35..."
python3 "$HERE/miyoo/apply_patch.py" "$SRC"
if [ -n "${SUDO_UID:-}" ]; then
    chown "$SUDO_UID:$SUDO_GID" "$SRC/src/miyoo.c" "$SRC/src/miyoo.h" 2>/dev/null || true
fi

echo "==> Construindo a imagem (usa cache; so demora se algo mudou)..."
docker build -t "$IMAGE" "$HERE"

echo "==> Compilando xsystem35 para ARM..."
docker run --rm \
    --user "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" \
    -v "$SRC":/src \
    -v "$HERE":/toolchain:ro \
    "$IMAGE" \
    bash -c '
        cmake --version | head -1
        cmake -S /src -B /src/build-arm \
            -DCMAKE_TOOLCHAIN_FILE=/toolchain/toolchainfile.cmake \
            -DCMAKE_BUILD_TYPE=Release \
            -DENABLE_DEBUGGER=OFF &&
        cmake --build /src/build-arm -j"$(nproc)"
    '

echo "==> Pronto. Binario em: $SRC/build-arm/"
