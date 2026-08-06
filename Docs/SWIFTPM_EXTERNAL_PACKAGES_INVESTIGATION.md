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

The build implementation is dependency-owned. CPicoSDK's root
`Package@swift-6.5.swift` declares `CPicoNative`, the external native builder,
the post-product builder, and their private host tools. Of that implementation,
it exports only the `CPicoFirmwareBuilder` plugin to clients. The Example
preview manifest attaches that plugin to its static-library target and keeps
its application-specific choices in `Example/cpicosdk-build.json`; it contains
no copied external package, plugin, adapter, or builder implementation.

The established `Example/build.sh` remains the default released-toolchain
path. The preview is isolated in version-gated manifests and the external
preview launcher.

## Where Preparation and Finalization Went

### Preparation became destination provisioning

The old preparation command had two different responsibilities:

1. obtain the Pico SDK, GNU ARM tools, CMake, Ninja, picotool, and OpenOCD; and
2. write destination metadata used by SwiftPM to plan a bare-metal build.

Those operations cannot be a normal target build command because SwiftPM needs
the compiler resources, sysroot, toolset, and target triple before it can
construct the target graph. The preview therefore runs preparation once from
CPicoSDK's root `setup-external-preview-sdk.sh` and publishes the result as a
relocatable Swift SDK artifact bundle. Its templates live under
`SwiftSDK/ExternalPreviewSDK`, not in the consuming Example package.

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
`SwiftSDK/ExternalPreviewSDK/swift-toolchain.txt`. The launcher compares the
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

The ownership boundary is visible in the repository layout:

| Owner | Preview files |
| --- | --- |
| CPicoSDK | `Package@swift-6.5.swift` and its template, `External/CPicoNativeSupport`, `Plugins/CPicoNativeBuilderPlugin`, `Plugins/CPicoFirmwareFinalizerPlugin`, `Sources/CPicoExternalBuildSupport`, `Sources/CPicoNativeBuilder`, `Sources/CPicoFirmwareFinalizerAdapter`, `SwiftSDK/ExternalPreviewSDK`, and root `setup-external-preview-sdk.sh` |
| Consumer | `Example/Package@swift-6.5.swift`, `Example/cpicosdk-build.json`, and the preview launcher used to select the development SwiftPM executable |

The consumer therefore selects policy and a firmware product without carrying
a private copy of CPicoSDK's build implementation.

### Version-gated manifest

The root `Package@swift-6.5.swift` uses the PR's `.externalSource`,
`.externalLibrary`, and `.externalBuilder` declarations. Its ordinary
`CPicoSDK` library product consumes `CPicoNativeSupport`, while its exported
`CPicoFirmwareBuilder` plugin names the private post-product plugin target.
The native and finalizer plugins, their adapters, and their shared resolver are
all private implementation targets in the CPicoSDK package.

`Example/Package@swift-6.5.swift` remains version-gated because released
SwiftPM cannot parse the experimental plugin capability. Its preview-specific
work is limited to attaching `.plugin(name: "CPicoFirmwareBuilder", package:
"CPicoSDK")` to the Example target. The same target continues to attach the
existing PIO and asset plugins from CPicoSDK.

`Example/cpicosdk-build.json` is the consumer-owned configuration boundary. It
selects the product name, board combination, platform triple, build mode,
stdio transport, stack sizes, and incremental mode. The finalizer can infer a
product only when the client package has exactly one static library; an
explicit `productName` keeps multi-product packages unambiguous.

The manifest intentionally describes Pico 2/RP2350. The launcher fixes the SDK
and combination to that same board so an ambient override cannot mix RP2040
native code with RP2350 Swift traits.

Released SwiftPM selects `Package.swift` and does not parse the preview-only
API.

### External native builder

The root package's private `CPicoNativeBuilderPlugin` declares CPicoSDK's
external source, the consumer configuration, its native inputs, and the
`pioasm-package-path.txt` output. `CPicoNativeBuilder` then:

1. resolves the selected CPicoSDK configuration and installed Swift SDK;
2. builds Pico's C++ `pioasm` as a host tool in an SDK-keyed cache;
3. configures the external CMake package with the SDK's ARM toolchain;
4. selects the requested stdio transport; and
5. produces `libCPicoNativeSupport.a` at the external product's declared path.

The child environment is the resolver's allowlisted environment, with
destination deployment variables removed for macOS host-tool compilation.
CMake/Ninja provide incremental work inside the external command.

The selected configuration path is forwarded by the consumer launcher, so the
dependency-owned native builder and post-product builder resolve the same
board and stdio choices without copying configuration into CPicoSDK.

### Post-product builder

The exported `CPicoFirmwareBuilder` plugin product resolves to CPicoSDK's
private `CPicoFirmwareFinalizerPlugin`. When invoked from Example, that plugin
finds CPicoSDK and its transitive `CPicoNative` external package, selects the
consumer's configured static product, and declares:

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

This cross-package layout also exposed a product-filtering gap in the PR.
SwiftPM normally loads only targets needed by the products selected from a
dependency. That filtering removed the private plugin and tool targets used by
CPicoSDK's inline external package, even though the exported CPicoSDK product
required the external archive. The local patch now retains local plugin
targets referenced by external packages, plus their transitive local target
and plugin dependencies. Plugin product names are resolved to their underlying
target names before computing that closure.

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
cd /absolute/path/to/CPicoSDK
./setup-external-preview-sdk.sh --stage-only

cd Example
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

The dependency-owned layout was also validated with a clean one-request build.
An identical incremental request kept native CMake/Ninja work incremental and
skipped the post-product finalizer because its declared inputs and all six
outputs were current. The released `Example/build.sh` path still completed,
and all 56 host tests passed. No device was programmed during this build-system
investigation.

## Local SwiftPM Extensions

The functional SwiftPM patch adds or corrects:

- preservation of `ExternalBuildCommand.environment`;
- declared external-command inputs and outputs;
- explicit host-tool and producer/consumer target dependencies;
- retention of private external-builder plugin/tool targets after dependency
  product filtering;
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
2. include external-package plugin targets and their private dependency closure
   when applying dependency product filters;
3. support post-product commands with a materialized product and declared
   outputs;
4. expose raw external artifacts without re-archiving them through a host
   librarian;
5. model auxiliary artifacts with a typed selector such as
   `.libraryArchive` and `.declaredOutput(String)` rather than the local
   optional string;
6. pass the resolved destination SDK root to external commands;
7. keep destination settings off host plugin tools;
8. preserve released `Package.resolved` compatibility;
9. handle header-only modules and custom toolset paths correctly; and
10. complete the bare-metal `none` platform's SDKROOT and generic-Unix behavior.

The setup/build distinction should remain. A destination installer must run
before planning; native support belongs before the Swift product; firmware
assembly belongs after it; and flashing should remain an explicit device
operation.

## Remaining Limitations

- The dependency product-filtering adjustment is deliberately narrow to this
  experiment. It treats private plugins referenced by every inline external
  package as additional roots and follows their local target/plugin
  dependencies, but it does not yet preserve third-party packages referenced
  through `.product` dependencies. A general upstream implementation should
  make selected external products part of manifest/package-graph filtering and
  cover aliases, helper targets, and external tool dependencies with graph
  tests.
- The native external builder cannot discover a consumer-root
  `cpicosdk-build.json` through the current plugin API. Preview launchers must
  export its absolute path as `CPICOSDK_BUILD_CONFIGURATION`; relative paths
  are intentionally not part of the documented contract because the native
  and post-product plugin contexts have different roots.
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
