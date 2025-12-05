#!/usr/bin/env bash
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
  -DSDK_VERSION="${SDK_VERSION}" \
  -DIMPORTED_LIBS="${IMPORTED_LIBS}" \
  -DIMPORTED_LOCATION="$3"

cmake --build "$BUILD_DIR"

cp "$BUILD_DIR/$4."* "$( dirname "$3" )/"
