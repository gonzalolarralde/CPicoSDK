#!/usr/bin/env bash
set -euo pipefail

# Exercise swift-package-manager#10198 using a prepared Swift SDK destination.
# The established build.sh remains the released-toolchain build path.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREVIEW_BUILD="${SWIFTPM_PREVIEW_BUILD:-}"
PREVIEW_SCRATCH_PATH="${SWIFTPM_PREVIEW_SCRATCH_PATH:-$SCRIPT_DIR/.build/swiftpm-external-preview}"
TOOLCHAIN_PIN_FILE="$SCRIPT_DIR/ExternalPreviewSDK/swift-toolchain.txt"
if [[ ! -s "$TOOLCHAIN_PIN_FILE" ]]; then
    echo "Missing preview toolchain pin: $TOOLCHAIN_PIN_FILE" >&2
    exit 1
fi
PREVIEW_TOOLCHAIN="${SWIFTPM_PREVIEW_TOOLCHAIN:-$(<"$TOOLCHAIN_PIN_FILE")}"
SWIFT_SDK_ID="cpicosdk-rp2350"
SWIFT_SDKS_PATH="${CPICOSDK_SWIFT_SDKS_PATH:-$SCRIPT_DIR/.build/swift-sdk-staging}"

if [[ -z "$PREVIEW_BUILD" || ! -x "$PREVIEW_BUILD" ]]; then
    echo "SWIFTPM_PREVIEW_BUILD must name swift-build built from the patched swift-package-manager#10198 checkout." >&2
    exit 1
fi
if command -v realpath >/dev/null 2>&1; then
    PREVIEW_BUILD="$(realpath "$PREVIEW_BUILD")"
else
    PREVIEW_BUILD="$(cd "$(dirname "$PREVIEW_BUILD")" && pwd -P)/$(basename "$PREVIEW_BUILD")"
fi

find_swiftly() {
    if command -v swiftly >/dev/null 2>&1; then
        command -v swiftly
    elif [[ -x "$HOME/.swiftly/bin/swiftly" ]]; then
        echo "$HOME/.swiftly/bin/swiftly"
    elif [[ -x "$HOME/.local/share/swiftly/bin/swiftly" ]]; then
        echo "$HOME/.local/share/swiftly/bin/swiftly"
    fi
}

SWIFTLY_PATH="$(find_swiftly || true)"
if [[ -z "$SWIFTLY_PATH" ]]; then
    echo "swiftly is required to select the preview compiler." >&2
    exit 1
fi
PREVIEW_SWIFT="$($SWIFTLY_PATH run which swift "+$PREVIEW_TOOLCHAIN")"
PREVIEW_TOOLCHAIN_ROOT="$(cd "$(dirname "$PREVIEW_SWIFT")/../.." && pwd)"

if ! "$PREVIEW_SWIFT" sdk list --swift-sdks-path "$SWIFT_SDKS_PATH" \
    | grep -Fxq "$SWIFT_SDK_ID"
then
    echo "Swift SDK '$SWIFT_SDK_ID' is not staged under $SWIFT_SDKS_PATH." >&2
    echo "Run: SWIFTPM_PREVIEW_TOOLCHAIN=$PREVIEW_TOOLCHAIN ./setup-external-preview-sdk.sh --stage-only" >&2
    exit 1
fi
STAGED_COMPILER_VERSION_FILE="$SWIFT_SDKS_PATH/cpicosdk-rp2xxx.artifactbundle/swift-compiler-version.txt"
if [[ ! -f "$STAGED_COMPILER_VERSION_FILE" ]]; then
    echo "The staged CPicoSDK Swift SDK does not record its compiler version." >&2
    echo "Re-run ./setup-external-preview-sdk.sh --stage-only." >&2
    exit 1
fi
if [[ "$(<"$STAGED_COMPILER_VERSION_FILE")" != "$($PREVIEW_SWIFT --version)" ]]; then
    echo "The staged Embedded Swift runtime does not match $PREVIEW_TOOLCHAIN." >&2
    echo "Re-run: SWIFTPM_PREVIEW_TOOLCHAIN=$PREVIEW_TOOLCHAIN ./setup-external-preview-sdk.sh --stage-only" >&2
    exit 1
fi

case "${1:-}" in
    --cortex-debug)
        export AUTO_STDIO=uart
        export CPICO_EXTERNAL_STDIO_UART=1
        export CPICO_EXTERNAL_STDIO_USB=0
        export CPICO_EXTERNAL_STDIO_RTT=0
        ;;
    ""|--flash)
        export AUTO_STDIO=usb
        export CPICO_EXTERNAL_STDIO_UART=0
        export CPICO_EXTERNAL_STDIO_USB=1
        export CPICO_EXTERNAL_STDIO_RTT=0
        ;;
    *)
        echo "Usage: ./build-external-preview.sh [--cortex-debug|--flash]" >&2
        exit 2
        ;;
esac

# This manifest's traits, native configuration, and Swift SDK all describe the
# Pico 2. Keep the experiment internally consistent instead of accepting an
# ambient board override that SwiftPM cannot apply to manifest traits.
export CPICOSDK_COMBINATION=pico2
export SWIFT_EXEC="$PREVIEW_TOOLCHAIN_ROOT/usr/bin/swiftc"
export SWIFT_EXEC_MANIFEST="$SWIFT_EXEC"

mkdir -p "$PREVIEW_SCRATCH_PATH" "$PREVIEW_SCRATCH_PATH/caches"
export CLANG_MODULE_CACHE_PATH="$PREVIEW_SCRATCH_PATH/caches/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PREVIEW_SCRATCH_PATH/caches/swift"
export SWIFTPM_TESTS_MODULECACHE="$PREVIEW_SCRATCH_PATH/caches/tests"
export SWIFTPM_TESTS_PACKAGECACHE="$PREVIEW_SCRATCH_PATH/caches/packages"

# A development swift-build does not have an installed ManifestAPI/PluginAPI
# layout. Stage the matching libraries beside a unique temporary directory so
# stale libraries from another PR build can never be mixed in.
PREVIEW_PRODUCTS_DIRECTORY="$(dirname "$PREVIEW_BUILD")"
PREVIEW_LIBS_DIRECTORY=""
cleanup_preview_libs() {
    if [[ -n "$PREVIEW_LIBS_DIRECTORY" ]]; then
        case "$PREVIEW_LIBS_DIRECTORY" in
            "$PREVIEW_SCRATCH_PATH"/.swiftpm-custom-libs.*)
                rm -rf -- "$PREVIEW_LIBS_DIRECTORY"
                ;;
        esac
    fi
}
trap cleanup_preview_libs EXIT
if [[ -n "${SWIFTPM_PREVIEW_LIBS_DIR:-}" ]]; then
    export SWIFTPM_CUSTOM_LIBS_DIR="$SWIFTPM_PREVIEW_LIBS_DIR"
else
    PREVIEW_LIBS_DIRECTORY="$(mktemp -d "$PREVIEW_SCRATCH_PATH/.swiftpm-custom-libs.XXXXXX")"
    PREVIEW_MANIFEST_LIBS="$PREVIEW_LIBS_DIRECTORY/ManifestAPI"
    PREVIEW_PLUGIN_LIBS="$PREVIEW_LIBS_DIRECTORY/PluginAPI"
    mkdir -p \
        "$PREVIEW_MANIFEST_LIBS/PackageDescription.swiftmodule" \
        "$PREVIEW_MANIFEST_LIBS/CompilerPluginSupport.swiftmodule" \
        "$PREVIEW_PLUGIN_LIBS/PackagePlugin.swiftmodule"

    case "$(uname -s)" in
        Darwin) LIBRARY_EXTENSION=dylib ;;
        Linux) LIBRARY_EXTENSION=so ;;
        *)
            echo "Unsupported host platform: $(uname -s)" >&2
            exit 1
            ;;
    esac
    PACKAGE_DESCRIPTION_LIBRARY="$PREVIEW_PRODUCTS_DIRECTORY/libPackageDescription.$LIBRARY_EXTENSION"
    PACKAGE_PLUGIN_LIBRARY="$PREVIEW_PRODUCTS_DIRECTORY/libPackagePlugin.$LIBRARY_EXTENSION"
    if [[ ! -f "$PACKAGE_DESCRIPTION_LIBRARY" || ! -f "$PACKAGE_PLUGIN_LIBRARY" || \
          ! -d "$PREVIEW_PRODUCTS_DIRECTORY/PackageDescription.swiftmodule" || \
          ! -d "$PREVIEW_PRODUCTS_DIRECTORY/CompilerPluginSupport.swiftmodule" || \
          ! -d "$PREVIEW_PRODUCTS_DIRECTORY/PackagePlugin.swiftmodule" ]]; then
        echo "The preview Products directory lacks matching manifest/plugin API artifacts." >&2
        echo "Set SWIFTPM_PREVIEW_LIBS_DIR for a nonstandard build layout." >&2
        exit 1
    fi

    cp "$PACKAGE_DESCRIPTION_LIBRARY" "$PREVIEW_MANIFEST_LIBS/"
    cp "$PACKAGE_PLUGIN_LIBRARY" "$PREVIEW_PLUGIN_LIBS/"
    cp -R "$PREVIEW_PRODUCTS_DIRECTORY/PackageDescription.swiftmodule/." \
        "$PREVIEW_MANIFEST_LIBS/PackageDescription.swiftmodule/"
    cp -R "$PREVIEW_PRODUCTS_DIRECTORY/CompilerPluginSupport.swiftmodule/." \
        "$PREVIEW_MANIFEST_LIBS/CompilerPluginSupport.swiftmodule/"
    cp -R "$PREVIEW_PRODUCTS_DIRECTORY/PackagePlugin.swiftmodule/." \
        "$PREVIEW_PLUGIN_LIBS/PackagePlugin.swiftmodule/"
    export SWIFTPM_CUSTOM_LIBS_DIR="$PREVIEW_LIBS_DIRECTORY"
fi

# The prototype uses a Package.resolved encoding that differs from released
# SwiftPM. Serialize preview access and keep the released lockfile recoverable
# even if a previous preview process was interrupted.
STATE_DIRECTORY="$SCRIPT_DIR/.build/swiftpm-external-preview-state"
LOCK_DIRECTORY="$STATE_DIRECTORY/lock"
mkdir -p "$STATE_DIRECTORY"
if ! mkdir "$LOCK_DIRECTORY" 2>/dev/null; then
    LOCK_PID=""
    if [[ -f "$LOCK_DIRECTORY/pid" ]]; then
        LOCK_PID="$(<"$LOCK_DIRECTORY/pid")"
    fi
    if [[ "$LOCK_PID" =~ ^[0-9]+$ ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Another external-preview build is active (pid $LOCK_PID)." >&2
        exit 1
    fi
    rm -f "$LOCK_DIRECTORY/pid"
    if ! rmdir "$LOCK_DIRECTORY" 2>/dev/null || ! mkdir "$LOCK_DIRECTORY"; then
        echo "Unable to recover stale preview lock at $LOCK_DIRECTORY." >&2
        exit 1
    fi
fi
echo "$$" > "$LOCK_DIRECTORY/pid"

STABLE_RESOLVED="$STATE_DIRECTORY/Package.resolved.stable"
RESOLVED_STATE="$STATE_DIRECTORY/Package.resolved.transaction"
PREVIEW_RESOLVED="$STATE_DIRECTORY/Package.resolved.preview-last"

restore_resolved_file() {
    if [[ ! -f "$RESOLVED_STATE" ]]; then
        return
    fi
    local original_state
    original_state="$(<"$RESOLVED_STATE")"
    if [[ -f "$SCRIPT_DIR/Package.resolved" ]]; then
        mv -f "$SCRIPT_DIR/Package.resolved" "$PREVIEW_RESOLVED"
    fi
    if [[ "$original_state" == present && -f "$STABLE_RESOLVED" ]]; then
        mv "$STABLE_RESOLVED" "$SCRIPT_DIR/Package.resolved"
    fi
    rm -f "$RESOLVED_STATE"
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    restore_resolved_file
    cleanup_preview_libs
    rm -f "$LOCK_DIRECTORY/pid"
    rmdir "$LOCK_DIRECTORY" 2>/dev/null
    exit "$status"
}
trap cleanup EXIT

if [[ -f "$RESOLVED_STATE" ]]; then
    restore_resolved_file
fi
if [[ -f "$SCRIPT_DIR/Package.resolved" ]]; then
    cp -p "$SCRIPT_DIR/Package.resolved" "$STABLE_RESOLVED"
    echo present > "$RESOLVED_STATE"
    rm -f "$SCRIPT_DIR/Package.resolved"
else
    echo absent > "$RESOLVED_STATE"
fi
if [[ -f "$PREVIEW_RESOLVED" ]]; then
    mv "$PREVIEW_RESOLVED" "$SCRIPT_DIR/Package.resolved"
fi

PREVIEW_ARGUMENTS=(
    --disable-sandbox
    --package-path "$SCRIPT_DIR"
    --scratch-path "$PREVIEW_SCRATCH_PATH"
    --configuration release
    --swift-sdks-path "$SWIFT_SDKS_PATH"
    --swift-sdk "$SWIFT_SDK_ID"
)
if [[ -n "${SWIFTPM_PREVIEW_BUILD_ARGUMENTS:-}" ]]; then
    read -r -a EXTRA_BUILD_ARGUMENTS <<< "$SWIFTPM_PREVIEW_BUILD_ARGUMENTS"
    PREVIEW_ARGUMENTS+=("${EXTRA_BUILD_ARGUMENTS[@]}")
fi
PREVIEW_ARGUMENTS+=(--product Example)

"$PREVIEW_BUILD" "${PREVIEW_ARGUMENTS[@]}"

shopt -s nullglob
ELF_CANDIDATES=("$PREVIEW_SCRATCH_PATH"/out/Products/*/Example.elf)
shopt -u nullglob
if [[ ${#ELF_CANDIDATES[@]} -ne 1 ]]; then
    echo "Expected exactly one finalized Example.elf, found ${#ELF_CANDIDATES[@]}." >&2
    exit 1
fi
OUTPUT_DIRECTORY="$(dirname "${ELF_CANDIDATES[0]}")"
for suffix in elf uf2 bin hex elf.map dis; do
    if [[ ! -f "$OUTPUT_DIRECTORY/Example.$suffix" ]]; then
        echo "The post-product task did not produce $OUTPUT_DIRECTORY/Example.$suffix" >&2
        exit 1
    fi
done

echo "[CPicoSDK] SwiftPM product and firmware artifacts: $OUTPUT_DIRECTORY"

if [[ "${1:-}" == "--flash" ]]; then
    PICOTOOL_CANDIDATES=("$SWIFT_SDKS_PATH"/cpicosdk-rp2xxx.artifactbundle/pico-sdk-bundle/picotool/*/picotool/picotool)
    if [[ ${#PICOTOOL_CANDIDATES[@]} -ne 1 || ! -x "${PICOTOOL_CANDIDATES[0]}" ]]; then
        echo "Unable to resolve picotool from the staged Swift SDK." >&2
        exit 1
    fi
    while ! "${PICOTOOL_CANDIDATES[0]}" info >/dev/null 2>&1; do
        echo "Waiting for a device in BOOTSEL mode (retrying in 2 seconds)..."
        sleep 2
    done
    "${PICOTOOL_CANDIDATES[0]}" load "$OUTPUT_DIRECTORY/Example.uf2"
    "${PICOTOOL_CANDIDATES[0]}" reboot
fi
