#!/usr/bin/env bash
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

# // TODO: Only include libraries enabled by Traits here.
{
    echo "#define __ARM_ARCH_8M_MAIN__ 1"
    
    if echo "$IMPORTED_LIBS" | grep "pico_lwip_http" > /dev/null 2> /dev/null; then
        echo "#include <lwip/apps/http_client.h>"
        echo "#include <lwip/altcp.h>"
        echo "#include <lwip/altcp_tls.h>"
        echo "#include <lwip/netif.h>"
        echo "#include <lwip/ip4_addr.h>"
    fi
    
    for lib in ${IMPORTED_LIBS//,/ }; do
        LIB_BASE="$( find "${PICO_SDK_PATH}/src/" -type d -name "$lib" | grep -v "/host/" | head -1 || echo "not-found" )/include"

        echo
        echo "// MARK: - ${lib} headers"

        if [ -d "$LIB_BASE" ]; then
            while IFS= read -r hdr; do
                fname=${hdr##$LIB_BASE/}     # strip directory → file name only
                echo "#include <$fname>"
            done < <(find "$LIB_BASE" -type f -name '*.h')
        else
            echo "// No headers found -- \$ find \"$LIB_BASE\" -type f -name '*.h')"
        fi
    done
} > "$SRC_DIR/CPicoSDK.source.h"
cat "$SRC_DIR/CPicoSDK.source.h"

cmake \
  -S "$SRC_DIR" \
  -B "$BUILD_DIR" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  -DPICO_SDK_PATH="${PICO_SDK_PATH:-}" \
  -DPICOTOOL_EXECUTABLE="${PICOTOOL_EXECUTABLE}" \
  -DBOARD_TYPE="${BOARD}" \
  -DTOOLCHAIN_VERSION="${TOOLCHAIN_VERSION}" \
  -DSDK_VERSION="${SDK_VERSION}" \
  -DIMPORTED_LIBS="${IMPORTED_LIBS}"

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
