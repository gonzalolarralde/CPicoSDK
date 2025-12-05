# Tell CMake where your external picotool binary is
add_executable(picotool IMPORTED GLOBAL)
set_target_properties(picotool PROPERTIES
    IMPORTED_LOCATION "${PICOTOOL_EXECUTABLE}"
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

project("${PROJECT_NAME}" C CXX ASM)

# Initialise the Raspberry Pi Pico SDK
pico_sdk_init()

# Add executable. Default name is the project name, version 0.1

add_executable("${PROJECT_NAME}" shims.c)

pico_set_program_name("${PROJECT_NAME}" "${PROJECT_NAME}")
pico_set_program_version("${PROJECT_NAME}" "0.1")

# Modify the below lines to enable/disable output over UART/USB
pico_enable_stdio_uart("${PROJECT_NAME}" 1)
pico_enable_stdio_usb("${PROJECT_NAME}" 0)

add_library(Output STATIC IMPORTED)
set_target_properties(Output PROPERTIES
    IMPORTED_LOCATION "${IMPORTED_LOCATION}"
)
target_link_libraries("${PROJECT_NAME}" Output)

string(REPLACE "," ";" IMPORTED_LIBS_LIST "${IMPORTED_LIBS}")
target_link_libraries("${PROJECT_NAME}" ${IMPORTED_LIBS_LIST})

target_link_libraries("${PROJECT_NAME}"
    pico_stdlib
    pico_status_led
    Output
)

# Add the standard include files to the build
target_include_directories("${PROJECT_NAME}" PRIVATE
        ${CMAKE_CURRENT_LIST_DIR}
)

include(lib_to_bundle.cmake)

pico_add_extra_outputs("${PROJECT_NAME}")
