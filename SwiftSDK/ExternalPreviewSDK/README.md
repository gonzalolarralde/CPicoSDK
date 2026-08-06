# CPicoSDK external-preview Swift SDK

These templates describe a relocatable, locally generated Swift SDK bundle for
the SwiftPM external-package preview. They live in CPicoSDK rather than in a
consumer such as `Example`, because the destination, Pico tools, and matching
Embedded Swift runtime are CPicoSDK build infrastructure. Applications only
need to attach CPicoSDK's exported `CPicoFirmwareBuilder` plugin for this build
machinery. A consumer may provide `cpicosdk-build.json`; its preview launcher
must export that file's absolute path as `CPICOSDK_BUILD_CONFIGURATION` so both
dependency-owned build phases receive it.

The generated payload is host-specific and is created under the CPicoSDK
package root's `.build`; no downloaded SDK or tool binary is stored in the
repository. Each variant records the selected compiler's host triple. Run the
commands below from the CPicoSDK package root.

Render and validate only the metadata:

```sh
./setup-external-preview-sdk.sh --metadata-only
```

This mode validates the selected compiler and both target runtime layouts, but
does not copy the runtime or download the Pico tool payload.

Download and stage the Pico SDK, ARM toolchain, and host tools once:

```sh
./setup-external-preview-sdk.sh --stage-only
```

Install the staged artifact bundle in SwiftPM's shared SDK store:

```sh
./setup-external-preview-sdk.sh --install
```

Select the compiler used by the preview explicitly when needed:

```sh
CPICOSDK_SWIFT=/path/to/toolchain/usr/bin/swift \
  ./setup-external-preview-sdk.sh --stage-only

SWIFTPM_PREVIEW_TOOLCHAIN=main-snapshot-2026-07-28 \
  ./setup-external-preview-sdk.sh --stage-only
```

The setup validates Embedded Swift support for both target triples. It copies
only matching module files and target libraries into `swift-resources`, making
that fallback relocatable and tied to the compiler recorded in
`swift-compiler-version.txt`. RP2040 base support is required; its concurrency
runtime is recorded as an optional capability because current toolchains may
not ship it. RP2350 concurrency support is required by the current Example.

Every complete stage is built in a fresh temporary artifact bundle. Before it
is published, the Swift normalizer rewrites absolute links whose targets are
inside the bundle—such as Darwin CMake and OpenOCD convenience links—and
rejects broken links or any link that escapes the bundle.

The bundle exposes two IDs, each with one target triple so a separate
`--triple` argument is unnecessary:

- `cpicosdk-rp2350`
- `cpicosdk-rp2040`

The external-package prototype still requires the patched `swift-build`; a
released `swift build` cannot parse these experimental manifests. For a
`--stage-only` SDK, that build must also pass the root
`.build/swift-sdk-staging` directory through `--swift-sdks-path`. The checked-in
Example launcher supplies both requirements:

```sh
SWIFTPM_PREVIEW_BUILD=/absolute/path/to/patched/swift-build \
  Example/build-external-preview.sh
```

The external builder receives the selected sysroot in `SWIFT_SDK`. It can walk
up from that path to `cpicosdk-layout.json` and resolve the remaining paths
relative to the artifact-bundle root.

SDK setup is deliberately separate from an application build. SwiftPM needs
the destination compiler resources, sysroot, and toolset before it can load
and plan the package graph. Once staged, a consumer build is a single SwiftPM
product request; native support and firmware finalization are scheduled from
CPicoSDK's dependency-owned external builders.
