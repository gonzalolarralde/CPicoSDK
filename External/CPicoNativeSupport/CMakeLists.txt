cmake_minimum_required(VERSION 3.13)

add_executable(picotool IMPORTED GLOBAL)
set_target_properties(picotool PROPERTIES IMPORTED_LOCATION "${PICOTOOL_PATH}")

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
# One SwiftBuild output directory can be reused by boards sharing a destination
# triple. Force the current selection so CMake cannot retain a previous board.
set(PICO_BOARD "${BOARD_TYPE}" CACHE STRING "Board type" FORCE)
set(SKIP_PICO_MALLOC 1)

include("${CPICOSDK_ROOT}/Support/FirmwareFinalizer/CMakeHarness/pico_sdk_import.cmake")

project(CPicoNativeSupport C CXX ASM)
pico_sdk_init()

# Product identity belongs to the final executable, not this reusable archive.
set_property(TARGET pico_standard_binary_info PROPERTY INTERFACE_SOURCES "")

add_library(CPicoNativeSupport STATIC
    "${CPICOSDK_ROOT}/Support/FirmwareFinalizer/CMakeHarness/runtime_coprocessors.c"
)

pico_enable_stdio_uart(CPicoNativeSupport ${STDIO_UART})
pico_enable_stdio_usb(CPicoNativeSupport ${STDIO_USB})
pico_enable_stdio_rtt(CPicoNativeSupport ${STDIO_RTT})

target_compile_definitions(CPicoNativeSupport PRIVATE
    PICO_STDIO_USB_ENABLE_RESET_VIA_VENDOR_INTERFACE=1
    PICO_STDIO_USB_ENABLE_RESET_VIA_BAUD_RATE=1
    PICO_ENTER_USB_BOOT_ON_EXIT=1
    PICO_USE_STACK_GUARDS=1
    PICO_STACK_SIZE=0u
    PICO_CORE1_STACK_SIZE=0u
    CPICOSDK_CORE1_STACK_SIZE_BYTES=${CPICOSDK_CORE1_STACK_SIZE_BYTES}
)
target_compile_options(CPicoNativeSupport PRIVATE
    -ffunction-sections
    -fdata-sections
)
target_include_directories(CPicoNativeSupport PRIVATE
    "${CPICOSDK_ROOT}/Support/FirmwareFinalizer/CMakeHarness"
)

string(REPLACE "," ";" IMPORTED_LIBS_LIST "${IMPORTED_LIBS}")
string(REPLACE "," ";" IMPORTED_LIBS_MORE_LIST "${IMPORTED_LIBS_MORE}")
list(APPEND IMPORTED_LIBS_LIST ${IMPORTED_LIBS_MORE_LIST})
# The generated list includes every concrete stdio transport. Remove those
# direct edges so pico_stdio's target properties select exactly the requested
# transport instead of compiling UART, USB, and RTT unconditionally.
list(REMOVE_ITEM IMPORTED_LIBS_LIST
    pico_stdio_rtt
    pico_stdio_uart
    pico_stdio_usb
)
target_link_libraries(CPicoNativeSupport PRIVATE
    ${IMPORTED_LIBS_LIST}
    pico_async_context_poll
)
