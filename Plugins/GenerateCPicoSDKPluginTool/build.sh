#!/usr/bin/env bash

if [[ -n "$VSCODE_PICO_SDK_PATH" ]]; then
    export PICO_SDK_PATH="$VSCODE_PICO_SDK_PATH/sdk/2.2.0/"
    export PICO_TOOLCHAIN_PATH="$VSCODE_PICO_SDK_PATH/toolchain/14_2_Rel1/"
    export PICOTOOL_EXECUTABLE="$VSCODE_PICO_SDK_PATH/picotool/2.2.0/picotool/picotool"
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

# TODO: Figure out a better way to do this, need to find ninja somehow.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin:$PATH"
export PICOTOOL_FETCH_FROM_GIT_PATH="$1/picotool"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "Writing source h file in $SRC_DIR/CPicoSDK.source.h"

# TODO: Only include libraries enabled by Traits here.
cat <<- "EOF" > "$SRC_DIR/CPicoSDK.source.h"
#include <pico/stdlib.h>
#include <pico/status_led.h>
EOF

/opt/homebrew/bin/cmake \
  -S "$SRC_DIR" \
  -B "$BUILD_DIR" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DPICO_SDK_PATH="${PICO_SDK_PATH:-}" \
  -DPICOTOOL_EXECUTABLE="${PICOTOOL_EXECUTABLE}" \
  -DBOARD_TYPE="pico2_w"


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
