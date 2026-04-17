# Tell CMake where your external picotool binary is
add_executable(picotool IMPORTED GLOBAL)
set_target_properties(picotool PROPERTIES
    IMPORTED_LOCATION "${PICOTOOL_PATH}"
)

# Generated Cmake Pico project file

cmake_minimum_required(VERSION 3.13)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Initialise pico_sdk from installed location
# (note this can come from environment, CMake cache etc)

set(sdkVersion "${SDK_VERSION}")
set(toolchainVersion "${TOOLCHAIN_VERSION}")
set(picotoolVersion "${SDK_VERSION}")

set(PICO_BOARD "${BOARD_TYPE}" CACHE STRING "Board type")

# Pull in Raspberry Pi Pico SDK (must be before project)
include(pico_sdk_import.cmake)

project(CMakeHarness C CXX ASM)

# Initialise the Raspberry Pi Pico SDK
pico_sdk_init()

# Add executable. Default name is the project name, version 0.1

add_executable(CMakeHarness main.c)

pico_set_program_name(CMakeHarness "CMakeHarness")
pico_set_program_version(CMakeHarness "0.1")

pico_enable_stdio_uart(CMakeHarness 0)
pico_enable_stdio_usb(CMakeHarness 0)
pico_enable_stdio_rtt(CMakeHarness 0)

target_compile_definitions("${PROJECT_NAME}" PRIVATE
    PICO_STDIO_USB_ENABLE_RESET_VIA_VENDOR_INTERFACE=1
    PICO_STDIO_USB_ENABLE_RESET_VIA_BAUD_RATE=1
    PICO_ENTER_USB_BOOT_ON_EXIT=1
)

string(REPLACE "," ";" IMPORTED_LIBS_LIST "${IMPORTED_LIBS}")
target_link_libraries(CMakeHarness ${IMPORTED_LIBS_LIST})
target_link_libraries(CMakeHarness pico_async_context_poll)

# Add the standard include files to the build
target_include_directories(CMakeHarness PRIVATE
        ${CMAKE_CURRENT_LIST_DIR}
)

# ----
include(flatten_target_header.cmake)

flatten_target_header(
    CMakeHarness
    ${CMAKE_SOURCE_DIR}/CPicoSDK_${COMBINATION}.source.h
    ${CMAKE_BINARY_DIR}/CPicoSDK_${COMBINATION}.h
)

add_dependencies(CMakeHarness CMakeHarness_flatten_header)
# ----
