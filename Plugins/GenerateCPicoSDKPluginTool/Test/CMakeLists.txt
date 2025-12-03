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

set(sdkVersion 2.2.0)
set(toolchainVersion 14_2_Rel1)
set(picotoolVersion 2.2.0-a4)

set(PICO_BOARD "${BOARD_TYPE}" CACHE STRING "Board type")

# Pull in Raspberry Pi Pico SDK (must be before project)
include(pico_sdk_import.cmake)

project(Test C CXX ASM)

# Initialise the Raspberry Pi Pico SDK
pico_sdk_init()

# Add executable. Default name is the project name, version 0.1

add_executable(Test Test.c )

pico_set_program_name(Test "Test")
pico_set_program_version(Test "0.1")

# Modify the below lines to enable/disable output over UART/USB
pico_enable_stdio_uart(Test 0)
pico_enable_stdio_usb(Test 1)

# Add the standard library to the build
target_link_libraries(Test
        pico_stdlib
        pico_status_led)

# Add the standard include files to the build
target_include_directories(Test PRIVATE
        ${CMAKE_CURRENT_LIST_DIR}
)

#pico_add_extra_outputs(Test)

# ----
include(flatten_target_header.cmake)

flatten_target_header(
    Test
    ${CMAKE_SOURCE_DIR}/CPicoSDK.source.h
    ${CMAKE_BINARY_DIR}/CPicoSDK.h
)

# If you want the flattened header to always exist when Test is built:
add_dependencies(Test Test_flatten_header)
# ----
