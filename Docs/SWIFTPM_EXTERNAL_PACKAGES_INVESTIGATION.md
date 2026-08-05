# SwiftPM External Packages Investigation

## Scope

This document records an evaluation of
[swift-package-manager#10198](https://github.com/swiftlang/swift-package-manager/pull/10198)
against the user-facing `Example` build. The goal was to determine which parts
of `Example/build.sh` and the finalization command plugin could become ordinary
build-graph work, while preserving the existing build for users of released
Swift toolchains.

The revisions evaluated were:

- SwiftPM `524b58aca7cc10609d828fcb1d01f4451f5bb61c`
- its companion
  [swift-build#1493](https://github.com/swiftlang/swift-build/pull/1493) at
  `801cb538e676908033d55d8549053dba2556fe1c`
- Swift development snapshot `2026-07-28`
- the CPicoSDK Example's pinned Swift snapshot `2026-04-27` for the control
  build

Nothing was pushed to either upstream repository. All changes made to those
checkouts were local experiments.

## Result

The PR is a strong fit for one substantial **pre-Swift** phase: building a
reusable archive containing nearly all Pico SDK native objects. It is not yet a
fit for CPicoSDK's **post-Swift** final link or final artifact generation.

The current maximum useful split is:

```text
external builder (pre-Swift)
  -> libCPicoNativeSupport.a (99 Pico-native objects)

native SwiftPM build
  -> libExample.a

product finalization (post-Swift; existing command today)
  -> product metadata + boot2 + linker script + assets
  -> link libCPicoNativeSupport.a + libExample.a + Swift archives
  -> ELF + UF2 + BIN + HEX + map
```

The native-archive split was built through to valid final artifacts. It cannot
yet be wired transparently through the PR because the external artifact's
resolved path is not exposed to a downstream plugin, and the PR has no product
post-build command or declared final-artifact model.

The real archive was also produced by a PR #10198 external-builder target, not
only by a standalone CMake experiment. That proves the proposed pre-Swift role
uses the new API successfully. Because of prototype ordering defects, the proof
requires separate commands to build the plugin tool and then the external
target; it does not yet work as a clean one-command consumer build.

The default `Example/build.sh` remains the supported path. It still builds the
same way with a released toolchain.

## Baseline

`Example/Package.swift` was first changed to use the local package at `../`.
The unchanged build pipeline then completed with the pinned April toolchain:

```text
./build.sh
  -> prepare-rp2xxx-environment
  -> swift build --build-system native
  -> finalize-rp2xxx-binary
```

Baseline artifacts:

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `libExample.a` | 2,297,762 | `b144f2d00a8132e582e5956161b9ae62a9a812855cfc3710159aef99360edc18` |
| `Example.elf` | 1,815,416 | `edfc976fadfe382d834ec89103598b5852ed743260ddd391049382516288cf0e` |
| `Example.uf2` | 641,536 | `8046fc6838721a133fef799abb19ca5fb77f30022edc01bcec0e1ecfbb4e56ec` |
| `Example.bin` | 320,292 | `06b6367f287f663ab54a7aaa2eeec984448abe73ba926e0960cb024a590f3998` |
| `Example.hex` | 900,978 | `b5cda9126bf412dfa4de8f63073b13eb03bd9b81217aa3b4a0d469926c2933dc` |
| `Example.elf.map` | 1,559,219 | `56da35fc26e040723e153e977d8fbff683413148fa441d9ce92e1b6f4ea8d314` |

The memory report showed 292.35 KiB of flash, 43.31 KiB of static RAM, and
460.68 KiB of heap capacity. `picotool` identified the result as an RP2350 ARM
Secure image for `pico2`, built with Pico SDK 2.2.0 and boot2 `w25q080`.

The baseline also exposed a pre-existing shell bug caused by this checkout's
spaces: unquoted configuration, toolset, and triple values in `build.sh` were
split into multiple arguments. Those arguments are now quoted.

After adding the explicit librarian to the generated toolset, the complete
released/native pipeline was run again. The ELF, UF2, BIN, HEX, and map digests
matched the control values above exactly, as did the memory report and
`picotool` metadata. The intermediate static archive digest changed after its
host tools and generated sources were rebuilt, but it finalized to the same
device image.

## What PR #10198 Adds

The prototype adds:

- `.externalSource(path:)` package dependencies
- inline external `Package` declarations in `externals:`
- `.externalLibrary` targets
- `.externalBuilder` plugin capability
- `ExternalBuilderPlugin.createExternalBuildCommand(context:)`
- build-time configuration, platform, architecture, triple component, and SDK
  environment values

An external builder is represented as a custom task on an aggregate target.
Its output library is currently assumed to be:

```text
<plugin-output>/<configuration><effective-platform>/lib<Target>.a
```

The command is always out of date, has no declared inputs or outputs, and must
implement its own incremental cache. The prototype currently runs only through
the SwiftBuild/PIF backend; the native build backend does not implement this
model.

This is an external **dependency builder**, not a general before/after build
hook API.

## Fit Against the Example Pipeline

| Existing phase | Fit | Finding |
| --- | --- | --- |
| Environment preparation and downloads | Possible, but weak | Moving host setup and mutable downloads into every external build would make graph behavior less predictable. Keep preparation explicit for now. |
| PIO and asset source generation | Existing API is better | These already have declared build-tool plugin inputs and outputs. They were intentionally not migrated. |
| Swift application compilation | Blocked in SwiftBuild | The backend still mixes host/plugin and destination settings for this bare-metal graph. The released April backend also predates bare-metal platform mapping. |
| Pico native support compilation | Strong prebuild fit | A 99-object reusable archive was built successfully. This is the best use of the PR. |
| Final native link | Needs post-build | It depends on the completed `libExample.a`, trait symbols, optional Swift archives, resources, and product identity. An external builder runs too early. |
| ELF/UF2/BIN/HEX/map emission | Needs declared product outputs | Side effects from an always-out-of-date prebuild command would not be a sound artifact model. |
| Flashing | Not build graph work | This should remain an explicit user action. |

## Reusable Pico Native Archive Proof

A CMake proof built `libCPicoNativeSupport.a` from the existing Pico target
graph. Product-specific `pico_standard_binary_info` was deliberately excluded.
The archive contained 99 members, including `runtime_coprocessors.c`, runtime,
hardware, stdio, and TinyUSB objects:

```text
size:    2,030,768 bytes
sha256:  62baeeb6ab723c0a5c0049d55ef9e6300b91bd49d0286397f1c9146b78f85535
members: 99
```

The finalizer proof then:

1. prevented the Pico interface graph from compiling the same propagated
   sources again;
2. compiled only `standard_binary_info.c` as the final product-specific Pico
   source;
3. whole-archived `libCPicoNativeSupport.a`, which is required so CPicoSDK's
   strong coprocessor initialization override wins over the Pico SDK weak
   definition;
4. preserved the existing boot2, linker script, stack layout, link wrappers,
   `.codeasset` embedding, and extra Swift archive logic; and
5. generated ELF, UF2, BIN, HEX, and map outputs.

The proof produced no undefined symbols and no duplicate Pico SDK objects.
`picotool` reported the correct product name (`Example`), version (`0.1`),
board (`pico2`), boot2 (`w25q080`), SDK (`2.2.0`), and RP2350 ARM Secure image
type. Its UF2 remained 641,536 bytes. The ELF was 1,815,304 bytes, 112 bytes
smaller than the control ELF; the binary payload changed by 24 bytes because
of layout/padding, not because metadata or required sections were missing.

This proves that native Pico compilation can move earlier. It does not by
itself make the external archive discoverable by CPicoSDK's later command
plugin.

The PR-driven version produced the same 99 ARM ELF members at its external
plugin output location:

```text
sha256: 5e0fbd9c9537758dd0955517fd945a7b9a0a277bb37b580dc25b9de669da8275
```

That exact PR-produced archive was passed to the finalizer adapter. It yielded
an ELF32 ARM soft-float executable with entry point `0x1000014d`, no undefined
globals, and a valid RP2350 ARM Secure UF2. `picotool` reported SDK 2.2.0 and
USB, RTT, and UART features. The UF2 digest matched the standalone archive-split
proof:

```text
ELF sha256: f466d196930eb74de7c7ce01a005d40d0d0b7ad8b77e0a184b07d78a4f74bfc8
UF2 sha256: 197938558ae0656f2af5413fd978c0d424d0a215a4fcfdaf5ca5f6ae0b28f8a8
```

## SwiftBuild Compatibility Findings

### Bare-metal platform mapping

The April 27 SwiftBuild backend fails before planning with:

```text
unable to find a single platform name for triple 'armv7em-none-none-eabi'
```

The companion swift-build checkout already contains upstream commit
`aefd6fcbba284bc24b1dcdf68eb5debe69a77055` ("Add missing triple to platform
mapping for baremetal"). No PR patch is needed for that first failure when a
post-May backend is used.

### A librarian must be declared

SwiftBuild asks the selected toolset for an archive tool. Without one it falls
back to Apple's `libtool`, whose interface and output are wrong for the ARM
destination. CPicoSDK now emits this additional toolset entry:

```json
"librarian": {
  "path": "<pico-toolchain>/bin/arm-none-eabi-ar"
}
```

The native backend accepts this entry, so it is a safe compatibility
improvement even before the rest of SwiftBuild's bare-metal support is ready.

### Host and destination settings still leak

After platform lookup, path quoting, and librarian selection are addressed,
the real Example gets far enough to construct and start tasks. It then tries to
compile host-side plugin tools such as `pioasm-swift` as the ARM destination and
constructs a target resembling `armv7em-none-macos12.0-eabi`. Host Foundation
and the embedded destination standard library cannot both satisfy that command.

This is not specific to the external-packages feature; it is a broader
SwiftBuild bare-metal/tool-plugin separation gap. Removing the existing code
generation plugins only hides part of the issue and is not an acceptable
production migration.

### Generic Unix specs are a viable bare-metal base

A four-line companion swift-build experiment made the `none` specification
domain inherit from `generic-unix`. With no other source changes, both of these
fixtures built successfully:

```swift
func specificationDomains() -> [String: [String]] {
    ["none": ["generic-unix"]]
}
```

- a pure Swift bare-metal static library; and
- a mixed C/module-map plus Swift bare-metal static library.

The resulting compile and relocatable-link commands used the exact
`armv7em-none-none-eabi` triple, GNU-compatible flags, the configured
`arm-none-eabi-ld`, and `arm-none-eabi-ar rcs`. All objects were ELF32 ARM
EABI5. This is a promising small swift-build direction, but it is independent
of PR #10198.

The same patched backend was then run against the full Example graph. Bare-metal
C targets compiled, but host plugin tools did not remain host-only. For example,
`pioasm-swift-product` was labeled with `SDKROOT=macosx` while receiving
`ARCHS=armv7em`, a synthesized `armv7em-none-macos12.0-eabi` triple, embedded
mode and sysroot flags, and the GNU destination linker. It consequently could
not resolve either the embedded Swift module or host Foundation.

That full-graph result confirms that Generic Unix inheritance fixes the
destination compile/link specs, but host tool products still need independent
architecture, SDK, and toolset settings.

## Local Upstream Experiments

### Toolset paths containing spaces

SwiftPM serializes custom toolset paths into the `SWIFT_SDK_TOOLSETS` string
list without escaping each item. The original path was therefore interpreted
as four toolsets (`/Volumes/AI`, `Slop`, `scratch`, and the remaining suffix).

The local one-line fix was:

```swift
buildParameters.customToolsetPaths.map {
    $0.pathStringWithPosixSlashes.shellEscaped()
}
```

After rebuilding the PR, the real toolset path with spaces was accepted and
the build advanced to host/destination compilation. This should be recommended
upstream independently of external packages.

### External command environment

The plugin runtime serializes `ExternalBuildCommand.environment`, but
`PIFBuilder` currently replaces it with the package manager process environment:

```swift
var newEnv: Environment = .current // externalBuildCommand.configuration.environment
```

This drops caller configuration before SwiftBuild adds its own `SWIFT_*`
values. The external-builder conversion should start from the command's
configured environment, matching ordinary build-tool commands, and then append
the required runtime paths.

A minimal external-library fixture confirmed the behavior. Before the local
fix, `FIXTURE_MARKER` was absent while SwiftBuild's injected `SWIFT_*` values
were present. After changing the initializer to use
`externalBuildCommand.configuration.environment`, the builder received the
marker and the expected configuration, architecture, vendor, OS, and SDK
values.

### Clean external builds race their artifact copy

The same fixture exposed a more fundamental ordering bug. From a completely
clean scratch directory, SwiftBuild starts the copy of `libTinyExternal.a`
before the external custom task has created it. The build fails with a missing
file. If that archive is seeded once, the next build runs the builder, copies
and links the archive, and the executable prints `external answer: 42`.

Declaring the expected archive as the custom task's output was not sufficient:
the current PIF models the copy input as a directory-like path with a trailing
slash, so no producer/consumer edge is formed. The PR needs a clean-scratch
integration test and a direct dependency edge from the external task's declared
file output to the copy/link phase. CPicoSDK cannot use an external native
archive reliably until this is fixed.

The real CPico archive exposed an earlier edge in the same family: selecting
the external target on a clean scratch path tries to invoke its builder before
the builder plugin's executable exists. The successful proof first built the
plugin product, then selected the external target. A correct graph needs both
the plugin-tool dependency and the external-artifact dependency; asking users
to prime either one is not acceptable.

### `Package.resolved` compatibility

The PR changes `PackageIdentity` from a string-like value to a compound Codable
value containing package type. As a result, it rewrites each pin's `identity`
from a string to an object. Released SwiftPM then reports that
`Package.resolved` is malformed, and the PR build similarly rejects the old
file.

External packages are local manifest content and do not need to become source
control pins. The lockfile encoding should preserve the existing string form
for ordinary Swift packages and decode both formats during the prototype's
transition. A prototype intended for transparent adoption should not force
lockfile churn that older SwiftPM cannot read.

## Missing API Needed for a Complete Migration

The smallest additions that would let CPicoSDK move the rest of the user-side
pipeline into the build graph are:

1. **Declared external inputs and outputs.** External commands should identify
   the files and directories they consume and produce instead of always
   rebuilding. Those outputs must form producer/consumer edges so clean builds
   cannot race the external command.
2. **Artifact lookup.** Downstream targets and plugins need a public way to
   obtain the resolved URL of an external library instead of reconstructing a
   private plugin-work-directory convention.
3. **A product post-build command.** It should run after a selected product
   archive exists and accept declared outputs such as ELF, UF2, BIN, HEX, and
   map files.
4. **Product context.** The post-build command needs product identity,
   configuration, destination triple/toolset, and paths to the product archive
   and external artifacts.
5. **Environment preservation.** The environment supplied by the plugin must
   survive PIF conversion.
6. **Correct host/destination separation.** Plugin executables and their Swift
   dependencies must be built for the host while application modules use the
   bare-metal destination.
7. **A configurable output model.** The hard-coded
   `lib<Target>.a` convention should be represented by declared artifacts so
   non-library outputs and platform-specific naming are possible.

With those pieces, CPicoSDK could remove the explicit finalization call from
`build.sh`; `swift build` could produce the flashable artifacts as first-class
product outputs.

## Why the Branch Does Not Hide the Gap

It is possible to make an outer host external-builder command recursively run
the old native `swift build` and finalizer, then copy a dummy library to the
path SwiftBuild expects. That would make one command appear to work, but it
would not migrate any phase into a coherent dependency graph. It would also
retain hidden side effects, always rebuild, complicate cancellation and
diagnostics, and make artifact ownership ambiguous.

This investigation intentionally did not adopt that wrapper. The checked-in
path stays predictable, and the measured prebuild design is ready to wire once
the prototype exposes the missing artifact and post-build contracts.

## Recommended Next Step

Keep the current native pipeline as the default. In parallel:

1. propose the path escaping, command-environment, and lockfile compatibility
   fixes to the PR author;
2. propose `none` to Generic Unix specification inheritance to swift-build,
   together with a separate follow-up for scoping destination toolset, arch,
   and triple overrides away from host plugin tools;
3. propose resolved external-artifact lookup and a declared product post-build
   command;
4. retain the 99-object CMake split as the acceptance fixture for those APIs;
5. rerun the control build and compare `picotool`, symbols, memory map, and
   artifact digests after wiring becomes possible; and
6. only then replace the explicit `finalize-rp2xxx-binary` line in
   `Example/build.sh`.
