# CMake toolchain for the RG DS / RG DS Plus (aarch64, RK3566 Cortex-A55).
# Only works inside the container (rgds/Dockerfile): Debian multiarch, with the
# arm64 libraries in /usr/lib/aarch64-linux-gnu.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_STRIP aarch64-linux-gnu-strip)
# Makes CMake look for libraries in /usr/lib/aarch64-linux-gnu (not the x86-64 ones).
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)

# -DMIYOO_MINI enables the same mode as on the Miyoo (virtual mouse, cursor,
# quit dialog, pre-rendered MIDI music, 60 fps frame pacing). -DRGDS adds
# what differs on the RG DS (extra gptokeyb keys, joystick ignored).
set(RGDS_FLAGS "-mcpu=cortex-a55 -DMIYOO_MINI -DRGDS")
set(CMAKE_C_FLAGS_INIT   "${RGDS_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${RGDS_FLAGS}")

# Uses the device's libraries (SDL2, SDL2_mixer, freetype, zlib); ./libs next
# to the binary comes first, in case one is missing.
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static-libgcc -Wl,--gc-sections -Wl,-rpath,'$ORIGIN/libs'")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
