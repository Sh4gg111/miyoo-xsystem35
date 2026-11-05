# Toolchain do CMake para RG DS / RG DS Plus (aarch64, RK3566 Cortex-A55).
# So funciona dentro do container (rgds/Dockerfile): Debian multiarch, com as
# bibliotecas arm64 em /usr/lib/aarch64-linux-gnu.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_STRIP aarch64-linux-gnu-strip)
# Faz o CMake procurar as libs em /usr/lib/aarch64-linux-gnu (e nao nas x86-64).
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)

# -DMIYOO_MINI liga o mesmo modo do Miyoo (mouse virtual, cursor, dialogo de
# sair, musica MIDI pre-gravada, ritmo de 60 quadros). -DRGDS acrescenta o
# que muda no RG DS (teclas extras do gptokeyb, joystick ignorado).
set(RGDS_FLAGS "-mcpu=cortex-a55 -DMIYOO_MINI -DRGDS")
set(CMAKE_C_FLAGS_INIT   "${RGDS_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${RGDS_FLAGS}")

# Usa as libs do aparelho (SDL2, SDL2_mixer, freetype, zlib); ./libs ao lado
# do binario vem primeiro, para o caso de faltar alguma.
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static-libgcc -Wl,--gc-sections -Wl,-rpath,'$ORIGIN/libs'")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
