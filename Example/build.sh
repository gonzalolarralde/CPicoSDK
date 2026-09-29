#!/usr/bin/env /bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Set the swift build configuration.
export BUILD_TYPE=${BUILD_TYPE:-RelWithDebInfo}

### Uncommenting the next line could help to debug issues or better understand the pipeline.
# set -x

export BUILD_SCRIPT_VERSION=1 # Helps the preparation script to warn in case of future changes.
export PREPARATION_SCRIPT_PATH="$PWD/.env_prep"

if command -v swiftly >/dev/null 2>&1; then
  export SWIFTLY_PATH="$(command -v swiftly)"
elif [ -f "$HOME/.swiftly/bin/swiftly" ]; then                 # macOS default path
  export SWIFTLY_PATH="$HOME/.swiftly/bin/swiftly"
elif [ -f "$HOME/.local/share/swiftly/bin/swiftly" ]; then     # Linux default path
  export SWIFTLY_PATH="$HOME/.local/share/swiftly/bin/swiftly"
else
  echo "swiftly not found in PATH."
  echo "Install it from https://www.swift.org/download/"
  exit 1
fi

# Host plugins use the PR's SwiftPM; firmware uses the pinned embedded compiler.
export CPICOSDK_SWIFT_EXEC=${CPICOSDK_SWIFT_EXEC:-$("$SWIFTLY_PATH" run which swiftc)}
swiftpm() { sh ../utils/swiftpm-experimental.sh "$@"; }

swiftpm package --disable-sandbox prepare-rp2xxx-environment \
    "$@" \
    --dump-prep-script "$PREPARATION_SCRIPT_PATH" \
    --disable-vscode-settings --disable-sourcekit-lsp-settings \
    --allow-writing-to-package-directory \
    --allow-network-connections all  # Used to download PicoSDK, toolchain and other dependencies.

# The preparation script is dumped to PREPARATION_SCRIPT_PATH so it can be inspected.
# Users can opt to place the output in a different location and source it here once inspected if preferred.
source "$PREPARATION_SCRIPT_PATH"

case "${1:-}" in
    --cortex-debug) export AUTO_STDIO=uart ;;
    *) export AUTO_STDIO=${AUTO_STDIO:-usb} ;;
esac

build_options=(
    --package-path Firmware --build-system swiftbuild --target Firmware
    --configuration "$SWIFT_BUILD_TYPE" --toolset "$TOOLSET_PATH"
    --triple "$SWIFTPM_TRIPLE"
)
# EXTRA_CONFIG_PARAMS is the preparation plugin's list of compiler flags.
swiftpm build "${build_options[@]}" $EXTRA_CONFIG_PARAMS
export CPICOSDK_FIRMWARE_PRODUCTS="$(swiftpm build "${build_options[@]}" --show-bin-path)"
printf 'Firmware: %s/%s.{elf,uf2}\n' "$CPICOSDK_FIRMWARE_PRODUCTS" "$SWIFTPM_PRODUCT"

# Flash the produced binary to the target device if requested.
flash_if_needed "$@"
