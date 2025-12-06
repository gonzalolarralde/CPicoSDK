#!/usr/bin/bash
set -euxo pipefail

cat env.json.tmpl | sed "s#<HOME>#$( dirname ~/. )#g" > env.json

rm -rf .build
rm -rf Sources/_CPicoSDK
cp -rf Sources/_CPicoSDKTemplate Sources/_CPicoSDK

swift package generate-cpicosdk --allow-writing-to-package-directory

# TODO: Figure out how to build with `host` pico-platform.
# swift build \
#     --build-system native \
#     --configuration release \
#     --toolset toolset.json \
#     --triple armv7em-none-none-eabi

