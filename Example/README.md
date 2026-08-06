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

   **Linux and macOS:** Install Swiftly from [swift.org](https://www.swift.org/install/).

3. **Build SwiftPM PR #10198** and set `SWIFTPM_BIN_DIR` to the directory that
   contains its sibling `swift-package` and `swift-build` executables. Released
   SwiftPM cannot load this experiment's tools-version 6.5 manifests.

4. **Run the build script** for the first time:
   ```bash
   SWIFTPM_BIN_DIR=/absolute/path/to/pr-build/Products/Debug ./build.sh
   ```
   > ⏱️ **Note**: The first run will take a couple of minutes as it downloads all dependencies (Pico SDK, toolchains, and Swift packages).

5. **Open in VSCode** (optional but recommended):
   Install the recommended extensions when prompted. This enables full IDE integration with debugging and flashing capabilities.

## SwiftPM External-Builder Build

This branch uses the third-party build-system model from
[swift-package-manager#10198](https://github.com/swiftlang/swift-package-manager/pull/10198)
as its only Example build path. `Package.swift` is a tools-version 6.5
manifest and intentionally has no released-SwiftPM compatibility path.

`build.sh` is deliberately small. Its phases are:

1. user-selectable configuration near the top of the script;
2. one `prepare-rp2xxx-environment` command-plugin call;
3. one `swift-build` product request;
4. automatic post-product firmware finalization in SwiftPM's build graph; and
5. an optional `FlashFirmware` command-plugin call when `--flash` is present.

The preparation plugin downloads the Pico SDK and host tools, stages the
matching Embedded Swift runtime into a relocatable Swift SDK, and writes the
environment file sourced by the launcher. SwiftPM then schedules CPicoSDK's
dependency-owned native builder, compiles the Example static library, and runs
the declared post-product finalizer. Shell code does not reproduce those build
steps. CPicoSDK selects the compiler snapshot from
`SwiftSDK/ExternalPreviewSDK/swift-toolchain.txt`; preparation does not rewrite
the consumer's `.swift-version`.

Set `SWIFTPM_BIN_DIR` to one directory containing both patched executables:

```bash
SWIFTPM_BIN_DIR=/absolute/path/to/pr-build/Products/Debug ./build.sh
```

The sibling layout matters: `swift-package` supplies package/plugin API
libraries used to load the manifests and command plugins, while `swift-build`
executes the external build graph. Exact checkout, patch, and build instructions
are in
[`Docs/SWIFTPM_EXTERNAL_PACKAGES_INVESTIGATION.md`](../Docs/SWIFTPM_EXTERNAL_PACKAGES_INVESTIGATION.md).

Consumer-specific policy lives in `cpicosdk-build.json`. It selects the board
combination, stack sizes, environment overrides, and incremental behavior. The
launcher exports the file's absolute path as `CPICOSDK_BUILD_CONFIGURATION`,
so CPicoSDK's preparation, native-build, and finalization components resolve
the same settings. The implementation itself remains in CPicoSDK; applications
only attach the exported `CPicoFirmwareBuilder` plugin.

For the default release configuration, the flashable and diagnostic artifacts
are written to:

```text
.build/out/Products/Release-none-armv7em/Example.elf
.build/out/Products/Release-none-armv7em/Example.uf2
.build/out/Products/Release-none-armv7em/Example.bin
.build/out/Products/Release-none-armv7em/Example.hex
.build/out/Products/Release-none-armv7em/Example.elf.map
.build/out/Products/Release-none-armv7em/Example.dis
```

The post-product, auxiliary-output, and dependency product-filtering changes
are local extensions to the PR experiment. They are documented, with
reproducible patches, in the investigation document. No device is programmed
unless `--flash` is passed.

Flashing waits for a compatible device for at most 60 seconds by default. Set
`CPICOSDK_FLASH_WAIT_SECONDS` to choose another bounded wait, and set
`CPICOSDK_PICOTOOL_SERIAL` to bind the operation to one picotool serial when
multiple devices may be attached:

```bash
CPICOSDK_FLASH_WAIT_SECONDS=30 \
CPICOSDK_PICOTOOL_SERIAL=0123456789ABCDEF \
SWIFTPM_BIN_DIR=/absolute/path/to/pr-build/Products/Debug \
  ./build.sh --flash
```

## Programming the Device

Once your project is built, you have two options for programming your RP2xxx device:

- **Using cortex-debug** (with debug probe): Connect an SWD debug probe (like a Raspberry Pi Debug Probe or Picoprobe) to your device. This enables full debugging with breakpoints, variable inspection, and step-through execution.

- **Using picotool** (USB flashing): Hold down the **BOOTSEL** button while connecting your device via USB (or press it while pressing the reset button). The device will appear as a USB mass storage device, and picotool can directly write the firmware without needing a debug probe.

<img width="1092" height="888" alt="Screenshot 2026-01-03 at 10 38 38 PM" src="https://github.com/user-attachments/assets/a32ef610-16fc-4141-b718-558960bc492f" />
