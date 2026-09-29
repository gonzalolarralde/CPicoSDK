# Custom-target firmware prototype

This branch experiments with [SwiftPM PR #10374](https://github.com/swiftlang/swift-package-manager/pull/10374)
and [Swift Build PR #1740](https://github.com/swiftlang/swift-build/pull/1740).
It requires the modified local SwiftPM build, not a released Swift toolchain.

## Current local-target experiment

`Firmware` now lives in `Example/Package.swift` and depends on the local
`Example` target. The nested `Example/Firmware` directory has been removed;
the source-free target uses `path: ".", exclude: ["Sources"], sources: []`, and
`build.sh` no longer passes `--package-path Firmware`.

Running `bash build.sh` from `Example` fails with `Build input file cannot be
found` for `libExample.a`. The plugin can find the local static product's
metadata, but a target dependency does not build that product's archive.
The reproducer log is `.build/local-target-launcher.log` at the repository root.

The architecture and successful verification below describe the earlier
wrapper-package implementation, before this experiment.

## Build graph

```text
Example static library
  Swift/C sources + PIOASM + AssetCompiler
       |
       v
Firmware custom target / PicoFirmware plugin
  PicoFirmwareBuildTool
    detect board and stdio traits from archive
    select embedded Swift runtime archives
    configure and build Pico SDK with CMake/Ninja
    link firmware, embed assets, generate ELF/UF2, report memory use
       |
       v
COPY_CMD publishes Example.elf and Example.uf2 to PRODUCTS_DIR
```

The finalizer is now a build-tool executable shared by the new build plugin and
the existing `finalize-rp2xxx-binary` command plugin. The build plugin declares
the application archive, tool binaries, CMake harness, SDK configuration, and
assets as inputs. ELF and UF2 are explicit outputs. CMake's build directory is
retained between runs; the legacy command still cleans unless `--incremental`
is supplied.

`Example/Firmware` is a small outer package so its custom target can depend on
the **Example product**, not just the Example source target. PR #10374 does not
yet provide same-package product dependencies to express that relationship.
Build `--target Firmware` explicitly: the prototype does not include otherwise
unreferenced custom targets in its default aggregate build.

The manifest's macOS 13 minimum is for host build tools using Foundation and
Swift Regex APIs. The firmware still targets bare-metal ARM.

## Local setup

Checkouts are siblings under `src/swift-contrib`:

- `CPicoSDK`, based on `a1aa863645122f9a985a0b6de4f63c5e04853a73`.
- `swiftpm-pr-10374`, PR head `f9eefb1d0e29c4543fd97aee87851b1c7d3d6f44`.
- `swift-build-pr-1740`, PR head `7df50450b485ca888cc941d71180b5fa932c1f04`.
- `swift-build` points to the PR #1740 checkout. Other local SwiftPM dependency
  paths point to the existing SwiftCompiler dependency checkouts.

With `SWIFTCI_USE_LOCAL_DEPS=1`, build these products in the SwiftPM checkout:
`swift-build`, `swift-package`, `swift-test`, `swiftpm-testing-helper`,
`PackageDescription`, and `PackagePlugin`. The local build uses Xcode's host
Swift compiler. `utils/swiftpm-experimental.sh` supplies that build's manifest
and plugin libraries and routes nested `swift package` calls to it too.

The existing SwiftCompiler checkout is not modified by this experiment.

## Run

Install the embedded toolchain specified by `Example/.swift-version` with
swiftly first. Then, from `Example`:

```sh
bash build.sh
```

`SWIFTPM_CHECKOUT` can select another build of the patched SwiftPM.
`CPICOSDK_SWIFT_EXEC` can select an explicit embedded `swiftc`. It affects the
destination toolset and runtime selection, not host manifest/plugin compilation.
`PICO_SDK_BUNDLE_PATH` can reuse an existing SDK bundle; in that case pass
`--disable-install-dependencies` to avoid downloading tools again.

The launcher prepares the toolset, then runs one Swift Build invocation for
`Firmware`. It prints the products directory returned by `--show-bin-path`.
It no longer invokes the finalization command separately. Flashing remains
explicit (`--flash`); ordinary builds do not access a device.

Host tests, from the repository root:

```sh
CPICOSDK_HOST_TESTS=1 sh utils/swiftpm-experimental.sh test --build-system native
```

## Required local upstream patches

These are experimental changes in the isolated upstream checkouts, **not**
changes already supplied by the referenced PRs:

1. SwiftPM `SwiftBuildSystem.swift`: qualify bare-metal architecture, vendor,
   and environment overrides with `__destination_platform=YES`. Unqualified
   overrides incorrectly compile macOS plugin tools for an ARM/macOS triple.
2. Swift Build `SWBGenericUnixPlatform/Plugin.swift`: let the `none` platform
   inherit the Unix linker and archiver specifications. Otherwise ARM `ld`
   receives Darwin flags, such as `-reproducible`.
3. SwiftPM `PackagePIFProjectBuilder+Products.swift`: materialize explicitly
   static dependency products, not just root-package products. Otherwise the
   custom target depends on a product group but there is no `libExample.a`.
4. SwiftPM `PackagePIFProjectBuilder+Modules.swift`: represent source-free Clang
   modules without plugins/resources as interface-only product groups. This
   avoids archive inputs referring to nonexistent objects for header-only SDK
   modules.

The CPicoSDK toolset now specifies the ARM librarian and an explicit newlib
header search path. Swift Build's placeholder bare-metal SDK otherwise wins
over the toolset's `-sdk` argument.

These patches need focused upstream regression tests and broader review before
being proposed as contributions. In particular, dependency archive
materialization is a policy choice, not merely plugin API plumbing.

## Verification

The local macOS/Apple Silicon run verified:

- PR SwiftPM and Swift Build compile successfully with the patches above.
- All 55 host tests pass, including the three new firmware-request tests.
- `Example/build.sh --disable-install-dependencies`, using the existing Pico SDK
  bundle, produces an ARM EABI5 ELF and UF2 in the published products directory.
  The firmware build commands run with the plugin sandbox enabled.
- The no-change firmware build stage completes in 1.4 seconds, without rerunning
  CMake or changing either published artifact's timestamp.
- A temporary asset-content edit triggers regeneration, compilation, firmware
  linking, and publication (5.6 seconds for the build stage). The added text is
  present in the ELF and the UF2 digest changes. Restoring the original asset
  rebuilds successfully; the temporary source edit is not retained.
- The sample asset's linker symbols lie in flash (`0x1004d660`), with 38 bytes of
  content and no static RAM allocation reported for embedded resources.

Build logs are under the root `.build/`: `host-tests.log`,
`firmware-experimental.log`, `firmware-incremental.log`,
`firmware-asset-change.log`, and `firmware-restored.log`.
No firmware was flashed and no upstream test suite was run for the local patches.

## CMake cache invalidation

The firmware tool records SDK/toolchain paths and versions, CMake/Ninja paths
and versions, and board selection after a successful CMake configuration. A
change to those inputs resets the plugin's CMake build directory. Existing
directories without a stamp are reset once; matching environments retain their
incremental objects. Downloaded bundles and SwiftPM build caches are untouched.

This fixes switching from a reused SDK bundle to the default bundle: CMake had
retained platform files and compiler paths from the old bundle, causing
`add_subdirectory` errors when combined with the new SDK path. Plain
`bash build.sh` now builds successfully with the default bundle. All 59 host
tests pass, including cache retention, environment changes, migration from an
unstamped directory, and explicit clean requests. Tool failures now print an
error and exit unsuccessfully rather than raising a top-level Swift fatal error.

## Boundaries

- Preparation remains a command plugin. Downloads, compiler selection, and
  toolset generation must precede SwiftPM's planning phase. A proper Swift SDK
  distribution is the longer-term way to remove this environment setup.
- PIO assembly already runs in a build plugin. AssetCompiler still uses its
  existing generated Swift accessor/content sidecar; objcopy embedding now
  executes under the firmware build plugin. Migrating that compiler to generated
  C `#embed` can be a separate, independently testable change.
- SDK header/package generation remains a maintainer operation; this does not
  regenerate the checked-in SDK headers during application builds.
- The wrapper is a macOS development helper. Linux, other Pico boards, device
  flashing, and the existing device-test launcher need separate validation.
- Treat downloaded SDK/toolchain bundles as immutable versioned inputs. The
  plugin does not enumerate every source inside them for Swift Build invalidation.
- IDE configurations are not regenerated by this launcher because their old
  native-build artifact paths do not describe the new firmware products directory.
