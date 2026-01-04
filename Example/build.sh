#!/usr/bin/env /bin/bash
set -euo pipefail

# Set the swift build configuration.
export BUILD_TYPE="RelWithDebInfo" # Options: Debug, Release, RelWithDebInfo, MinSizeRel

### Uncommenting the next line could help to debug issues or better understand the pipeline.
# set -x

export BUILD_SCRIPT_VERSION=1 # Helps the preparation script to warn in case of future changes.
export PREPARATION_SCRIPT_PATH="$(dirname "$0")/.env_prep"

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

# This command will prepare the environment and create a swiftpm and a vscode basic configuration.
# On doing so, it might opt to overwrite some of the existing files. If you are customizing your
# environment, please inspect the preparation script dumped at PREPARATION_SCRIPT_PATH and source it
# manually after inspection. You can also use the following flags to disable parts of the preparation:
    #--disable-vscode-settings \
    #--disable-sourcekit-lsp-settings \
    #--disable-toolset \
    #--disable-swift-version \
    #--disable-install-dependencies \
"$SWIFTLY_PATH" run swift package prepare-rp2xxx-environment \
    "$@" \
    --dump-prep-script "$PREPARATION_SCRIPT_PATH" \
    --allow-writing-to-package-directory \
    --allow-network-connections all  # Used to download PicoSDK, toolchain and other dependencies.

# The preparation script is dumped to PREPARATION_SCRIPT_PATH so it can be inspected.
# Users can opt to place the output in a different location and source it here once inspected if preferred.
source "$PREPARATION_SCRIPT_PATH"

# Make sure the selected swift toolchain is installed.
"$SWIFTLY_PATH" install

# Builds the library using swiftpm. This is where the application code is compiled.
"$SWIFTLY_PATH" run swift build -v \
    --build-system native \
    --configuration $SWIFT_BUILD_TYPE \
    --toolset $TOOLSET_PATH \
    --triple $SWIFTPM_TRIPLE \
    $EXTRA_CONFIG_PARAMS            # This allows passing extra parameters from the command line.
                                    # Used for adding debugging flags based on the cmake configuration.

# Here the application code is linked with the PicoSDK and other imported libraries to produce
# the final binary that can be flashed to the target device. An UF2 and ELF file are produced.
finalize_rp2xxx_binary "$@"

# Flash the produced binary to the target device if requested.
flash_if_needed "$@"
