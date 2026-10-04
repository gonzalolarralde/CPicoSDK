#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
bundle=${1:?Pass an already-installed Pico SDK bundle directory.}
bundle=$(cd -- "$bundle" && pwd)
mkdir -p "$root/.build"
fixture=$(mktemp -d "$root/.build/header-preparation.XXXXXX")
cleanup() {
    if [[ ${CPICOSDK_KEEP_FIXTURE:-0} == 1 ]]; then
        printf 'Header-generation fixture: %s\n' "$fixture"
    else
        rm -rf -- "$fixture"
    fi
}
trap cleanup EXIT

# Exercise the root script's bootstrap state without deleting the real checkout.
cp "$root/Package.swift.template" "$fixture/Package.swift"
cp "$root/Package.swift.template" "$root/env.json" "$fixture/"
cp -R "$root/Plugins" "$root/Vendor" "$root/Tests" "$fixture/"
mkdir "$fixture/Sources"
for source in "$root"/Sources/*; do
    case $(basename -- "$source") in _CPicoSDK_*) continue ;; esac
    cp -R "$source" "$fixture/Sources/"
done
cd -- "$fixture"
export PICO_SDK_BUNDLE_PATH="$bundle"
export BUILD_TYPE=RelWithDebInfo
# This path must never be invoked by header preparation with version/toolset sync disabled.
export SWIFTLY_PATH="$fixture/not-installed-swiftly"
sh "$root/utils/swiftpm-experimental.sh" package --disable-sandbox prepare-rp2xxx-environment \
    --disable-install-dependencies --disable-vscode-settings --disable-sourcekit-lsp-settings \
    --disable-toolset --disable-swift-version --dont-force-product-name \
    --cpicosdk-envs-path "$fixture/env.json" --dump-prep-script "$fixture/.env_prep" \
    --allow-writing-to-package-directory --allow-network-connections all > prepare.log 2>&1 \
    || { tail -n 60 prepare.log; exit 1; }
source .env_prep
[[ -z "$SWIFTPM_PRODUCT" ]]
[[ "$CPICOSDK_pico_SWIFTPM_TRIPLE" == armv6m-none-none-eabi ]]
[[ "$CPICOSDK_pico_w_ARCH_PREPROCESSOR_DEFINE" == __ARM_ARCH_6M__ ]]
[[ "$CPICOSDK_pico2_BOARD" == pico2 ]]
[[ "$CPICOSDK_pimoroni_pico_plus2_w_rp2350_IMPORTED_LIBS_MORE" == *pico_cyw43_arch* ]]
[[ ! -e toolset.json && ! -e .swift-version && ! -e .cpicosdk-installation.json ]]

sh "$root/utils/swiftpm-experimental.sh" package --disable-sandbox generate-cpicosdk \
    --allow-writing-to-package-directory > generate.log 2>&1 \
    || { tail -n 60 generate.log; exit 1; }
for board in pico pico_w pico2 pico2_w pimoroni_pico_plus2_rp2350 pimoroni_pico_plus2_w_rp2350; do
    [[ -s "Sources/_CPicoSDK_$board/include/CPicoSDK_$board.h" ]]
    [[ -s "Sources/_CPicoSDK_$board/module.modulemap" ]]
    grep -Fq ".target(name: \"_CPicoSDK_$board\")" Package.swift
done
grep -Fq 'name: "PicoBuildConfigurationCore"' Package.swift
sh "$root/utils/swiftpm-experimental.sh" package dump-package > package.json
printf 'Root preparation and all six header-generation checks passed.\n'
