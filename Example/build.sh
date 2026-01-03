#!/usr/bin/env /bin/bash

set -euo pipefail

### Uncomment next line to debug issues or better understand what the scripts are doing.
# set -x

export BUILD_SCRIPT_VERSION=1 # Helps the preparation script to warn in case of future changes.
export PREPARATION_SCRIPT_PATH="$(dirname "$0")/.env_prep"
export SWIFTLY_PATH="$HOME/.swiftly/bin/swiftly"

export BUILD_TYPE="RelWithDebInfo" # Options: Debug, Release, RelWithDebInfo, MinSizeRel

"$SWIFTLY_PATH" run swift package prepare-rp2xxx-environment \
    "$@" \
    --dump-prep-script "$PREPARATION_SCRIPT_PATH" \
    --allow-writing-to-package-directory \
    --allow-network-connections all                  # Used to download PicoSDK, toolchain and other dependencies.

# The preparation script is dumped to PREPARATION_SCRIPT_PATH so it can be inspected.
# Users can opt to place the output in a different location and source it here once inspected if preferred.
source "$PREPARATION_SCRIPT_PATH"

"$SWIFTLY_PATH" run swift build -v \
    --build-system native \
    --configuration $SWIFT_BUILD_TYPE \
    --toolset $TOOLSET_PATH \
    --triple $SWIFTPM_TRIPLE

finalize_rp2xxx_binary "$@"

flash_if_needed "$@"
