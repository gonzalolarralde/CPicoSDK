# CPicoSDK external-build Swift SDK

These files are templates and metadata for the relocatable Swift SDK used by
CPicoSDK's SwiftPM external-build experiment. They live in CPicoSDK rather than
in an application such as `Example`, because the destination, Pico tools, and
matching Embedded Swift runtime are dependency-owned build infrastructure.

The SDK is created by the `PrepareEnvironment` command plugin. Applications do
not invoke a separate setup script and do not copy these templates. A normal
Example build starts with the small preparation call in `Example/build.sh`:

```sh
SWIFTPM_BIN_DIR=/absolute/path/to/pr-build/Products/Debug \
  ./Example/build.sh
```

The preparation plugin:

1. downloads or reuses the Pico SDK, ARM toolchain, CMake, Ninja, picotool, and
   OpenOCD payload;
2. reads the dependency-owned compiler pin from `swift-toolchain.txt` and
   locates or installs that Swift snapshot;
3. copies the matching Embedded Swift modules, runtime archives, Swift shims,
   and Clang resources;
4. renders the artifact-bundle metadata and its `toolsets/rp2xxx.json` from
   these templates;
5. normalizes links that point within the bundle and rejects broken or escaping
   links; and
6. exports `CPICOSDK_SWIFT_SDKS_PATH` and `CPICOSDK_SWIFT_SDK_ID` in the
   generated preparation environment.

The generated payload is host-specific and lives below the consuming package's
build directory. No downloaded SDK or tool binary is checked into the
repository. A complete existing stage is validated and reused on later builds.
The consumer package does not need a generated root `toolset.json`, and
preparation does not mutate its `.swift-version` or write legacy SourceKit
settings.

The bundle exposes one SDK ID per platform so callers do not need a separate
target-triple argument:

- `cpicosdk-rp2350`
- `cpicosdk-rp2040`

The selected external builder receives the resolved sysroot in `SWIFT_SDK`. It
can walk up from that path to `cpicosdk-layout.json` and resolve the remaining
paths relative to the artifact-bundle root.

SwiftPM must know the destination before it plans the firmware graph, which is
why preparation remains a small command-plugin call before `swift-build`.
Native support and firmware finalization are different: they are scheduled as
declared external tasks inside the build graph, including the automatic
post-product finalizer. Flashing remains an explicit `FlashFirmware` command
plugin action.

This branch intentionally targets the tools-version 6.5 APIs from
[swift-package-manager#10198](https://github.com/swiftlang/swift-package-manager/pull/10198).
Released SwiftPM is not supported. `SWIFTPM_BIN_DIR` must contain sibling
patched `swift-package` and `swift-build` executables so manifest/plugin loading
and build execution use the same development implementation.
