#!/usr/bin/bash
set -euxo pipefail

cat env.json.tmpl | sed "s#<HOME-PATH-HERE>#$( dirname ~/. )#g" | sed "s#<PICOTOOL-VERSION>#$PICOTOOL_VERSION#g" > env.json

rm -rf .build
rm -rf Sources/_CPicoSDK
cp -rf Sources/_CPicoSDKTemplate Sources/_CPicoSDK

swift package generate-cpicosdk

# TODO: Figure out how to build with `host` pico-platform.
# swift build \
#     --build-system native \
#     --configuration release \
#     --toolset toolset.json \
#     --triple armv7em-none-none-eabi

