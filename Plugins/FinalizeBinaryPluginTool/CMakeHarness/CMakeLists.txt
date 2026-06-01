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
target_sources("${PROJECT_NAME}" PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/runtime_coprocessors.c
)

pico_set_program_name("${PROJECT_NAME}" "${PROJECT_NAME}")
pico_set_program_version("${PROJECT_NAME}" "0.1")

set(CPICOSDK_HOT_MEMMAP_SOURCE "${PICO_SDK_PATH}/src/rp2_common/pico_crt0/${PICO_CHIP}/memmap_default.ld")
set(CPICOSDK_HOT_MEMMAP "${CMAKE_CURRENT_BINARY_DIR}/memmap_cpicosdk_hot.ld")
if(NOT DEFINED CPICOSDK_CORE0_STACK_SIZE_BYTES)
    set(CPICOSDK_CORE0_STACK_SIZE_BYTES "8192")
endif()
if(NOT DEFINED CPICOSDK_CORE1_STACK_SIZE_BYTES)
    set(CPICOSDK_CORE1_STACK_SIZE_BYTES "8192")
endif()
if(CPICOSDK_CORE0_STACK_SIZE_BYTES LESS_EQUAL 0)
    message(FATAL_ERROR "CPICOSDK_CORE0_STACK_SIZE_BYTES must be greater than 0")
endif()
if(CPICOSDK_CORE1_STACK_SIZE_BYTES LESS 0)
    message(FATAL_ERROR "CPICOSDK_CORE1_STACK_SIZE_BYTES must be greater than or equal to 0")
endif()
file(READ "${CPICOSDK_HOT_MEMMAP_SOURCE}" CPICOSDK_HOT_MEMMAP_CONTENT)
set(CPICOSDK_HOT_TEXT_ANCHOR "*(EXCLUDE_FILE(*libgcc.a: *libc.a:*lib_a-mem*.o *libm.a:) .text*)")
set(CPICOSDK_HOT_TEXT_REPLACEMENT "*(EXCLUDE_FILE(*libgcc.a: *libc.a:*lib_a-mem*.o *libm.a: *libswift_Concurrency.a:Actor.cpp.o) .text*)")
set(CPICOSDK_LATE_TEXT_ANCHOR "    .ARM.extab :")
set(CPICOSDK_LATE_TEXT_REPLACEMENT "    .cpicosdk_late_text : {\n        *(.cpicosdk_late_text*)\n        . = ALIGN(4);\n    } > FLASH\n\n    .ARM.extab :")
# Pico SDK's default linker script keeps core0 in SCRATCH_Y. CPicoSDK keeps the
# core0 stack top there for every size, letting larger core0 stacks extend
# downward through SCRATCH_X into main RAM. Core1 uses SCRATCH_X only when core0
# does not need it, otherwise core1 sits below core0 in main RAM.
set(CPICOSDK_STACK_SYMBOLS_ANCHOR "    __StackLimit = ORIGIN(RAM) + LENGTH(RAM);\n    __StackOneTop = ORIGIN(SCRATCH_X) + LENGTH(SCRATCH_X);\n    __StackTop = ORIGIN(SCRATCH_Y) + LENGTH(SCRATCH_Y);\n    __StackOneBottom = __StackOneTop - SIZEOF(.stack1_dummy);\n    __StackBottom = __StackTop - SIZEOF(.stack_dummy);")
if(CPICOSDK_CORE0_STACK_SIZE_BYTES LESS_EQUAL 4096)
    set(CPICOSDK_STACK_TOP "ORIGIN(SCRATCH_Y) + LENGTH(SCRATCH_Y)")
    set(CPICOSDK_STACK_BOTTOM "__StackTop - ${CPICOSDK_CORE0_STACK_SIZE_BYTES}")
    set(CPICOSDK_STACK_ONE_TOP "ORIGIN(SCRATCH_X) + LENGTH(SCRATCH_X)")
    set(CPICOSDK_STACK_ONE_BOTTOM "__StackOneTop - ${CPICOSDK_CORE1_STACK_SIZE_BYTES}")
    if(CPICOSDK_CORE1_STACK_SIZE_BYTES GREATER 4096)
        set(CPICOSDK_HEAP_LIMIT "__StackOneBottom")
    else()
        set(CPICOSDK_HEAP_LIMIT "ORIGIN(RAM) + LENGTH(RAM)")
    endif()
else()
    set(CPICOSDK_STACK_TOP "ORIGIN(SCRATCH_Y) + LENGTH(SCRATCH_Y)")
    set(CPICOSDK_STACK_BOTTOM "__StackTop - ${CPICOSDK_CORE0_STACK_SIZE_BYTES}")
    if(CPICOSDK_CORE1_STACK_SIZE_BYTES GREATER 0)
        set(CPICOSDK_STACK_ONE_TOP "__StackBottom")
        set(CPICOSDK_STACK_ONE_BOTTOM "__StackOneTop - ${CPICOSDK_CORE1_STACK_SIZE_BYTES}")
        set(CPICOSDK_HEAP_LIMIT "__StackOneBottom")
    else()
        set(CPICOSDK_STACK_ONE_TOP "__StackBottom")
        set(CPICOSDK_STACK_ONE_BOTTOM "__StackOneTop")
        if(CPICOSDK_CORE0_STACK_SIZE_BYTES GREATER 8192)
            set(CPICOSDK_HEAP_LIMIT "__StackBottom")
        else()
            set(CPICOSDK_HEAP_LIMIT "ORIGIN(RAM) + LENGTH(RAM)")
        endif()
    endif()
endif()
set(CPICOSDK_STACK_SYMBOLS_REPLACEMENT "    __StackOneTop = ${CPICOSDK_STACK_ONE_TOP};\n    __StackOneBottom = ${CPICOSDK_STACK_ONE_BOTTOM};\n    __StackTop = ${CPICOSDK_STACK_TOP};\n    __StackBottom = ${CPICOSDK_STACK_BOTTOM};\n    __StackLimit = __StackBottom;\n    __HeapLimit = ${CPICOSDK_HEAP_LIMIT};")
string(FIND "${CPICOSDK_HOT_MEMMAP_CONTENT}" "${CPICOSDK_HOT_TEXT_ANCHOR}" CPICOSDK_HOT_TEXT_ANCHOR_INDEX)
if(CPICOSDK_HOT_TEXT_ANCHOR_INDEX EQUAL -1)
    message(FATAL_ERROR "CPicoSDK expected Pico SDK .text linker-script anchor not found in ${CPICOSDK_HOT_MEMMAP_SOURCE}")
endif()
string(FIND "${CPICOSDK_HOT_MEMMAP_CONTENT}" "${CPICOSDK_LATE_TEXT_ANCHOR}" CPICOSDK_LATE_TEXT_ANCHOR_INDEX)
if(CPICOSDK_LATE_TEXT_ANCHOR_INDEX EQUAL -1)
    message(FATAL_ERROR "CPicoSDK expected Pico SDK .ARM.extab linker-script anchor not found in ${CPICOSDK_HOT_MEMMAP_SOURCE}")
endif()
string(FIND "${CPICOSDK_HOT_MEMMAP_CONTENT}" "${CPICOSDK_STACK_SYMBOLS_ANCHOR}" CPICOSDK_STACK_SYMBOLS_ANCHOR_INDEX)
if(CPICOSDK_STACK_SYMBOLS_ANCHOR_INDEX EQUAL -1)
    message(FATAL_ERROR "CPicoSDK expected Pico SDK stack symbols linker-script anchor not found in ${CPICOSDK_HOT_MEMMAP_SOURCE}")
endif()
string(REPLACE
    "${CPICOSDK_HOT_TEXT_ANCHOR}"
    "${CPICOSDK_HOT_TEXT_REPLACEMENT}"
    CPICOSDK_HOT_MEMMAP_CONTENT
    "${CPICOSDK_HOT_MEMMAP_CONTENT}"
)
string(REPLACE
    "${CPICOSDK_LATE_TEXT_ANCHOR}"
    "${CPICOSDK_LATE_TEXT_REPLACEMENT}"
    CPICOSDK_HOT_MEMMAP_CONTENT
    "${CPICOSDK_HOT_MEMMAP_CONTENT}"
)
string(REPLACE
    "${CPICOSDK_STACK_SYMBOLS_ANCHOR}"
    "${CPICOSDK_STACK_SYMBOLS_REPLACEMENT}"
    CPICOSDK_HOT_MEMMAP_CONTENT
    "${CPICOSDK_HOT_MEMMAP_CONTENT}"
)
file(WRITE "${CPICOSDK_HOT_MEMMAP}" "${CPICOSDK_HOT_MEMMAP_CONTENT}")
pico_set_linker_script("${PROJECT_NAME}" "${CPICOSDK_HOT_MEMMAP}")

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
    PICO_USE_STACK_GUARDS=1
    PICO_STACK_SIZE=0u
    PICO_CORE1_STACK_SIZE=0u
    CPICOSDK_CORE1_STACK_SIZE_BYTES=${CPICOSDK_CORE1_STACK_SIZE_BYTES}
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
