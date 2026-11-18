#!/bin/bash
# Usage:  sudo ./rgds/build-rgds.sh ~/xsystem35-sdl2
# Builds the Docker image (cached) and compiles xsystem35-sdl2 for the
# RG DS / RG DS Plus (aarch64). Output in <source folder>/build-rgds/
# The Miyoo build (build-arm/) is left alone: both can coexist.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="${1:-$HOME/xsystem35-sdl2}"
IMAGE=xsystem35-rgds-toolchain

if [ ! -d "$SRC" ]; then
    echo "Source folder not found: $SRC"
    echo "Usage: ./rgds/build-rgds.sh /path/to/xsystem35-sdl2"
    exit 1
fi

echo "==> Applying the patch (the same as the Miyoo one) to the xsystem35 source..."
python3 "$REPO/miyoo/apply_patch.py" "$SRC"
if [ -n "${SUDO_UID:-}" ]; then
    chown "$SUDO_UID:$SUDO_GID" "$SRC/src/miyoo.c" "$SRC/src/miyoo.h" 2>/dev/null || true
fi

echo "==> Building the Docker image (cached; only slow the first time)..."
docker build -t "$IMAGE" "$HERE"

echo "==> Compiling xsystem35 for aarch64 (RG DS)..."
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
        echo "Libraries the binary needs (all must exist on the device):"
        aarch64-linux-gnu-readelf -d "$B" | sed -n "s/.*Shared library: \[\(.*\)\]/  \1/p"
        echo "Highest glibc version required:"
        aarch64-linux-gnu-objdump -T "$B" | grep -o "GLIBC_[0-9.]*" | sort -uV | tail -1
    '

echo "==> Done. Binary in: $SRC/build-rgds/src/xsystem35"
