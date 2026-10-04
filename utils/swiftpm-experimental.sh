#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
checkout=${SWIFTPM_CHECKOUT:-"$root/../swiftpm-pr-10374"}
command=${1:-build}
case "$command" in build|package|test) shift ;; *) echo "Expected build, package, or test" >&2; exit 2 ;; esac
libraries="$root/.build/experimental-swiftpm"
mkdir -p "$libraries/ManifestAPI" "$libraries/PluginAPI"
for module in PackageDescription CompilerPluginSupport PackagePlugin; do
    directory=ManifestAPI
    if [ "$module" = PackagePlugin ]; then directory=PluginAPI; fi
    for suffix in swiftmodule swiftdoc; do
        ln -sf "$checkout/.build/debug/Modules/$module.$suffix" "$libraries/$directory/$module.$suffix"
    done
    ln -sf "$checkout/.build/debug/lib$module.dylib" "$libraries/$directory/lib$module.dylib"
done
export SWIFTPM_CUSTOM_LIBS_DIR="$libraries"
export SWIFT_EXEC_MANIFEST=${SWIFT_EXEC_MANIFEST:-$(xcrun --find swiftc)}
export SWIFT_EXEC=${SWIFT_EXEC:-$(xcrun --find swiftc)}
export CC=${CC:-$(xcrun --find clang)}
export PATH="$root/utils/experimental-toolchain:$PATH"
exec "$checkout/.build/debug/swift-$command" "$@"
