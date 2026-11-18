#!/bin/bash
# Usage:  ./build.sh ~/xsystem35-sdl2
# Builds the Docker image (cached) and compiles xsystem35-sdl2
# for the Miyoo Mini. Output in <source folder>/build-arm/
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HOME/xsystem35-sdl2}"
IMAGE=xsystem35-miyoo-toolchain

if [ ! -d "$SRC" ]; then
    echo "Source folder not found: $SRC"
    echo "Usage: ./build.sh /path/to/xsystem35-sdl2"
    exit 1
fi

echo "==> Applying the Miyoo Mini patch to the xsystem35 source..."
python3 "$HERE/miyoo/apply_patch.py" "$SRC"
if [ -n "${SUDO_UID:-}" ]; then
    chown "$SUDO_UID:$SUDO_GID" "$SRC/src/miyoo.c" "$SRC/src/miyoo.h" 2>/dev/null || true
fi

echo "==> Building the Docker image (cached; only slow if something changed)..."
docker build -t "$IMAGE" "$HERE"

echo "==> Compiling xsystem35 for ARM..."
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

echo "==> Done. Binary in: $SRC/build-arm/"
