#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
export GENERATED_PREP_SCRIPT=${1:-"$root/Example/.env_prep"}
if [[ ! -f "$GENERATED_PREP_SCRIPT" ]]; then
    echo "Run Example/build.sh first, or pass a generated preparation script." >&2
    exit 1
fi
GENERATED_PREP_SCRIPT=$(cd -- "$(dirname -- "$GENERATED_PREP_SCRIPT")" && pwd)/$(basename -- "$GENERATED_PREP_SCRIPT")
scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT

# Exercise the real launcher and generated helpers without installing or flashing.
swiftly() {
    case "$*" in
        install)
            [[ "$(< .swift-version)" == prepared-version ]] || return 1
            printf 'install\n' >> events
            ;;
        'run which swiftc')
            [[ "$(tail -n 1 events)" == install ]] || return 1
            printf 'compiler\n' >> events
            printf '%s\n' "$TEST_COMPILER"
            ;;
        *) echo "Unexpected swiftly invocation: $*" >&2; return 1 ;;
    esac
}

sh() {
    [[ "$1" == ../utils/swiftpm-experimental.sh ]] || return 1
    shift
    case "$*" in
        'package --disable-sandbox prepare-rp2xxx-environment '*)
            printf 'prepare\n' >> events
            printf 'prepared-version\n' > .swift-version
            printf '%s\n' \
                'source "$GENERATED_PREP_SCRIPT"' \
                'export SWIFTLY_PATH=swiftly' \
                'export PLUGIN_OUTPUT_PATH="$TEST_OUTPUT"' \
                > "$PREPARATION_SCRIPT_PATH"
            ;;
        'build '*)
            [[ "$CPICOSDK_SWIFT_EXEC" == "$TEST_COMPILER" ]] || return 1
            [[ "$AUTO_STDIO" == "$TEST_STDIO" ]] || return 1
            [[ "$(readlink "$TEST_OUTPUT/generated/swift-toolchain")" == "$(dirname -- "$(dirname -- "$TEST_COMPILER")")" ]] || return 1
            printf 'build\n' >> events
            ;;
        'package memory-map-report '*) printf 'report\n' >> events ;;
        *) echo "Unexpected SwiftPM invocation: $*" >&2; return 1 ;;
    esac
}
export -f swiftly sh

export TEST_COMPILER="$scratch/selected toolchain/usr/bin/swiftc"
mkdir -p "$(dirname -- "$TEST_COMPILER")"
cp /usr/bin/true "$TEST_COMPILER"
for mode in usb uart; do
    workspace="$scratch/$mode"
    mkdir -p "$workspace"
    cp "$root/Example/build.sh" "$workspace/build.sh"
    export TEST_OUTPUT="$workspace/plugin output"
    export TEST_STDIO=$mode
    (
        cd -- "$workspace"
        unset CPICOSDK_SWIFT_EXEC
        printf 'old-version\n' > .swift-version
        if [[ "$mode" == uart ]]; then
            bash ./build.sh --cortex-debug > build.log 2>&1 || { cat build.log; exit 1; }
        else
            bash ./build.sh > build.log 2>&1 || { cat build.log; exit 1; }
        fi
        [[ "$(< events)" == $'prepare\ninstall\ncompiler\nbuild\nreport' ]]
    )
done

(
    source "$GENERATED_PREP_SCRIPT"
    export PLUGIN_OUTPUT_PATH="$scratch/explicit compiler"
    export CPICOSDK_SWIFT_EXEC="$TEST_COMPILER"
    # Still install the pinned toolchain, but do not replace an explicit compiler.
    installation_count=0
    install_only_swiftly() {
        [[ "$*" == install ]] || return 1
        installation_count=$((installation_count + 1))
    }
    export SWIFTLY_PATH=install_only_swiftly
    configure_rp2xxx_build --cortex-debug
    [[ "$installation_count" == 1 ]]
    [[ "$AUTO_STDIO" == uart ]]
    [[ "$(readlink "$PLUGIN_OUTPUT_PATH/generated/swift-toolchain")" == "$(dirname -- "$(dirname -- "$TEST_COMPILER")")" ]]
    configure_rp2xxx_stdio --picotool
    [[ "$AUTO_STDIO" == usb ]]
    configure_rp2xxx_stdio --flash
    [[ "$AUTO_STDIO" == usb ]]
    export CPICOSDK_SWIFT_EXEC="$scratch/missing/swiftc"
    if configure_rp2xxx_build > /dev/null 2>&1; then
        echo "Accepted a missing compiler" >&2
        exit 1
    fi
    export CPICOSDK_SWIFT_EXEC="$TEST_COMPILER"
    export SWIFTLY_PATH=/usr/bin/false
    export AUTO_STDIO=unchanged
    if configure_rp2xxx_build --cortex-debug; then
        echo "Continued after installation failed" >&2
        exit 1
    fi
    [[ "$AUTO_STDIO" == unchanged ]]
)

printf 'Build preparation regression checks passed.\n'
