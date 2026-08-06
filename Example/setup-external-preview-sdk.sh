#!/usr/bin/env bash
set -euo pipefail

# Assemble the host-specific Pico tools as an installed Swift SDK. This is a
# one-time destination setup step; normal preview builds should only select the
# resulting SDK ID.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/ExternalPreviewSDK"
STAGING_ROOT="${CPICOSDK_SWIFT_SDK_STAGING_ROOT:-$SCRIPT_DIR/.build/swift-sdk-staging}"
TOOLCHAIN_PIN_FILE="$TEMPLATE_DIR/swift-toolchain.txt"
if [[ ! -s "$TOOLCHAIN_PIN_FILE" ]]; then
    echo "Missing preview toolchain pin: $TOOLCHAIN_PIN_FILE" >&2
    exit 1
fi
DEFAULT_SWIFT_SELECTOR="$(<"$TOOLCHAIN_PIN_FILE")"

SDK_VERSION="${SDK_VERSION:-2.2.0}"
TOOLCHAIN_VERSION="${TOOLCHAIN_VERSION:-14_2_Rel1}"
CMAKE_VERSION="${CMAKE_VERSION:-3.31.5}"
NINJA_VERSION="${NINJA_VERSION:-1.12.1}"
PICOTOOL_VERSION="${PICOTOOL_VERSION:-2.2.0-a4}"
OPENOCD_VERSION="${OPENOCD_VERSION:-0.12.0+dev}"
BUNDLE_VERSION="${CPICOSDK_SWIFT_SDK_BUNDLE_VERSION:-$SDK_VERSION}"

MODE="stage"
case "${1:-}" in
    "") ;;
    --metadata-only) MODE="metadata" ;;
    --stage-only) MODE="stage" ;;
    --install) MODE="install" ;;
    --help|-h)
        cat <<'EOF'
Usage: ./setup-external-preview-sdk.sh [--metadata-only|--stage-only|--install]

  --metadata-only  Render and validate relocatable SDK metadata without downloading tools.
  --stage-only     Download tools and build a complete artifact bundle without installing it. (default)
  --install        Stage the bundle and install its cpicosdk-rp2040 and cpicosdk-rp2350 SDK IDs.

Swift selection, in priority order:

  CPICOSDK_SWIFT=/absolute/path/to/swift
  CPICOSDK_SWIFT_TOOLCHAIN=<swiftly selector>
  SWIFTPM_PREVIEW_TOOLCHAIN=<swiftly selector>
  ExternalPreviewSDK/swift-toolchain.txt

The selected compiler supplies a verified, target-specific Embedded Swift
resource subset that is copied into the bundle. CPICOSDK_PREPARE_SWIFT may
separately select the released SwiftPM used only to invoke the existing
preparation plugin.
EOF
        exit 0
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "Run $0 --help for usage." >&2
        exit 2
        ;;
esac

validate_identifier() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        echo "$name contains unsupported characters: $value" >&2
        exit 2
    fi
}

validate_identifier SDK_VERSION "$SDK_VERSION"
validate_identifier TOOLCHAIN_VERSION "$TOOLCHAIN_VERSION"
validate_identifier CMAKE_VERSION "$CMAKE_VERSION"
validate_identifier NINJA_VERSION "$NINJA_VERSION"
validate_identifier PICOTOOL_VERSION "$PICOTOOL_VERSION"
validate_identifier OPENOCD_VERSION "$OPENOCD_VERSION"
validate_identifier CPICOSDK_SWIFT_SDK_BUNDLE_VERSION "$BUNDLE_VERSION"

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
SWIFT_SELECTOR="${CPICOSDK_SWIFT_TOOLCHAIN:-${SWIFTPM_PREVIEW_TOOLCHAIN:-$DEFAULT_SWIFT_SELECTOR}}"
if [[ -n "${CPICOSDK_SWIFT:-}" ]]; then
    SWIFT_BIN="$CPICOSDK_SWIFT"
elif [[ -n "$SWIFT_SELECTOR" ]]; then
    validate_identifier Swift-toolchain-selector "$SWIFT_SELECTOR"
    if [[ -z "$SWIFTLY_PATH" ]]; then
        echo "A Swift toolchain selector requires swiftly, but swiftly was not found." >&2
        exit 1
    fi
    SWIFT_BIN="$(cd "$SCRIPT_DIR" && "$SWIFTLY_PATH" run which swift "+$SWIFT_SELECTOR")"
elif [[ -n "$SWIFTLY_PATH" ]]; then
    SWIFT_BIN="$(cd "$SCRIPT_DIR" && "$SWIFTLY_PATH" run which swift)"
elif command -v swift >/dev/null 2>&1; then
    SWIFT_BIN="$(command -v swift)"
else
    echo "No Swift compiler was found." >&2
    exit 1
fi

if [[ ! -x "$SWIFT_BIN" ]]; then
    echo "Selected Swift compiler is not executable: $SWIFT_BIN" >&2
    exit 1
fi
SWIFT_BIN="$(cd "$(dirname "$SWIFT_BIN")" && pwd)/$(basename "$SWIFT_BIN")"

SWIFT_TARGET_INFO="$($SWIFT_BIN -print-target-info)"
if command -v python3 >/dev/null 2>&1; then
    HOST_TRIPLE="$(printf '%s' "$SWIFT_TARGET_INFO" | python3 -c 'import json,sys; t=json.load(sys.stdin)["target"]; print(t.get("unversionedTriple", t["triple"]))')"
    SWIFT_RUNTIME_RESOURCE_PATH="$(printf '%s' "$SWIFT_TARGET_INFO" | python3 -c 'import json,sys; print(json.load(sys.stdin)["paths"]["runtimeResourcePath"])')"
else
    HOST_TRIPLE="$(printf '%s\n' "$SWIFT_TARGET_INFO" | awk -F'"' '/"unversionedTriple"/ { print $4; found=1; exit } END { if (!found) exit 1 }' || printf '%s\n' "$SWIFT_TARGET_INFO" | awk -F'"' '/"triple"/ { print $4; exit }')"
    SWIFT_RUNTIME_RESOURCE_PATH="$(printf '%s\n' "$SWIFT_TARGET_INFO" | awk -F'"' '/"runtimeResourcePath"/ { print $4; exit }')"
fi
validate_identifier Swift-host-triple "$HOST_TRIPLE"
if [[ -z "$SWIFT_RUNTIME_RESOURCE_PATH" || "$SWIFT_RUNTIME_RESOURCE_PATH" != /* ]]; then
    echo "Selected Swift compiler reported an invalid runtime resource path." >&2
    exit 1
fi
EMBEDDED_RUNTIME_PATH="$SWIFT_RUNTIME_RESOURCE_PATH/embedded"

TARGET_TRIPLES=(
    armv6m-none-none-eabi
    armv7em-none-none-eabi
)
for target_triple in "${TARGET_TRIPLES[@]}"; do
    required_runtime_paths=(
        "$EMBEDDED_RUNTIME_PATH/Swift.swiftmodule/$target_triple.swiftmodule"
        "$EMBEDDED_RUNTIME_PATH/Synchronization.swiftmodule/$target_triple.swiftmodule"
        "$EMBEDDED_RUNTIME_PATH/$target_triple"
        "$EMBEDDED_RUNTIME_PATH/$target_triple/libswiftEmbeddedPlatformPOSIX.a"
    )
    for runtime_path in "${required_runtime_paths[@]}"; do
        if [[ ! -e "$runtime_path" ]]; then
            echo "Selected Swift compiler does not support $target_triple: missing $runtime_path" >&2
            exit 1
        fi
    done
done

RP2040_CONCURRENCY_SUPPORTED=false
if [[ -f "$EMBEDDED_RUNTIME_PATH/_Concurrency.swiftmodule/armv6m-none-none-eabi.swiftmodule" && \
      -f "$EMBEDDED_RUNTIME_PATH/armv6m-none-none-eabi/libswift_Concurrency.a" ]]; then
    RP2040_CONCURRENCY_SUPPORTED=true
fi
RP2350_CONCURRENCY_SUPPORTED=false
if [[ -f "$EMBEDDED_RUNTIME_PATH/_Concurrency.swiftmodule/armv7em-none-none-eabi.swiftmodule" && \
      -f "$EMBEDDED_RUNTIME_PATH/armv7em-none-none-eabi/libswift_Concurrency.a" ]]; then
    RP2350_CONCURRENCY_SUPPORTED=true
fi
if [[ "$RP2350_CONCURRENCY_SUPPORTED" != true ]]; then
    echo "Selected Swift compiler lacks the RP2350 Embedded Swift concurrency runtime." >&2
    exit 1
fi
if [[ "$RP2040_CONCURRENCY_SUPPORTED" != true ]]; then
    echo "[CPicoSDK] Note: selected Swift supports RP2040 base firmware but not its concurrency runtime." >&2
    if [[ "${CPICOSDK_REQUIRE_RP2040_CONCURRENCY:-0}" == "1" ]]; then
        exit 1
    fi
fi

mkdir -p "$STAGING_ROOT"
WORK_ROOT="$(mktemp -d "$STAGING_ROOT/.cpicosdk-rp2xxx.XXXXXX")"
WORK_BUNDLE="$WORK_ROOT/cpicosdk-rp2xxx.artifactbundle"

safe_remove_tree() {
    local candidate="$1"
    local candidate_name
    candidate_name="$(basename "$candidate")"
    case "$candidate" in
        "$STAGING_ROOT"/*)
            if [[ "$candidate_name" == .cpicosdk-rp2xxx.* ]]; then
                rm -rf -- "$candidate"
                return
            fi
            ;;
    esac
    echo "Refusing to remove unexpected path: $candidate" >&2
    exit 1
}

cleanup() {
    if [[ -n "${WORK_ROOT:-}" && -e "$WORK_ROOT" ]]; then
        safe_remove_tree "$WORK_ROOT"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p \
    "$WORK_BUNDLE/generated/newlib_overlay" \
    "$WORK_BUNDLE/rp2040" \
    "$WORK_BUNDLE/rp2350" \
    "$WORK_BUNDLE/toolsets"

render_template() {
    local source="$1"
    local destination="$2"
    sed \
        -e "s|@SDK_VERSION@|$SDK_VERSION|g" \
        -e "s|@TOOLCHAIN_VERSION@|$TOOLCHAIN_VERSION|g" \
        -e "s|@CMAKE_VERSION@|$CMAKE_VERSION|g" \
        -e "s|@NINJA_VERSION@|$NINJA_VERSION|g" \
        -e "s|@PICOTOOL_VERSION@|$PICOTOOL_VERSION|g" \
        -e "s|@OPENOCD_VERSION@|$OPENOCD_VERSION|g" \
        -e "s|@BUNDLE_VERSION@|$BUNDLE_VERSION|g" \
        -e "s|@HOST_TRIPLE@|$HOST_TRIPLE|g" \
        -e "s|@RP2040_CONCURRENCY_SUPPORTED@|$RP2040_CONCURRENCY_SUPPORTED|g" \
        -e "s|@RP2350_CONCURRENCY_SUPPORTED@|$RP2350_CONCURRENCY_SUPPORTED|g" \
        "$source" > "$destination"
}

render_metadata() {
    render_template "$TEMPLATE_DIR/info.json.in" "$WORK_BUNDLE/info.json"
    render_template \
        "$TEMPLATE_DIR/rp2040-swift-sdk.json.in" \
        "$WORK_BUNDLE/rp2040/swift-sdk.json"
    render_template \
        "$TEMPLATE_DIR/rp2350-swift-sdk.json.in" \
        "$WORK_BUNDLE/rp2350/swift-sdk.json"
    render_template \
        "$TEMPLATE_DIR/rp2xxx-toolset.json.in" \
        "$WORK_BUNDLE/toolsets/rp2xxx.json"
    render_template \
        "$TEMPLATE_DIR/cpicosdk-layout.json.in" \
        "$WORK_BUNDLE/cpicosdk-layout.json"
    render_template \
        "$TEMPLATE_DIR/stdatomic.h.in" \
        "$WORK_BUNDLE/generated/newlib_overlay/stdatomic.h"
    "$SWIFT_BIN" --version > "$WORK_BUNDLE/swift-compiler-version.txt"
}

validate_metadata() {
    local json_files=(
        "$WORK_BUNDLE/info.json"
        "$WORK_BUNDLE/rp2040/swift-sdk.json"
        "$WORK_BUNDLE/rp2350/swift-sdk.json"
        "$WORK_BUNDLE/toolsets/rp2xxx.json"
        "$WORK_BUNDLE/cpicosdk-layout.json"
    )

    if command -v python3 >/dev/null 2>&1; then
        local json_file
        for json_file in "${json_files[@]}"; do
            python3 -m json.tool "$json_file" >/dev/null
        done
    else
        echo "Warning: python3 is unavailable; SwiftPM will perform the JSON schema check." >&2
    fi

    if grep -Eq '": *"/|^[[:space:]]*"/' \
        "$WORK_BUNDLE/rp2040/swift-sdk.json" \
        "$WORK_BUNDLE/rp2350/swift-sdk.json" \
        "$WORK_BUNDLE/toolsets/rp2xxx.json" \
        "$WORK_BUNDLE/cpicosdk-layout.json"
    then
        echo "Generated SDK metadata contains an absolute path." >&2
        exit 1
    fi

    local listed_sdks
    listed_sdks="$($SWIFT_BIN sdk list --swift-sdks-path "$WORK_ROOT")"
    grep -Fxq cpicosdk-rp2040 <<< "$listed_sdks"
    grep -Fxq cpicosdk-rp2350 <<< "$listed_sdks"
}

copy_embedded_runtime_subset() {
    # swiftResourcesPath is a Swift resource root. Embedded modules live in
    # its `embedded` child, matching a normal toolchain's usr/lib/swift layout.
    local destination="$WORK_BUNDLE/swift-resources/embedded"
    mkdir -p "$destination"

    # The compiler still resolves SwiftShims and its Clang resource headers
    # from the parent Swift resource root. Copy the selected compiler's exact
    # support directories; resolve the toolchain's out-of-tree clang symlink so
    # the artifact bundle stays self-contained.
    cp -R "$SWIFT_RUNTIME_RESOURCE_PATH/shims" \
        "$WORK_BUNDLE/swift-resources/shims"
    local clang_resource_path
    clang_resource_path="$(cd "$SWIFT_RUNTIME_RESOURCE_PATH/clang" && pwd -P)"
    cp -R "$clang_resource_path" "$WORK_BUNDLE/swift-resources/clang"

    local root_file
    for root_file in "$EMBEDDED_RUNTIME_PATH"/*; do
        if [[ -f "$root_file" ]]; then
            cp -p "$root_file" "$destination/"
        fi
    done

    local target_triple
    for target_triple in "${TARGET_TRIPLES[@]}"; do
        cp -R "$EMBEDDED_RUNTIME_PATH/$target_triple" "$destination/$target_triple"
    done

    local module_directory
    for module_directory in "$EMBEDDED_RUNTIME_PATH"/*.swiftmodule; do
        local copied=false
        local target_file
        for target_triple in "${TARGET_TRIPLES[@]}"; do
            for target_file in "$module_directory/$target_triple".*; do
                if [[ -f "$target_file" ]]; then
                    if [[ "$copied" == false ]]; then
                        mkdir -p "$destination/$(basename "$module_directory")"
                        copied=true
                    fi
                    cp -p "$target_file" "$destination/$(basename "$module_directory")/"
                fi
            done
        done
    done
}

publish_bundle() {
    local destination="$1"
    local destination_parent
    local backup
    destination_parent="$(dirname "$destination")"
    backup="$destination_parent/.cpicosdk-rp2xxx.previous.$$"
    mkdir -p "$destination_parent"

    if [[ -e "$destination" ]]; then
        mv "$destination" "$backup"
    fi
    if mv "$WORK_BUNDLE" "$destination"; then
        if [[ -e "$backup" ]]; then
            safe_remove_tree "$backup"
        fi
    else
        if [[ -e "$backup" ]]; then
            mv "$backup" "$destination"
        fi
        return 1
    fi
}

render_metadata
"$SWIFT_BIN" "$TEMPLATE_DIR/NormalizeBundle.swift" "$WORK_BUNDLE"
validate_metadata

if [[ "$MODE" == "metadata" ]]; then
    METADATA_BUNDLE="$STAGING_ROOT/metadata/cpicosdk-rp2xxx.artifactbundle"
    publish_bundle "$METADATA_BUNDLE"
    echo "[CPicoSDK] Relocatable Swift SDK metadata: $METADATA_BUNDLE"
    echo "[CPicoSDK] Selected Swift: $SWIFT_BIN"
    exit 0
fi

# Package@swift-6.5.swift belongs to the PR experiment. Invoke the established
# preparation command with the Example's released SwiftPM selection unless an
# explicit preparation compiler is supplied.
if [[ -n "${CPICOSDK_PREPARE_SWIFT:-}" ]]; then
    PREPARE_SWIFT_BIN="$CPICOSDK_PREPARE_SWIFT"
elif [[ -n "$SWIFTLY_PATH" ]]; then
    PREPARE_SWIFT_BIN="$(cd "$SCRIPT_DIR" && "$SWIFTLY_PATH" run which swift)"
else
    PREPARE_SWIFT_BIN="$SWIFT_BIN"
fi
if [[ ! -x "$PREPARE_SWIFT_BIN" ]]; then
    echo "Preparation Swift compiler is not executable: $PREPARE_SWIFT_BIN" >&2
    exit 1
fi

PREPARATION_SCRIPT="$WORK_ROOT/prepared-environment.sh"
PICO_SDK_BUNDLE_PATH="$WORK_BUNDLE/pico-sdk-bundle"
PICO_TOOLCHAIN_PATH="$PICO_SDK_BUNDLE_PATH/toolchain/$TOOLCHAIN_VERSION"

cd "$SCRIPT_DIR"
env \
    CMAKE_PATH="$PICO_SDK_BUNDLE_PATH/cmake/v$CMAKE_VERSION/bin" \
    CMAKE_VERSION="$CMAKE_VERSION" \
    GDB_PATH="$PICO_TOOLCHAIN_PATH/bin/arm-none-eabi-gdb" \
    LD_PATH="$PICO_TOOLCHAIN_PATH/bin/arm-none-eabi-ld" \
    NINJA_PATH="$PICO_SDK_BUNDLE_PATH/ninja/v$NINJA_VERSION" \
    NINJA_VERSION="$NINJA_VERSION" \
    OPENOCD_PATH="$PICO_SDK_BUNDLE_PATH/openocd/$OPENOCD_VERSION" \
    OPENOCD_VERSION="$OPENOCD_VERSION" \
    PICOTOOL_PATH="$PICO_SDK_BUNDLE_PATH/picotool/$PICOTOOL_VERSION/picotool/picotool" \
    PICOTOOL_VERSION="$PICOTOOL_VERSION" \
    PICO_SDK_BUNDLE_PATH="$PICO_SDK_BUNDLE_PATH" \
    PICO_SDK_PATH="$PICO_SDK_BUNDLE_PATH/sdk/$SDK_VERSION" \
    PICO_TOOLCHAIN_PATH="$PICO_TOOLCHAIN_PATH" \
    PLUGIN_OUTPUT_PATH="$WORK_BUNDLE" \
    SDK_PATH="$PICO_TOOLCHAIN_PATH/arm-none-eabi" \
    SDK_VERSION="$SDK_VERSION" \
    SWIFTLY_PATH="${SWIFTLY_PATH:-$SWIFT_BIN}" \
    SWIFT_EMBEDDED_FALLBACK_MODULES=0 \
    TOOLCHAIN_VERSION="$TOOLCHAIN_VERSION" \
    TOOLSET_PATH="$WORK_BUNDLE/toolsets/rp2xxx.json" \
    "$PREPARE_SWIFT_BIN" package prepare-rp2xxx-environment \
        --disable-sandbox \
        --dont-force-product-name \
        --disable-sourcekit-lsp-settings \
        --disable-swift-version \
        --disable-vscode-settings \
        --dump-prep-script "$PREPARATION_SCRIPT" \
        --allow-writing-to-package-directory \
        --allow-network-connections all

# Replace preparation's per-project absolute metadata, then add the verified
# resource subset belonging to the selected preview compiler.
render_metadata
copy_embedded_runtime_subset

required_paths=(
    "$PICO_SDK_BUNDLE_PATH/sdk/$SDK_VERSION"
    "$PICO_TOOLCHAIN_PATH/arm-none-eabi"
    "$PICO_TOOLCHAIN_PATH/bin/arm-none-eabi-ar"
    "$PICO_TOOLCHAIN_PATH/bin/arm-none-eabi-ld"
    "$PICO_SDK_BUNDLE_PATH/cmake/v$CMAKE_VERSION/bin/cmake"
    "$PICO_SDK_BUNDLE_PATH/ninja/v$NINJA_VERSION/ninja"
    "$PICO_SDK_BUNDLE_PATH/picotool/$PICOTOOL_VERSION/picotool/picotool"
    "$PICO_SDK_BUNDLE_PATH/openocd/$OPENOCD_VERSION"
    "$WORK_BUNDLE/swift-resources/embedded/Swift.swiftmodule/armv7em-none-none-eabi.swiftmodule"
)
for required_path in "${required_paths[@]}"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Prepared Swift SDK is missing: $required_path" >&2
        exit 1
    fi
done

# Raspberry Pi's Darwin bundles currently contain absolute convenience links
# for CMake and OpenOCD. Rewrite links whose targets are inside the bundle and
# reject broken links or any link that escapes it before publishing.
"$SWIFT_BIN" "$TEMPLATE_DIR/NormalizeBundle.swift" "$WORK_BUNDLE"
validate_metadata

ARTIFACT_BUNDLE="$STAGING_ROOT/cpicosdk-rp2xxx.artifactbundle"
publish_bundle "$ARTIFACT_BUNDLE"
payload_size="$(du -sh "$ARTIFACT_BUNDLE" | awk '{print $1}')"
echo "[CPicoSDK] Staged Swift SDK bundle: $ARTIFACT_BUNDLE ($payload_size)"
echo "[CPicoSDK] SDK IDs: cpicosdk-rp2040, cpicosdk-rp2350"

if [[ "$MODE" != "install" ]]; then
    echo "[CPicoSDK] Re-run with --install to copy this bundle into SwiftPM's shared SDK store."
    exit 0
fi

installed_sdks="$($SWIFT_BIN sdk list)"
if grep -Fxq cpicosdk-rp2040 <<< "$installed_sdks" || \
    grep -Fxq cpicosdk-rp2350 <<< "$installed_sdks"
then
    echo "A CPicoSDK Swift SDK is already installed." >&2
    echo "Inspect it with 'swift sdk list'; remove the old bundle explicitly before replacing it." >&2
    exit 1
fi

echo "[CPicoSDK] Installing a second copy of the staged $payload_size bundle into SwiftPM's shared SDK store."
"$SWIFT_BIN" sdk install "$ARTIFACT_BUNDLE"
echo "[CPicoSDK] Build with '--swift-sdk cpicosdk-rp2350' or '--swift-sdk cpicosdk-rp2040'."
