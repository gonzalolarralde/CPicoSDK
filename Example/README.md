# How to Start

1. **Clone the repository** and navigate to the Example project:
   ```bash
   cd Example/
   ```

2. **Install swiftly** and other dependencies if using linux:
   **Linux:** First, install required system dependencies:
   ```bash
   sudo apt install build-essential libhidapi-hidraw0 libhidapi-libusb0
   ```

   **Linux and macOS:** Install Swiftly from [swift.org](https://www.swift.org/install/) and ensure all dependencies mentioned at the end of the build script are installed.

3. **Run the build script** for the first time:
   ```bash
   bash build.sh
   ```
   > ⏱️ **Note**: The first run will take a couple of minutes as it downloads all dependencies (Pico SDK, toolchains, and Swift packages).

4. **Open in VSCode** (optional but recommended):
   Install the recommended extensions when prompted. This enables full IDE integration with debugging and flashing capabilities.

## Experimental SwiftPM External-Builder Build

`build-external-preview.sh` exercises the third-party build-system model from
[swift-package-manager#10198](https://github.com/swiftlang/swift-package-manager/pull/10198).
It is intentionally separate from `build.sh`, which remains the supported path
for released toolchains.

The preview requires a `swift-build` executable built from that PR together
with its companion SwiftBuild changes and the small local compatibility fixes
recorded in
[`Docs/SWIFTPM_EXTERNAL_PACKAGES_INVESTIGATION.md`](../Docs/SWIFTPM_EXTERNAL_PACKAGES_INVESTIGATION.md).
It uses the compiler pinned by CPicoSDK in
[`SwiftSDK/ExternalPreviewSDK/swift-toolchain.txt`](../SwiftSDK/ExternalPreviewSDK/swift-toolchain.txt).

First stage the relocatable Pico toolchain and matching Embedded Swift runtime.
This is a one-time destination setup step, not part of normal builds:

```bash
../setup-external-preview-sdk.sh --stage-only
```

Then run the preview build:

```bash
SWIFTPM_PREVIEW_BUILD=/absolute/path/to/pr-build/swift-build \
./build-external-preview.sh
```

The launcher copies the matching manifest/plugin API libraries found beside
`swift-build` into an isolated temporary directory. Set
`SWIFTPM_PREVIEW_LIBS_DIR` only when those libraries use a separate installed
`ManifestAPI`/`PluginAPI` layout. Exact checkout, patch, and build instructions
are in the investigation document.

The preview selects `Package@swift-6.5.swift`, whose only preview-specific
consumer wiring is the exported `CPicoFirmwareBuilder` plugin. CPicoSDK's own
`Package@swift-6.5.swift` owns the external native package, private builder
plugins, and host-side tools. SwiftPM builds native support through that
dependency, builds the Example static product, and runs the declared
post-product firmware task. The launcher makes one SwiftPM product-build
request; it does not run preparation or finalization itself.

Consumer-specific settings live in `cpicosdk-build.json`. `productName`
selects the static library to finalize when a package has more than one, while
the remaining fields select the board combination, target triple, build type,
stdio mode, and stack sizes. The launcher exports this file's absolute path as
`CPICOSDK_BUILD_CONFIGURATION`, allowing both CPicoSDK-owned build phases to
read it. Other preview launchers must do the same; no external-builder
implementation files need to be copied into the application package.

For the default release configuration, the flashable and diagnostic artifacts
are written to:

```text
.build/swiftpm-external-preview/out/Products/Release-none-armv7em/Example.elf
.build/swiftpm-external-preview/out/Products/Release-none-armv7em/Example.uf2
.build/swiftpm-external-preview/out/Products/Release-none-armv7em/Example.bin
.build/swiftpm-external-preview/out/Products/Release-none-armv7em/Example.hex
.build/swiftpm-external-preview/out/Products/Release-none-armv7em/Example.elf.map
.build/swiftpm-external-preview/out/Products/Release-none-armv7em/Example.dis
```

The post-product, auxiliary-output, and dependency product-filtering changes
are small local extensions to the PR experiment. They are documented, with
reproducible patches, in the investigation document. No device is programmed
unless `--flash` is passed.

## Programming the Device

Once your project is built, you have two options for programming your RP2xxx device:

- **Using cortex-debug** (with debug probe): Connect an SWD debug probe (like a Raspberry Pi Debug Probe or Picoprobe) to your device. This enables full debugging with breakpoints, variable inspection, and step-through execution.

- **Using picotool** (USB flashing): Hold down the **BOOTSEL** button while connecting your device via USB (or press it while pressing the reset button). The device will appear as a USB mass storage device, and picotool can directly write the firmware without needing a debug probe.

<img width="1092" height="888" alt="Screenshot 2026-01-03 at 10 38 38 PM" src="https://github.com/user-attachments/assets/a32ef610-16fc-4141-b718-558960bc492f" />
