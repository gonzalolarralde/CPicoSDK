# SwiftPM External Packages Investigation

## Scope

This document records an end-to-end evaluation of
[swift-package-manager#10198](https://github.com/swiftlang/swift-package-manager/pull/10198)
against the user-facing `Example` build. The goal was to make SwiftPM own as
much of the firmware build graph as its external-build-system model naturally
allows, while leaving the released `Example/build.sh` behavior unchanged.

The evaluated revisions were:

- SwiftPM `524b58aca7cc10609d828fcb1d01f4451f5bb61c`
- its companion
  [swift-build#1493](https://github.com/swiftlang/swift-build/pull/1493) at
  `801cb538e676908033d55d8549053dba2556fe1c`
- Swift development snapshot `2026-07-28`
- CPicoSDK's pinned `2026-04-27` snapshot for the released-path control build

Nothing was pushed to either upstream repository. The SwiftPM and SwiftBuild
changes described below are local experiments only.

## Outcome

The completed preview is a single SwiftPM build graph:

```text
one-time CPicoSDK Swift SDK setup
    |
    v
external native-support task
    -> libCPicoNativeSupport.a
    -> pioasm-package-path.txt
    |
    v
ordinary Swift static product
    -> libExample.a
    |
    v
post-product firmware task
    -> Example.elf
    -> Example.uf2
    -> Example.bin
    -> Example.hex
    -> Example.elf.map
    -> Example.dis
```

`build-external-preview.sh` now makes exactly one `swift-build --product
Example` request. It does not invoke preparation, prime an external target, or
call the finalizer itself. SwiftPM owns the producer/consumer edges and the
final six outputs.

The established `Example/build.sh` remains the default released-toolchain
path. The preview is isolated in `Package@swift-6.5.swift` and the external
preview launcher.

## Where Preparation and Finalization Went

### Preparation became destination provisioning

The old preparation command had two different responsibilities:

1. obtain the Pico SDK, GNU ARM tools, CMake, Ninja, picotool, and OpenOCD; and
2. write destination metadata used by SwiftPM to plan a bare-metal build.

Those operations cannot be a normal target build command because SwiftPM needs
the compiler resources, sysroot, toolset, and target triple before it can
construct the target graph. The preview therefore runs preparation once from
`setup-external-preview-sdk.sh` and publishes the result as a relocatable Swift
SDK artifact bundle.

Normal builds only select `cpicosdk-rp2350` with `--swift-sdk`. They do not run
the preparation plugin.

The staged SDK includes:

- both RP2040 and RP2350 Swift SDK descriptors;
- the Pico SDK and host/ARM tools;
- the generated newlib overlay and SwiftPM toolset;
- the selected compiler's target-specific Embedded Swift modules and static
  runtime archives; and
- the compiler's matching Swift shims and Clang resource headers.

The compiler snapshot is pinned in
`Example/ExternalPreviewSDK/swift-toolchain.txt`. The launcher compares the
staged `swift-compiler-version.txt` with the selected compiler and fails rather
than mixing snapshots.

### Finalization became a post-product graph task

The finalizer still exists because a Swift static archive is not itself Pico
firmware. Something must combine the completed Swift product with:

- Pico startup and boot-stage code;
- product binary metadata;
- the linker script and allocator wrapping rules;
- selected Pico native support;
- required Embedded Swift runtime archives;
- embedded resource objects; and
- ELF-to-UF2/BIN/HEX conversion and diagnostic outputs.

Deleting that operation would only move the same work into a less explicit
link command. The useful migration is ownership: `FirmwareFinalizerTool` is now
a reusable host executable launched by a declared `.postProduct` external
command. SwiftPM supplies the exact product archive, native archive, pioasm
sidecar, destination SDK, tools, inputs, and output directory.

This leaves the finalizer cohesive while removing it from shell orchestration.

## Checked-In Preview Integration

### Version-gated manifest

`Example/Package@swift-6.5.swift` uses the PR's `.externalSource`,
`.externalLibrary`, and `.externalBuilder` declarations. The Example target
consumes `CPicoNativeSupport` like an ordinary static-library dependency and
attaches a post-product firmware builder.

The manifest intentionally describes Pico 2/RP2350. The launcher fixes the SDK
and combination to that same board so an ambient override cannot mix RP2040
native code with RP2350 Swift traits.

Released SwiftPM selects `Package.swift` and does not parse the preview-only
API.

### External native builder

`CPicoNativeBuilderPlugin` declares its source/configuration inputs and the
`pioasm-package-path.txt` output. `CPicoNativeBuilder` then:

1. resolves the selected CPicoSDK configuration and installed Swift SDK;
2. builds Pico's C++ `pioasm` as a host tool in an SDK-keyed cache;
3. configures the external CMake package with the SDK's ARM toolchain;
4. selects the requested stdio transport; and
5. produces `libCPicoNativeSupport.a` at the external product's declared path.

The child environment is the resolver's allowlisted environment, with
destination deployment variables removed for macOS host-tool compilation.
CMake/Ninja provide incremental work inside the external command.

### Post-product builder

`CPicoFirmwareFinalizerPlugin` declares:

- the materialized `libExample.a` product;
- the raw external native archive;
- the native builder's declared pioasm sidecar;
- the finalizer and memory-report host tools;
- configuration, harness, environment, and embedded-resource inputs; and
- ELF, UF2, BIN, HEX, map, and disassembly outputs.

The sidecar is not inferred by filesystem adjacency. A local extension to the
PR lets a typed external-product input select one of the producer's named
outputs, validates that the producer declared it, adds the file edge, and
injects its exact path through an environment variable.

On an identical second build, the external native command ran its conservative
CMake/Ninja check and reported no work. The post-product finalizer did not run
because its inputs and all six outputs were current.

### Launcher

The preview launcher is now bootstrap glue, not a build pipeline. It:

- selects the pinned preview compiler and staged Swift SDK;
- copies manifest/plugin runtime libraries found beside a development
  `swift-build` into an isolated temporary directory;
- protects the released `Package.resolved` from the prototype encoding;
- serializes that package-local transaction across all scratch paths;
- reuses the preview lockfile between invocations; and
- makes one product build request, then verifies the six declared outputs.

Flashing remains an explicit `--flash` action and is never part of a normal
build.

## Reproducing the Prototype

The exact local compatibility patches are checked in under
`Docs/SwiftPMExternalBuilderPatches`. The local dependency patch only points
SwiftPM at a sibling SwiftBuild checkout and is not an upstream source change.

```bash
mkdir -p ~/src/swiftpm-external-preview
cd ~/src/swiftpm-external-preview

git clone https://github.com/swiftlang/swift-build.git swift-build-baremetal-gap
git -C swift-build-baremetal-gap fetch origin \
  pull/1493/head:external-package-preview
git -C swift-build-baremetal-gap checkout \
  801cb538e676908033d55d8549053dba2556fe1c
git -C swift-build-baremetal-gap apply \
  /absolute/path/to/CPicoSDK/Docs/SwiftPMExternalBuilderPatches/swift-build.patch

git clone https://github.com/swiftlang/swift-package-manager.git \
  swift-package-manager
git -C swift-package-manager fetch origin \
  pull/10198/head:external-package-preview
git -C swift-package-manager checkout \
  524b58aca7cc10609d828fcb1d01f4451f5bb61c
git -C swift-package-manager apply \
  /absolute/path/to/CPicoSDK/Docs/SwiftPMExternalBuilderPatches/swift-package-manager.patch
git -C swift-package-manager apply \
  /absolute/path/to/CPicoSDK/Docs/SwiftPMExternalBuilderPatches/swift-package-manager-local-swift-build.patch

cd swift-package-manager
swiftly run swift build +main-snapshot-2026-07-28 \
  --build-system swiftbuild \
  --scratch-path .build-pr10198 \
  --product swift-build
swiftly run swift build +main-snapshot-2026-07-28 \
  --build-system swiftbuild \
  --scratch-path .build-pr10198 \
  --product PackageDescription
swiftly run swift build +main-snapshot-2026-07-28 \
  --build-system swiftbuild \
  --scratch-path .build-pr10198 \
  --product PackagePlugin
```

Stage the destination once, then build:

```bash
cd /absolute/path/to/CPicoSDK/Example
./setup-external-preview-sdk.sh --stage-only

SWIFTPM_PREVIEW_BUILD=~/src/swiftpm-external-preview/swift-package-manager/.build-pr10198/out/Products/Debug/swift-build \
  ./build-external-preview.sh
```

The default output directory is:

```text
Example/.build/swiftpm-external-preview/out/Products/Release-none-armv7em/
```

It contains `Example.elf`, `Example.uf2`, `Example.bin`, `Example.hex`,
`Example.elf.map`, and `Example.dis`.

`SWIFTPM_PREVIEW_SCRATCH_PATH` can select another build directory.
`SWIFTPM_PREVIEW_LIBS_DIR` is only needed for a nonstandard installed
ManifestAPI/PluginAPI layout.

## Verified Result

A clean, unprimed build completed on macOS from an empty scratch directory.
SwiftPM first built the native archive, then the Swift product, then the final
firmware outputs. The run produced:

| Measurement | Value |
| --- | ---: |
| BIN payload | 352,572 bytes |
| UF2 file | 706,048 bytes |
| Flash sections | 326.38 KiB |
| Static RAM sections | 40.54 KiB |
| Heap capacity | 463.46 KiB |

The final result was an ELF32 ARM EABI5 image with resolved symbols and Pico 2
metadata. The July runtime is larger than the April control, so byte-for-byte
equality is not expected.

No device was programmed during this build-system investigation.

## Local SwiftPM Extensions

The functional SwiftPM patch adds or corrects:

- preservation of `ExternalBuildCommand.environment`;
- declared external-command inputs and outputs;
- explicit host-tool and producer/consumer target dependencies;
- package and post-product command placement;
- materialized product path and external output-directory context;
- typed access to a raw external library archive;
- typed access to a producer-declared auxiliary output;
- destination SDK-root injection into external commands;
- separate host and destination product paths;
- destination-only bare-metal settings for host tool safety;
- custom toolset path escaping;
- header-only target handling; and
- Linux runtime-library-path plumbing for custom tasks.

The SwiftBuild patch makes the `none` platform inherit the generic Unix
specification and stops injecting a placeholder SDKROOT/sysroot when a
bare-metal toolset supplies its own.

The generated CPicoSDK toolset also declares the GNU ARM librarian, avoiding a
fallback to Apple's incompatible `libtool`.

## Recommendations for the Upstream Experiment

The most generally useful changes to recommend are:

1. make inputs, outputs, and producer/consumer edges part of the external
   builder API;
2. support post-product commands with a materialized product and declared
   outputs;
3. expose raw external artifacts without re-archiving them through a host
   librarian;
4. model auxiliary artifacts with a typed selector such as
   `.libraryArchive` and `.declaredOutput(String)` rather than the local
   optional string;
5. pass the resolved destination SDK root to external commands;
6. keep destination settings off host plugin tools;
7. preserve released `Package.resolved` compatibility;
8. handle header-only modules and custom toolset paths correctly; and
9. complete the bare-metal `none` platform's SDKROOT and generic-Unix behavior.

The setup/build distinction should remain. A destination installer must run
before planning; native support belongs before the Swift product; firmware
assembly belongs after it; and flashing should remain an explicit device
operation.

## Remaining Limitations

- The external package task is conservatively launched on each build because
  the staged Swift SDK's contents are not yet modeled as task inputs. Its inner
  CMake/Ninja build is incremental.
- The PR's lockfile encoding differs from released SwiftPM. The launcher
  transaction is a local development workaround, not an upstream solution.
  Preview launches serialize with one another, but the released `build.sh`
  does not participate in that lock; do not run the stable and preview paths
  concurrently in the same checkout.
- The July Embedded Swift runtime uses newer platform mutex/TLS entry points.
  CPicoSDK provides a narrow adapter over its existing Pico implementation,
  but focused physical multicore validation is still required before treating
  this preview as a runtime upgrade.
- A focused SwiftPM PIF test run was blocked by an unrelated July snapshot
  compiler failure while compiling `swift-bootstrap`. Direct builds of
  `PackagePlugin`, `SPMBuildCore`, `SwiftBuildSupport`, and the complete
  `swift-build` product passed, as did the clean CPicoSDK integration build.
