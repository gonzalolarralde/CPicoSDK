#!/usr/bin/env bash

if [[ -n "$VSCODE_PICO_SDK_PATH" ]]; then
    export PICO_SDK_PATH="$VSCODE_PICO_SDK_PATH/sdk/$SDK_VERSION/"
    export PICO_TOOLCHAIN_PATH="$VSCODE_PICO_SDK_PATH/toolchain/$TOOLCHAIN_VERSION/"
    export PICOTOOL_EXECUTABLE="$VSCODE_PICO_SDK_PATH/picotool/$PICOTOOL_VERSION/picotool/picotool"
else
    missing=""

    [[ -z "$PICO_SDK_PATH" ]]        && missing+=" PICO_SDK_PATH"
    [[ -z "$PICO_TOOLCHAIN_PATH" ]]  && missing+=" PICO_TOOLCHAIN_PATH"
    [[ -z "$PICOTOOL_EXECUTABLE" ]]  && missing+=" PICOTOOL_EXECUTABLE"

    if [[ -n "$missing" ]]; then
        echo "Missing required variables:$missing" >&2
        exit 1
    fi
fi

set -euxo pipefail

cp -r "$2" "$1"

SRC_DIR="$1/Test"
BUILD_DIR="${SRC_DIR}/build"
OUTPUT_DIR="$1/output"

mkdir -p "$OUTPUT_DIR"

export PATH="$CMAKE_PATH:$NINJA_PATH:$PATH"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Writing source h file in $SRC_DIR/lib_to_bundle.cmake"

cat <<- "EOF" > "$SRC_DIR/lib_to_bundle.cmake"
add_library(Output STATIC IMPORTED)
set_target_properties(Output PROPERTIES
EOF

echo    IMPORTED_LOCATION "$3" >> "$SRC_DIR/lib_to_bundle.cmake"

cat <<- "EOF" >> "$SRC_DIR/lib_to_bundle.cmake"
)

target_link_libraries("${PROJECT_NAME}"
    pico_stdlib
    pico_status_led
    Output
)
EOF

# TODO: CMake path shouldn't depend on homebrew
cmake \
  -S "$SRC_DIR" \
  -B "$BUILD_DIR" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebug \
  -DPICO_SDK_PATH="${PICO_SDK_PATH:-}" \
  -DPICOTOOL_EXECUTABLE="${PICOTOOL_EXECUTABLE}" \
  -DBOARD_TYPE="${BOARD}" \
  -DPROJECT_NAME="$4" \
  -DTOOLCHAIN_VERSION="${TOOLCHAIN_VERSION}" \
  -DSDK_VERSION="${SDK_VERSION}"

cmake --build "$BUILD_DIR"

cp "$BUILD_DIR/$4."* "$( dirname "$3" )/"
