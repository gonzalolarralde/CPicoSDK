# SwiftPM External Packages Investigation

## Scope

This document records an end-to-end evaluation of
[swift-package-manager#10198](https://github.com/swiftlang/swift-package-manager/pull/10198)
against the user-facing `Example` build. The goal is to make SwiftPM own as
much of the firmware build graph as its external-build-system model naturally
allows and to make that experiment the branch's one canonical Example flow.
Compatibility with released SwiftPM is intentionally out of scope.

The evaluated revisions were:

- SwiftPM `524b58aca7cc10609d828fcb1d01f4451f5bb61c`
- its companion
  [swift-build#1493](https://github.com/swiftlang/swift-build/pull/1493) at
  `801cb538e676908033d55d8549053dba2556fe1c`
- Swift development snapshot `2026-07-28`

Nothing was pushed to either upstream repository. The SwiftPM and SwiftBuild
changes described below are local experiments only.

## Outcome

The completed preview is a single SwiftPM build graph:

```text
PrepareEnvironment command plugin
    -> downloaded/reused Pico tool payload
    -> staged relocatable CPico Swift SDK
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

`Example/build.sh` makes one small preparation-plugin call followed by one
`swift-build --product Example` request. It does not prime an external target
or call the finalizer itself. SwiftPM owns the producer/consumer edges and the
final six outputs. An explicit final phase invokes the `FlashFirmware` command
plugin only when `--flash` is requested.

The build implementation is dependency-owned. CPicoSDK's root
`Package.swift` declares `CPicoNative`, the external native builder,
the post-product builder, and their private host tools. Of that implementation,
it exports only the `CPicoFirmwareBuilder` plugin to clients. The Example
manifest attaches that plugin to its static-library target and keeps
its application-specific choices in `Example/cpicosdk-build.json`; it contains
no copied external package, plugin, adapter, or builder implementation.

Both root and Example `Package.swift` files are canonical tools-version 6.5
manifests. The former released-SwiftPM path, version-gated manifests, separate
setup script, external-preview launcher, and legacy `FinalizeBinary` command
plugin have been removed from this experiment.

## Where Preparation and Finalization Went

### Preparation became destination provisioning

Preparation has two responsibilities:

1. obtain the Pico SDK, GNU ARM tools, CMake, Ninja, picotool, and OpenOCD; and
2. write destination metadata used by SwiftPM to plan a bare-metal build.

Those operations cannot be a normal target build command because SwiftPM needs
the compiler resources, sysroot, toolset, and target triple before it can
construct the target graph. `Example/build.sh` therefore starts with one
`prepare-rp2xxx-environment` command-plugin call. The plugin downloads or
reuses the payload, stages and validates a relocatable Swift SDK artifact
bundle, and writes the environment selected by the following `swift-build`
request. Its templates live under `SwiftSDK/ExternalPreviewSDK`, not in the
consuming application's sources.

The staged SDK includes:

- both RP2040 and RP2350 Swift SDK descriptors;
- the Pico SDK and host/ARM tools;
- the newlib overlay and `toolsets/rp2xxx.json` destination toolset;
- the selected compiler's target-specific Embedded Swift modules and static
  runtime archives; and
- the compiler's matching Swift shims and Clang resource headers.

The compiler snapshot is pinned by CPicoSDK in
`SwiftSDK/ExternalPreviewSDK/swift-toolchain.txt`. The stager records and
validates the selected compiler so it fails rather than mixing snapshots.
Preparation does not generate a root `toolset.json`, mutate the consumer's
`.swift-version`, or write legacy SourceKit settings.

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

## Checked-In Integration

The ownership boundary is visible in the repository layout:

| Owner | Build-system files |
| --- | --- |
| CPicoSDK | Canonical `Package.swift` and its template, `External/CPicoNativeSupport`, `Plugins/CPicoNativeBuilderPlugin`, `Plugins/CPicoFirmwareFinalizerPlugin`, `Plugins/FlashFirmwarePlugin`, `Plugins/PrepareEnvironmentPlugin`, `Sources/CPicoExternalBuildSupport`, `Sources/CPicoNativeBuilder`, `Sources/CPicoFirmwareFinalizerAdapter`, `Sources/CPicoSDKEnvironmentTool`, `Sources/CPicoFlashTool`, `SwiftSDK/ExternalPreviewSDK`, and `Support/FirmwareFinalizer/CMakeHarness` |
| Consumer | Canonical `Example/Package.swift`, `Example/cpicosdk-build.json`, and the small `Example/build.sh` launcher |

The consumer therefore selects policy and a firmware product without carrying
a private copy of CPicoSDK's build implementation.

### Canonical experimental manifests

The root `Package.swift` uses the PR's `.externalSource`,
`.externalLibrary`, and `.externalBuilder` declarations. Its ordinary
`CPicoSDK` library product consumes `CPicoNativeSupport`, while its exported
`CPicoFirmwareBuilder` plugin names the private post-product plugin target.
The native and finalizer plugins, their adapters, and their shared resolver are
all private implementation targets in the CPicoSDK package.

`Example/Package.swift` is also tools-version 6.5. Its experiment-specific work
is limited to attaching `.plugin(name: "CPicoFirmwareBuilder", package:
"CPicoSDK")` to the Example target. The same target continues to attach the
existing PIO and asset plugins from CPicoSDK.

`Example/cpicosdk-build.json` is the consumer-owned configuration boundary. It
selects the board combination, environment overrides such as stack sizes, and
incremental mode. The static product and build configuration come from the
manifest and launcher. The finalizer requires an unambiguous selected static
product.

The manifest intentionally describes Pico 2/RP2350. The launcher fixes the SDK
and combination to that same board so an ambient override cannot mix RP2040
native code with RP2350 Swift traits.

Released SwiftPM cannot parse these manifests; this branch does not provide a
fallback manifest.

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

The selected configuration path is forwarded by the consumer launcher, so
preparation, the dependency-owned native builder, and the post-product builder
resolve the same board and environment choices without copying implementation
into the consumer.

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

On an identical build after the graph was current, neither the external native
command nor the post-product finalizer ran. The package task is incremental
when it declares outputs. The native wrapper also refreshes those outputs'
timestamps after a successful CMake/Ninja no-op; without that acknowledgement,
a touched input would leave the unchanged archive older forever and reschedule
the wrapper on every later build.

### Launcher

The sole Example launcher is bootstrap glue, not a build pipeline. It:

- reads user-overridable configuration at the top of the script;
- requires `SWIFTPM_BIN_DIR` to contain sibling patched `swift-package` and
  `swift-build` products;
- selects the compiler pinned by
  `SwiftSDK/ExternalPreviewSDK/swift-toolchain.txt`;
- invokes the preparation plugin and sources its generated environment;
- makes one product build request, whose graph contains native support and the
  post-product finalizer; and
- invokes the explicit `FlashFirmware` command plugin only for `--flash`.

Flashing remains an explicit `--flash` action and is never part of a normal
build. Device discovery is bounded to 60 seconds by default;
`CPICOSDK_FLASH_WAIT_SECONDS` changes that limit, and
`CPICOSDK_PICOTOOL_SERIAL` selects a specific device when needed.

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
  --product swift-package
swiftly run swift build +main-snapshot-2026-07-28 \
  --build-system swiftbuild \
  --scratch-path .build-pr10198 \
  --product swift-build
```

Build the Example. The preparation phase stages or reuses the destination SDK:

```bash
cd /absolute/path/to/CPicoSDK/Example
SWIFTPM_BIN_DIR=~/src/swiftpm-external-preview/swift-package-manager/.build-pr10198/out/Products/Debug \
  ./build.sh
```

The default output directory is:

```text
Example/.build/out/Products/Release-none-armv7em/
```

It contains `Example.elf`, `Example.uf2`, `Example.bin`, `Example.hex`,
`Example.elf.map`, and `Example.dis`.

`SWIFTPM_SCRATCH_PATH` can select another build directory. The sibling
development products supply the matching manifest and plugin API libraries;
there is no separate API-library copy step in the launcher.

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
An identical incremental request skipped both native CMake/Ninja and the
post-product finalizer. Touching one declared native CMake input scheduled the
native task exactly once; the following identical targeted build skipped it
again. In an earlier compatibility phase, the then-separate released path also
completed and all 56 host tests passed. That historical control path is no
longer retained on this branch. No device was programmed during this
build-system investigation.

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
- custom Swift SDK toolset path escaping;
- header-only target handling; and
- Linux runtime-library-path plumbing for custom tasks.

The SwiftBuild patch makes the `none` platform inherit the generic Unix
specification and stops injecting a placeholder SDKROOT/sysroot when a
bare-metal toolset supplies its own.

The CPicoSDK Swift SDK's `toolsets/rp2xxx.json` also declares the GNU ARM
librarian, avoiding a fallback to Apple's incompatible `libtool`.

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
7. source plugin-tool runtime library paths from the host toolchain, not the
   destination toolchain;
8. keep destination settings off host plugin tools;
9. reject external output names that escape their output directory or denote
   the directory itself;
10. handle header-only modules and custom toolset paths correctly; and
11. complete the bare-metal `none` platform's SDKROOT and generic-Unix behavior.

The preparation/build distinction should remain. Destination provisioning must
run before planning; native support belongs before the Swift product; firmware
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
  `cpicosdk-build.json` through the current plugin API. Consumer launchers must
  export its absolute path as `CPICOSDK_BUILD_CONFIGURATION`; relative paths
  are intentionally not part of the documented contract because the native
  and post-product plugin contexts have different roots.
- The staged Swift SDK's contents are not yet modeled as external-task inputs.
  Normal identical builds are incremental, but replacing files in an existing
  staged SDK at the same path may require explicitly refreshing the build.
- The prototype validates external output names as relative paths but still
  needs to reject `.` and escaping `..` paths before it is suitable upstream.
- The PR's lockfile encoding differs from released SwiftPM. This branch accepts
  that prototype encoding because it has no released-SwiftPM compatibility
  path; an upstream implementation still needs a migration and compatibility
  design.
- The July Embedded Swift runtime uses newer platform mutex/TLS entry points.
  CPicoSDK provides a narrow adapter over its existing Pico implementation,
  but focused physical multicore validation is still required before treating
  this preview as a runtime upgrade.
- A focused SwiftPM PIF test run was blocked by an unrelated July snapshot
  compiler failure while compiling `swift-bootstrap`. Direct builds of
  `PackagePlugin`, `SPMBuildCore`, `SwiftBuildSupport`, and the complete
  `swift-build` product passed, as did the clean CPicoSDK integration build.
