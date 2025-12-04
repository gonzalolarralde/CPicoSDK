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
export PICOTOOL_FETCH_FROM_GIT_PATH="$1/picotool"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Writing source h file in $SRC_DIR/CPicoSDK.source.h"

# TODO: Only include libraries enabled by Traits here.
cat <<- "EOF" > "$SRC_DIR/CPicoSDK.source.h"
#include <pico/stdlib.h>
#include <pico/status_led.h>
EOF

cmake \
  -S "$SRC_DIR" \
  -B "$BUILD_DIR" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DPICO_SDK_PATH="${PICO_SDK_PATH:-}" \
  -DPICOTOOL_EXECUTABLE="${PICOTOOL_EXECUTABLE}" \
  -DBOARD_TYPE="${BOARD}" \
  -DTOOLCHAIN_VERSION="${TOOLCHAIN_VERSION}" \
  -DSDK_VERSION="${SDK_VERSION}"

cmake --build "$BUILD_DIR"

echo "Writing modulemap to $1/output/module.modulemap"

cat <<- "EOF" > "$OUTPUT_DIR/module.modulemap"
module CPicoSDK {
    umbrella header "includes/CPicoSDK.h"
    export *
}
EOF

mkdir -p "$OUTPUT_DIR/include"
echo "#pragma GCC system_header" > "$OUTPUT_DIR/include/CPicoSDK.h"
cat "$BUILD_DIR/CPicoSDK.h" >> "$OUTPUT_DIR/include/CPicoSDK.h"

cp -rf "$OUTPUT_DIR/" "$3/Sources/_CPicoSDK"
