# CMake toolchain for the Miyoo Mini. Only works inside the Docker container
# (the compiler and sysroot paths are the container's).
# Adapted from OpenRCT2mini's toolchainfile.cmake.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(TOOLCHAIN_PREFIX arm-linux-gnueabihf)
set(CMAKE_C_COMPILER ${TOOLCHAIN_PREFIX}-gcc)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}-g++)
set(CMAKE_LINKER ${TOOLCHAIN_PREFIX}-ld)
set(CMAKE_AR ${TOOLCHAIN_PREFIX}-ar)
set(CMAKE_RANLIB ${TOOLCHAIN_PREFIX}-ranlib)
set(CMAKE_STRIP ${TOOLCHAIN_PREFIX}-strip)

execute_process(
    COMMAND ${CMAKE_C_COMPILER} -print-sysroot
    OUTPUT_VARIABLE TOOLCHAIN_SYSROOT
    OUTPUT_STRIP_TRAILING_WHITESPACE
)
set(CMAKE_SYSROOT ${TOOLCHAIN_SYSROOT})
set(CMAKE_FIND_ROOT_PATH ${TOOLCHAIN_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Avoid -isystem for imported headers (it breaks libstdc++'s #include_next).
set(CMAKE_NO_SYSTEM_FROM_IMPORTED TRUE)

# Cortex-A7 with NEON-VFPv4.
# -DMIYOO_MINI enables the Miyoo controls/cursor mode (miyoo/miyoo.c).
set(MIYOOMINI_FLAGS "-marm -mtune=cortex-a7 -mfpu=neon-vfpv4 -mfloat-abi=hard -march=armv7ve -DMIYOO_MINI")
set(CMAKE_C_FLAGS_INIT   "${MIYOOMINI_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${MIYOOMINI_FLAGS}")

# Static C++ runtime; shared libraries are looked up in ./lib next to the binary.
# --allow-shlib-undefined: the Miyoo libSDL2 depends on libraries that only exist on the device (json-c, libmi_*).
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static-libstdc++ -static-libgcc -Wl,--gc-sections -Wl,--allow-shlib-undefined -Wl,-rpath-link,${TOOLCHAIN_SYSROOT}/usr/lib -Wl,-rpath,'$ORIGIN/lib'")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()
