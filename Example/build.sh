#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

## User customization

export BUILD_TYPE="${BUILD_TYPE:-RelWithDebInfo}"
export CPICOSDK_BUILD_CONFIGURATION="${CPICOSDK_BUILD_CONFIGURATION:-$SCRIPT_DIR/cpicosdk-build.json}"
SWIFTPM_BIN_DIR="${SWIFTPM_BIN_DIR:-}"
SWIFTPM_SCRATCH_PATH="${SWIFTPM_SCRATCH_PATH:-$SCRIPT_DIR/.build}"
if [[ "$SWIFTPM_SCRATCH_PATH" != /* ]]; then
    SWIFTPM_SCRATCH_PATH="$SCRIPT_DIR/$SWIFTPM_SCRATCH_PATH"
fi

FLASH_REQUESTED=0
for argument in "$@"; do
    if [[ "$argument" == "--flash" ]]; then
        FLASH_REQUESTED=1
    fi
done

if [[ -z "$SWIFTPM_BIN_DIR" ]]; then
    echo "Set SWIFTPM_BIN_DIR to the Products directory containing the patched swift-package and swift-build executables." >&2
    exit 1
fi
SWIFT_PACKAGE="$SWIFTPM_BIN_DIR/swift-package"
SWIFT_BUILD="$SWIFTPM_BIN_DIR/swift-build"
if [[ ! -x "$SWIFT_PACKAGE" || ! -x "$SWIFT_BUILD" ]]; then
    echo "SWIFTPM_BIN_DIR must contain executable swift-package and swift-build products." >&2
    exit 1
fi

if command -v swiftly >/dev/null 2>&1; then
    export SWIFTLY_PATH="$(command -v swiftly)"
elif [[ -x "$HOME/.swiftly/bin/swiftly" ]]; then
    export SWIFTLY_PATH="$HOME/.swiftly/bin/swiftly"
elif [[ -x "$HOME/.local/share/swiftly/bin/swiftly" ]]; then
    export SWIFTLY_PATH="$HOME/.local/share/swiftly/bin/swiftly"
else
    echo "swiftly not found. Install it from https://www.swift.org/download/." >&2
    exit 1
fi

# The development SwiftPM products use the compiler selected by .swift-version.
export SWIFT_EXEC="${SWIFT_EXEC:-$(cd "$SCRIPT_DIR" && "$SWIFTLY_PATH" run which swiftc)}"
export SWIFT_EXEC_MANIFEST="${SWIFT_EXEC_MANIFEST:-$SWIFT_EXEC}"
export PREPARATION_SCRIPT_PATH="${PREPARATION_SCRIPT_PATH:-$SCRIPT_DIR/.env_prep}"

## Prepare the destination before SwiftPM plans the firmware build.

"$SWIFT_PACKAGE" \
    --disable-sandbox \
    --package-path "$SCRIPT_DIR" \
    prepare-rp2xxx-environment \
    "$@" \
    --dump-prep-script "$PREPARATION_SCRIPT_PATH" \
    --allow-writing-to-package-directory \
    --allow-network-connections all

source "$PREPARATION_SCRIPT_PATH"

# Use the exact compiler whose Embedded Swift runtime was staged above.
export SWIFT_EXEC="$CPICOSDK_SWIFT_EXECUTABLE"
export SWIFT_EXEC_MANIFEST="$SWIFT_EXEC"

## Build Swift, native support, and the final firmware artifacts.

"$SWIFT_BUILD" \
    --disable-sandbox \
    --package-path "$SCRIPT_DIR" \
    --scratch-path "$SWIFTPM_SCRATCH_PATH" \
    --configuration "$SWIFT_BUILD_TYPE" \
    --swift-sdks-path "$CPICOSDK_SWIFT_SDKS_PATH" \
    --swift-sdk "$CPICOSDK_SWIFT_SDK_ID" \
    --product "$SWIFTPM_PRODUCT"

## Finalization is the product's declared post-build task; no extra call is needed.

## Flash the finalized UF2 only when requested.

if [[ "$FLASH_REQUESTED" == "1" ]]; then
    "$SWIFT_PACKAGE" \
        --disable-sandbox \
        --package-path "$SCRIPT_DIR" \
        flash-rp2xxx-binary "$SWIFTPM_PRODUCT" \
        --configuration "$SWIFT_BUILD_TYPE" \
        --firmware-scratch-path "$SWIFTPM_SCRATCH_PATH"
fi
