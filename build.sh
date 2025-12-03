#!/usr/bin/bash

set -euxo pipefail

rm -rf .build
rm -rf Sources/_CPicoSDK
cp -rf Sources/_CPicoSDKTemplate Sources/_CPicoSDK

swift package generate-cpicosdk

# TODO: Figure out how to build with `host` pico-platform.
# swift build \
#     --build-system native \
#     --configuration release \
#     --triple armv7em-apple-none-macho \
#     --toolset toolset.json \
#     --triple armv7em-none-none-eabi

