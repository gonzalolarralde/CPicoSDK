#!/usr/bin/env /bin/bash

### Uncomment next line to debug issues or better understand what the scripts are doing.
# set -x

export BUILD_SCRIPT_VERSION=1 # Helps the preparation script to wran against future changes.
export VERBOSE_ENV_SETUP=1 # Print steps and debug info.
export SWIFTLY_PATH="$HOME/.swiftly/bin/swiftly"

export BUILD_TYPE="RelWithDebInfo" # Options: Debug, Release, RelWithDebInfo, MinSizeRel

PREPARATION_CODE="$( "$SWIFTLY_PATH" run swift package prepare-rp2xxx-environment \
    "$*" \
    --allow-writing-to-package-directory )"

if [ $? -ne 0 ]; then
    echo "Error when setting up environment preparation."
    echo "$PREPARATION_CODE"
    exit 5
fi

set -euo pipefail

# To have more control over the preparation code you can opt to dump it to a file, inspect it, and source it instead.
# It's not expected to change run to run, only when the lib is upgraded. Can be manually managed if preferred.

# echo "$PREPARATION_CODE" > prep_code.sh
# source prep_code.sh

eval "$PREPARATION_CODE"

"$SWIFTLY_PATH" run swift build -v \
    --build-system native \
    --configuration $SWIFT_BUILD_TYPE \
    --toolset $TOOLSET_PATH \
    --triple $SWIFTPM_TRIPLE

finalize_rp2xxx_binary "$1"

flash_if_needed "$1" "${2:-}"
