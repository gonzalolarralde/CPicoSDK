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

set (SKIP_PICO_MALLOC 1)

# Pull in Raspberry Pi Pico SDK (must be before project)
include(pico_sdk_import.cmake)

project("${PROJECT_NAME}" C CXX ASM)

# Initialise the Raspberry Pi Pico SDK
pico_sdk_init()

include(embed_resources.cmake)

# Add executable. Default name is the project name, version 0.1

add_executable("${PROJECT_NAME}")

pico_set_program_name("${PROJECT_NAME}" "${PROJECT_NAME}")
pico_set_program_version("${PROJECT_NAME}" "0.1")

# Modify the below lines to enable/disable output over UART/USB
pico_enable_stdio_uart("${PROJECT_NAME}" ${STDIO_UART})
pico_enable_stdio_usb("${PROJECT_NAME}" ${STDIO_USB})
pico_enable_stdio_rtt("${PROJECT_NAME}" ${STDIO_RTT})

target_link_options("${PROJECT_NAME}" PRIVATE "LINKER:--wrap=malloc")
target_link_options("${PROJECT_NAME}" PRIVATE "LINKER:--wrap=calloc")
target_link_options("${PROJECT_NAME}" PRIVATE "LINKER:--wrap=realloc")
target_link_options("${PROJECT_NAME}" PRIVATE "LINKER:--wrap=free")

target_compile_definitions("${PROJECT_NAME}" PRIVATE
    PICO_STDIO_USB_ENABLE_RESET_VIA_VENDOR_INTERFACE=1
    PICO_STDIO_USB_ENABLE_RESET_VIA_BAUD_RATE=1
    PICO_ENTER_USB_BOOT_ON_EXIT=1
)

add_library(Output STATIC IMPORTED)
set_target_properties(Output PROPERTIES
    IMPORTED_LOCATION "${IMPORTED_LOCATION}"
)

string(REPLACE "," ";" IMPORTED_LIBS_LIST "${IMPORTED_LIBS}")
target_link_libraries("${PROJECT_NAME}" "-Wl,--start-group")
target_link_libraries("${PROJECT_NAME}" Output)
if(EXTRA_SWIFT_ARCHIVES)
    target_link_libraries("${PROJECT_NAME}" "-Wl,--whole-archive" ${EXTRA_SWIFT_ARCHIVES} "-Wl,--no-whole-archive")
endif()
target_link_libraries("${PROJECT_NAME}" ${IMPORTED_LIBS_LIST})
target_link_libraries("${PROJECT_NAME}" "-Wl,--end-group")
target_link_libraries("${PROJECT_NAME}" pico_async_context_poll)

# Add the standard include files to the build
target_include_directories("${PROJECT_NAME}" PRIVATE
        ${CMAKE_CURRENT_LIST_DIR}
)

target_compile_options("${PROJECT_NAME}" PRIVATE
    -ffunction-sections
    -fdata-sections
)

target_link_options("${PROJECT_NAME}" PRIVATE
    -Wl,--gc-sections
)

cpicosdk_embed_resources(
    "${PROJECT_NAME}"
    "${CPICOSDK_EMBEDDED_RESOURCE_NAMES}"
    "${CPICOSDK_EMBEDDED_RESOURCE_PATHS}"
)

pico_add_extra_outputs("${PROJECT_NAME}")
