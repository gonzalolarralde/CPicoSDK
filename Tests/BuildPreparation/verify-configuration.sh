#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
compiler=${SWIFTC:-$(command -v swiftc)}
scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT
source_file="$root/Sources/CPicoSDKConfiguration/Configuration.swift"

check_board() {
    local board=$1 platform=$2 variant=$3 radio=$4
    "$compiler" -parse-as-library -emit-object "$source_file" \
        -D "$platform" -D "$variant" -D "$radio" \
        -D StdIO_UART -D StdIO_USB -D StdIO_RTT -o "$scratch/metadata.o"
    nm "$scratch/metadata.o" > "$scratch/symbols"
    for marker in "combination_$board" trait_stdio_uart trait_stdio_usb trait_stdio_rtt; do
        grep -Eq "_cpicosdk_${marker}$" "$scratch/symbols"
    done
    [[ $(grep -Ec '_cpicosdk_combination_[[:alnum:]_]+$' "$scratch/symbols") == 1 ]]
}

check_board pico Platform_RP2040 Variant_RP2040 Radio_None
check_board pico_w Platform_RP2040 Variant_RP2040 Radio_CYW43439
check_board pico2 Platform_RP2350 Variant_RP2350A Radio_None
check_board pico2_w Platform_RP2350_arm_s Variant_RP2350A Radio_CYW43439
check_board pimoroni_pico_plus2_rp2350 Platform_RP2350 Variant_RP2350B Radio_None
check_board pimoroni_pico_plus2_w_rp2350 Platform_RP2350_arm_s Variant_RP2350B Radio_CYW43439

"$compiler" -parse-as-library -emit-object "$source_file" \
    -D Platform_RP2350 -D Variant_RP2350A -D Radio_None \
    -D StdIO_Automatic -o "$scratch/metadata.o"
nm "$scratch/metadata.o" | grep -Eq '_cpicosdk_trait_stdio_automatic$'

expect_error() {
    local diagnostic=$1
    shift
    if "$compiler" -typecheck "$source_file" "$@" > "$scratch/diagnostics" 2>&1; then
        echo "Unexpectedly accepted invalid configuration: $*" >&2
        exit 1
    fi
    grep -Fq "$diagnostic" "$scratch/diagnostics"
}

expect_error 'At least one Platform needs to be selected.'
expect_error 'Only one Platform can be selected at a time.' \
    -D Platform_RP2040 -D Platform_RP2350 -D Variant_RP2040 -D Radio_None
expect_error 'Platform_RP2040 requires Variant_RP2040.' \
    -D Platform_RP2040 -D Variant_RP2350A -D Radio_None
expect_error 'Only one Variant can be selected at a time.' \
    -D Platform_RP2350 -D Variant_RP2350A -D Variant_RP2350B -D Radio_None
expect_error 'Invalid Variant + Radio combination.' \
    -D Platform_RP2350 -D Variant_RP2350A
expect_error 'StdIO_Automatic mode is selected' \
    -D Platform_RP2350 -D Variant_RP2350A -D Radio_None -D StdIO_Automatic -D StdIO_USB

printf 'Configuration metadata regression checks passed.\n'
