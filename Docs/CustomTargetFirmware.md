# Custom-target firmware prototype

This branch experiments with [SwiftPM PR #10374](https://github.com/swiftlang/swift-package-manager/pull/10374)
and [Swift Build PR #1740](https://github.com/swiftlang/swift-build/pull/1740).
It requires the modified local SwiftPM build, not a released Swift toolchain.

## Current verified state

The firmware plugin now returns two ordered build commands:

1. `--phase sdk` configures CMake and builds the `cpicosdk_sdk` static library.
   Its declared outputs are `CMakeHarness/build/libPicoSDK.a`, `build.ninja`,
   and a successful-build configuration record, `sdk-build.json`.
2. `--phase link` consumes those outputs plus the Swift archive and assets,
   builds application-specific runtime/resource objects, links the firmware,
   and publishes ELF/UF2/BIN/map through `productFiles`.

Both commands belong to the same plugin and share its private working directory.
The link command does not clean or configure CMake. It rejects a missing SDK
build or mismatched configuration rather than silently rebuilding with different
settings. The legacy command plugin retains its existing behavior: omitting
`--phase` runs both stages, and `--clean` applies before SDK compilation only.

The SDK archive privately consumes Pico's interface-library sources; the final
executable receives their compile and link settings without recompiling those
sources. Whole-archive linking preserves startup/vector-table objects, with
section garbage collection still enabled. The harness requires CMake 3.17 or
newer for CMP0099's transitive static-library link properties (the prepared
bundle supplies CMake 3.31.5).

Board/stdio traits are still discovered from the built Swift archive. This is
an explicit staging split, not yet an independent SDK target that can compile
in parallel with Swift. SDK artifacts are internal plugin outputs, not published
products for sharing across packages. SDK headers remain pre-generated.

Verified on October 3, 2026 using the existing prototype SwiftPM and pinned
April embedded compiler, without rebuilding Swift/LLVM or programming hardware:

- All 67 host tests pass, including phase parsing, SDK state validation, and
  memory-map classification of `libPicoSDK.a` members.
- A fresh SwiftPM scratch directory builds and publishes RP2350 firmware with
  sandboxed plugin commands (23.79 seconds, reusing downloaded tools).
- A no-change build takes 1.57 seconds and preserves SDK/ELF/UF2 timestamps.
- A Swift-only edit relinks firmware without recompiling SDK objects or changing
  the SDK archive. An asset-only edit runs resource embedding and linking only.
  Both temporary edits were restored and rebuilt.
- Link-only execution rejects changed stdio settings. A deliberately failed
  SDK configuration removes the success record and prevents a subsequent link.
- A separate RP2040 C smoke archive builds through `--phase all`, including
  boot-stage selection and ELF/UF2 generation, with no embedded resources.

Logs are in `Example/.build/two-step-*.log`; host test results are in
`.build/two-step-host-tests.log`. The cold-build scratch directory is
`Example/.build/two-step-swiftpm`. These are local build-only checks, not runtime
or performance validation on a board. Other boards and Linux remain unverified.

## Previous single-command baseline

The wrapper package is restored by explicit revert commit `5182dd0`; the failed
same-package experiment remains in history as `9152594`.

With the refreshed PR checkouts and the SwiftPM fixes listed below:

- Plain `bash build.sh` from `Example` succeeds from a fresh
  `Example/Firmware/.build` directory, reusing the downloaded SDK bundle.
- The plugin produces and publishes an ARM EABI5 ELF, UF2, BIN, and linker map
  through `productFiles`, with its build-command sandbox enabled. Reporting is
  a separate launcher step using these published files, not plugin internals.
- A no-change rebuild takes 1.70 seconds for the firmware build stage and
  preserves the hashes and modification times of both published files.
- All 60 CPicoSDK host tests pass, including published-artifact size reporting.
- The focused SwiftPM regressions pass: destination-only bare-metal overrides,
  header-only module dependencies, and static versus automatic dependency
  product handling (two parameterized cases).
- The broader PIF/CGen and bare-metal regression selection passes all 57 tests
  across five suites.

Artifacts are in `Example/Firmware/.build/out/Products/Release-none-armv7em/`.
Logs are in `../build-investigation-logs/restored-wrapper-*.log`. No hardware
was programmed. The April embedded compiler still emits package-module and
dependency-scanner compatibility warnings; they do not prevent this build.

SwiftPM's full test bundle has unrelated stale call sites in `BuildTests` and
`SBOMModelTests`. The focused regressions were run with the manifest temporarily
selecting only `SwiftBuildSupportTests`; that manifest edit is not retained.
The missing `productFiles: []` argument in that suite's existing CGen test mock
was updated to match the PR API.

## Reverted local-target experiment

Commit `9152594` moved `Firmware` into `Example/Package.swift`, depending on the
local `Example` target. Commit `5182dd0` explicitly reverts that experiment and
restores `Example/Firmware` and the product dependency. The investigation below
records why the single-package version was not sufficient.

The initial run of `bash build.sh` from `Example` failed with `Build input file cannot be
found` for `libExample.a`. The plugin can find the local static product's
metadata, but a target dependency does not build that product's archive.
The preserved reproducer log is
`../build-investigation-logs/custom-target-missing-archive.log`.

After refreshing both PRs and upstream main on September 28, all local SwiftPM
tools and runtime APIs rebuilt successfully. Running `bash build.sh` with those
tools recognizes the bare-metal triple and reaches ARM compilation, but fails
earlier on missing `ARMClib` and `_CPicoSDK_*` module maps. The retained
header-only module workaround below does not generate these maps with cold
Swift Build outputs; this is not evidence of a new upstream regression. This
run does not reach the archive dependency failure above. Logs are preserved in
`../build-investigation-logs/latest-prs-all-tools.log` and
`../build-investigation-logs/latest-prs-cpicosdk.log`.

The architecture and successful verification below describe the earlier
wrapper-package implementation, before this experiment.

## Reassessment before the revert

The old SwiftPM patches were stashed and tested independently on September 28.
Swift Build has no local source patches beyond merging upstream main into the PR.

- With no SwiftPM patches, the build tries to compile host plugin tools for
  `armv7em-none-macos13.0-eabi`. The destination-only triple override fix is
  still required.
- With only that fix, ARM compilation and generated module maps succeed.
  Building `--target Firmware` fails because the target dependency builds
  `Example.o`, not the `Example` static product's `libExample.a`.
- Building `--product Example` explicitly reaches the archiver, but its input
  list contains nonexistent objects for header-only targets such as `ARMClib`.
  The fix should preserve module-map generation while excluding nonexistent
  link inputs; the old `.packageProduct` workaround is not retained.
- The static dependency-product materialization patch is also not retained:
  it does not address the same-package dependency edge.
- The firmware plugin now uses `productFiles` to publish ELF/UF2 outputs. The
  generated build graph has native file-copy tasks, replacing the two manual
  `COPY_CMD` commands. Publication has not run successfully in this layout.

The intended graph remains `Firmware -> Example static product -> source
targets`. PR #10374 still exposes target dependencies and products from other
packages, not same-package product dependencies. Matching a local product by
its source targets only finds metadata; it does not create a build edge.
Keep that missing capability explicit rather than making arbitrary target
dependencies materialize every matching static product. A two-invocation
launcher would be a temporary workaround, not a single-graph solution, and
would still need the header-only archive-input issue fixed. The explicit revert
restores the wrapper package instead of adding a second build invocation.

A regression test was added for destination-only bare-metal overrides. Running
it is blocked by existing test compilation errors in this PR: a missing
`productFiles` argument in `CGenPIFTests.swift` and an obsolete
`platformConstraint` argument in `SBOMTestModulesGraphHelpers.swift`. Those
unrelated test call sites have not been changed.

Logs under `../build-investigation-logs/`:
`rethink-baseline-demo.log`, `rethink-scoped-demo.log`,
`rethink-explicit-product.log`, and `rethink-scoped-test.log`.
The previous Swift Build output directory was moved to
`../build-investigation-logs/pre-rethink-swiftbuild-out` before the baseline;
the downloaded SDK bundle was retained.

## Build graph

```text
Example static library
  Swift/C sources + PIOASM + AssetCompiler
       |
       v
Firmware custom target / PicoFirmware plugin
  PicoFirmwareBuildTool
    sdk command:
      detect board and stdio traits from archive
      select embedded Swift runtime archives
      configure CMake and build libPicoSDK.a
       |
       v
    link command:
    link firmware, embed assets, generate ELF/UF2/BIN/map
       |
       v
productFiles publishes ELF/UF2/BIN/map to PRODUCTS_DIR
       |
       v
build.sh reports artifact sizes/memory use, then optionally flashes
```

The finalizer is now a build-tool executable shared by the new build plugin and
the existing `finalize-rp2xxx-binary` command plugin. The build plugin declares
the application archive, tool binaries, CMake harness, and SDK configuration as
SDK-command inputs. The linker also depends on SDK-command outputs and asset
contents. Resource paths are passed to both commands so adding/removing an asset
updates the CMake graph, while changing only asset contents does not directly
invalidate the SDK command. ELF, UF2, BIN, and the linker map are explicit outputs. CMake's build directory is
retained between runs; the legacy command still cleans unless `--incremental`
is supplied.

`Example/Firmware` is a small outer package so its custom target can depend on
the **Example product**, not just the Example source target. PR #10374 does not
yet provide same-package product dependencies to express that relationship.
Build `--target Firmware` explicitly: the prototype does not include otherwise
unreferenced custom targets in its default aggregate build.

The manifests do not declare an Apple platform minimum. Build commands pass
`-Xswiftc -Xfrontend -Xswiftc -disable-availability-checking` so host build tools
can use modern Foundation and Swift Regex APIs without imposing a macOS floor
on the firmware packages. This suppresses compiler availability diagnostics;
the host running those tools must still support their APIs (macOS 13 or newer).
The firmware still targets bare-metal ARM.

## Local setup

Checkouts are siblings under `src/swift-contrib`:

- `CPicoSDK`, based on `a1aa863645122f9a985a0b6de4f63c5e04853a73`.
- `swiftpm-pr-10374`, PR head `3f825ab250c7fbc531ce1c161261a108ea44c7e4`,
  including upstream main `24a8a7b071d9fc92540ce464f648bd01f91428cd`.
- `swift-build-pr-1740`, PR head `b96a0096dc0c9dafed112ab4ed2b2961adb0633d`,
  merged with upstream main `96738a4ea719569905422fab7ef65c6d1aa68bee`.
  The local merge is `09f7ca75`. Both remote PR heads and main branches were
  checked on September 28, 2026.
- `swift-build` points to the PR #1740 checkout. Other local SwiftPM dependency
  paths point to the existing SwiftCompiler dependency checkouts.

With `SWIFTCI_USE_LOCAL_DEPS=1`, build these products in the SwiftPM checkout:
`swift-build`, `swift-package`, `swift-test`, `swiftpm-testing-helper`,
`PackageDescription`, and `PackagePlugin`. The local build uses Xcode's host
Swift compiler. `utils/swiftpm-experimental.sh` supplies that build's manifest
and plugin libraries and routes nested `swift package` calls to it too.

The existing SwiftCompiler checkout is not modified by this experiment.

## Run

Start with an installed Swift toolchain and swiftly. From `Example`:

```sh
bash build.sh
```

Preparation writes `Example/.swift-version` from `env.json`. The generated
`configure_rp2xxx_build` helper runs `swiftly install`, then resolves the selected
compiler and configures automatic stdio. The generated
toolset uses a stable `generated/swift-toolchain` link in the preparation
plugin's output directory, bound by that helper after installation; it does not
capture the previously selected Swift compiler. Manual build scripts must call
the helper after sourcing the preparation script and before building. The
legacy finalizer shares the same generated stdio selector.

`SWIFTPM_CHECKOUT` can select another build of the patched SwiftPM.
`CPICOSDK_SWIFT_EXEC` can select an explicit embedded `swiftc`. It affects the
destination toolset and runtime selection, not host manifest/plugin compilation.
`PICO_SDK_BUNDLE_PATH` can reuse an existing SDK bundle; in that case pass
`--disable-install-dependencies` to avoid downloading tools again.

The launcher preserves the original straight-line preparation/build/flash
structure, using the experimental SwiftPM wrapper where required. It runs one
Swift Build invocation for `Firmware`, then calls the generated `memory_map_report`
shell function. Reporting and flashing share the generated
`firmware_products_directory` helper, which assumes this experiment's wrapper
layout: `Firmware/.build/out/Products/<Debug|Release>-none-<architecture>`.
There is no extra build invocation to query the path and no fallback to stale
artifacts in the native build directory. The report command still uses the
experimental SwiftPM wrapper to run `memory-map-report --artifact-stats`.
Reporting runs even on a no-change build; a reporting failure remains nonfatal.
Flashing remains explicit (`--flash`); ordinary builds do not access a device.

Host tests, from the repository root:

```sh
CPICOSDK_HOST_TESTS=1 sh utils/swiftpm-experimental.sh test --build-system swiftbuild \
  -Xswiftc -Xfrontend -Xswiftc -disable-availability-checking
```

After generating `Example/.env_prep`, check launcher ordering and the generated
helpers without installing toolchains or accessing hardware:

```sh
bash Tests/BuildPreparation/verify.sh
```

## Required local upstream patches

Three SwiftPM fixes are applied in the local checkout:

1. `SwiftBuildSystem.swift` qualifies bare-metal architecture, vendor, and
   environment overrides with `__destination_platform=YES`, keeping ARM settings
   out of macOS host plugin-tool builds.
2. `PackagePIFProjectBuilder+Products.swift` materializes explicitly static
   dependency products when archive materialization is enabled. This is needed
   now that `Example` is a product from a dependency of the wrapper package.
   Automatic dependency products remain product groups.
3. Header-only Clang modules retain their ordinary targets and module-map
   generation, but consumers add them as build-only dependencies rather than
   nonexistent object-file link inputs. The old `.packageProduct` replacement
   workaround is not applied. Modules with sources, plugins, or resources are
   not classified as header-only by this fix.

Swift Build no longer needs the local `none` domain patch: upstream main
provides triple recognition, generic-Unix spec inheritance, and a bare-metal
linker spec under `SWBUniversalPlatform`. The April embedded compiler remains
pinned, but the launcher uses the locally rebuilt SwiftPM and Swift Build,
not the SwiftPM bundled with that April toolchain.

The CPicoSDK toolset now specifies the ARM librarian and an explicit newlib
header search path. Swift Build's placeholder bare-metal SDK otherwise wins
over the toolset's `-sdk` argument.

These patches remain local experiments, separate from output publication
through `productFiles`, and need upstream review before contribution.

## Original wrapper verification

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
- Artifact summaries, memory reports, and flashing are not build-plugin work.
  The launcher requests the existing reporting command after the build finishes;
  the build tool has no report-tool dependency or flashing code.
- The wrapper is a macOS development helper. Linux, other Pico boards, device
  flashing, and the existing device-test launcher need separate validation.
- Treat downloaded SDK/toolchain bundles as immutable versioned inputs. The
  plugin does not enumerate every source inside them for Swift Build invalidation.
- IDE generation retains the original launcher's defaults. Its native-build
  artifact paths do not describe the new firmware products directory; use
  `--disable-vscode-settings --disable-sourcekit-lsp-settings` to leave existing
  IDE files untouched while testing this experiment.
