# CPicoSDK

A SwiftPM package that enables seamless Swift development for the Raspberry Pi Pico SDK, targeting the RP2xxx device family with a streamlined developer experience.

## License

This project is licensed under the MIT License. 

---

<img width="1092" height="888" alt="Screenshot 2026-01-03 at 10 38 38 PM" src="https://github.com/user-attachments/assets/a32ef610-16fc-4141-b718-558960bc492f" />

## For Users

### How to Start

The easiest way to get started is with the **Example** project located in the `Example/` directory:

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

#### Programming the Device

Once your project is built, you have two options for programming your RP2xxx device:

- **Using cortex-debug** (with debug probe): Connect an SWD debug probe (like a Raspberry Pi Debug Probe or Picoprobe) to your device. This enables full debugging with breakpoints, variable inspection, and step-through execution.

- **Using picotool** (USB flashing): Hold down the **BOOTSEL** button while connecting your device via USB (or press it while pressing the reset button). The device will appear as a USB mass storage device, and picotool can directly write the firmware without needing a debug probe.

#### PIO Example

The Example project includes a small PIO demo based on `hello_pio` from pico-examples. It ships a `hello.pio` file and uses the `PIOASM` SwiftPM plugin to assemble it and expose a Swift helper (`hello.program_init`). In `Example.swift`, the PIO program is loaded and a state machine drives GPIO 20 by pushing values into the TX FIFO.

Swift-specific blocks can be embedded directly in a `.pio` file using a `% swift { ... }` section. In `hello.pio`, that block defines a Swift extension on the generated `hello` namespace with `program_init(...)`, which wires up pin mapping, GPIO init, pin direction, state machine config, and enable. This lets you keep PIO program + Swift setup side by side in a single source file.

The `% swift { ... }` section is placed after the `.program` body in `hello.pio`, so the assembly remains up top and the Swift helper lives at the bottom of the same file.

The example also keeps a small Unicode-aware string check on purpose. That exercises the embedded Swift Unicode runtime path so CPicoSDK can demonstrate automatically linking `libswiftUnicodeDataTables.a` only when the final link actually needs it.

### Experimental Concurrency Support

CPicoSDK now has a first pass at embedded Swift Concurrency support, but it is still experimental.

Important points:

- it is opt-in
- it currently lives in a secondary package product: `CPicoConcurrency`
- no concurrency support is pulled in unless you depend on and import it explicitly

For now, if you want to use `Task`, `await`, or the helper APIs in this repository, add `CPicoConcurrency` to your target dependencies and import it in your code:

```swift
import CPicoSDK
import CPicoConcurrency
```

Current status:

- plain embedded `async`/`await` is working
- the implementation is still exploratory
- custom executors are not supported yet
- Linux currently depends on a vendored fallback copy of the embedded `_Concurrency` artifacts for the pinned Swift snapshot
- the API surface may still change

The Example project is expected to keep demonstrating an important embedded constraint here: long-running `while true { ... }` loops need some form of yielding or scheduler pumping, otherwise non-awaiting code can monopolize the CPU.

### Versioning

CPicoSDK follows a versioning scheme that tracks the underlying Pico SDK version:

- **Major.Minor** versions match the Pico SDK version (e.g., `2.2`)
- **Patch** version is calculated as: `(Pico SDK patch × 100) + CPicoSDK revision`
  - This gives us 100 possible revisions for each Pico SDK patch version
  - Allows for CPicoSDK-specific updates without changing the base SDK version

**Example**: When Pico SDK `2.2.1` is released, CPicoSDK will release:
- `2.2.100` - Initial release tracking Pico SDK 2.2.1
- `2.2.101` - `2.2.199` - Up to 99 additional CPicoSDK updates for the same base SDK

> ⚠️ **Note**: This versioning scheme prioritizes clarity about which Pico SDK version is bundled, but may introduce breaking changes between revisions. Always check release notes when updating.

### Overview

**CPicoSDK** brings the power of Swift to embedded development on the RP2xxx microcontroller family. This project enables you to: 

- 🚀 **Use Pico SDK in Swift** with full SwiftPM integration
- 🔧 **Develop in VSCode** with complete debugging support, SourceKit-LSP autocompletion, and one-click flashing
- 🎯 **Target RP2xxx devices** with a modern, type-safe language
- 💻 **Cross-platform development** on macOS and linux
- ⚡ **Streamlined workflow** with automated environment setup and dependency management

This project is built with the intention of **streamlining the developer experience** when building for embedded systems, making it as simple as developing any other Swift package.

### Current Status

- ✅ **Fully supported**: Pico 2 (RP2350A), Pico 2 W (RP2350A + CYW43439), Pimoroni Pico Plus 2 (RP2350B), Pimoroni Pico Plus 2 W (RP2350B + CYW43439)
- 🚧 **In progress**: More RP2xxx boards and configuration combinations are actively being developed
- 🔍 **Debugging**: Currently using `cortex-debug` in VSCode, following the proven pico-vscode approach.  LLDB support is being worked on but requires additional development time.

### Board/Trait Matrix (Temporary)

This matrix is temporary while we work on a more generic approach that ties traits to non-specific board configurations.

| Board | Combination | Variant Trait | Radio Trait |
| --- | --- | --- | --- |
| Pico 2 | `pico2` | `Variant_RP2350A` | `Radio_None` |
| Pico 2 W | `pico2_w` | `Variant_RP2350A` | `Radio_CYW43439` |
| Pimoroni Pico Plus 2 | `pimoroni_pico_plus2_rp2350` | `Variant_RP2350B` | `Radio_None` |
| Pimoroni Pico Plus 2 W | `pimoroni_pico_plus2_w_rp2350` | `Variant_RP2350B` | `Radio_CYW43439` |

### Features & Capabilities

- **Full Pico SDK Access**: Interact with hardware peripherals (GPIO, ADC, I2C, SPI, UART, PWM, DMA, etc.) directly from Swift
- **WiFi & Networking**: Built-in support for CYW43 wireless chip with lwIP and HTTP client capabilities
- **Automated Environment Setup**: One-command setup that downloads and configures all dependencies
- **Integrated Debugging**: Set breakpoints, inspect variables, and step through Swift code on real hardware
- **UF2 Generation**: Automatic binary generation ready for drag-and-drop flashing
- **Smart Embedded Swift Runtime Linking**: Automatically links extra embedded Swift archives such as `libswiftUnicodeDataTables.a` only when your build artifact actually references them
- **Build Configurations**: Support for Debug, Release, RelWithDebInfo, and MinSizeRel builds

### Platform Support

#### macOS
Install Swiftly and you're ready to go! Get it from [swift.org](https://www.swift.org/install/macos/) 

#### Windows
There is no Windows support at the moment. This is mostly due to lack of ways to test the platform. If interested please consider contributing support or opening/+1 an issue requesting it to track and quantify interest.

#### Linux
First, install required system dependencies:
```bash
sudo apt install build-essential libhidapi-hidraw0 libhidapi-libusb0
```

Then install Swiftly from [swift.org](https://www.swift.org/download/) and ensure all dependencies mentioned at the end of the build script are installed.

### Swift Version

> **Note**: This project currently uses a very specific Swift version (`main-snapshot-2026-04-01`) due to bugs that need resolution in newer versions. This requirement will be relaxed as upstream issues are addressed.

### Getting Started

1. **Create your Swift package** that depends on CPicoSDK: 

```swift
// swift-tools-version:  6.2
import PackageDescription

let package = Package(
    name: "MyPicoProject",
    products: [
        .library(name: "MyPicoProject", type: .static, targets: ["MyPicoProject"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/gonzalolarralde/CPicoSDK", exact: "2.2.5",
            traits: [.init(name: "Variant_RP2350A"), .init(name: "Radio_None")] // Pico 2
            traits: [.init(name: "Variant_RP2350A"), .init(name: "Radio_CYW43439")] // Pico 2W
        ),
    ],
    targets: [
        .target(
            name: "MyPicoProject",
            dependencies: ["CPicoSDK"],
            plugins: [.plugin(name: "PIOASM", package: "CPicoSDK")]
        ),
    ]
)
```

2. **Write your Swift code**:

```swift
import CPicoSDK

@main
struct App {
    static func main() {
        stdio_init_all()
        
        gpio_init(25)
        gpio_set_dir(25, true)
        
        while true {
            gpio_put(25, true)
            sleep_ms(250)
            gpio_put(25, false)
            sleep_ms(250)
        }
    }
}
```

3. **Build and flash** (see the Example directory for a complete build. sh script):

```bash
./build.sh --flash
```

The build script will:
- Download and configure the Pico SDK, ARM toolchain, and all dependencies
- Set up VSCode with debugging configurations
- Build your Swift code
- Link it with the Pico SDK
- Generate UF2 and ELF binaries
- Optionally flash to your device

### VSCode Integration

When you run the environment preparation step, CPicoSDK automatically generates: 

- **`.vscode/settings.json`**: VSCode workspace configuration
- **`.vscode/launch.json`**: Debug configurations for cortex-debug
- **`buildServerConfig.json`**: SourceKit-LSP configuration for code completion
- **`toolset.json`**: SwiftPM toolchain configuration
- **`.swift-version`**: Swiftly version pinning

This gives you a complete IDE experience with:
- Syntax highlighting and code completion
- Inline error checking
- Hardware debugging with breakpoints
- Variable inspection
- One-click build and flash

---

## For Contributors & Maintainers

### Implementation Details

This section explains how CPicoSDK works internally and how the various pieces fit together.

### Architecture Overview

CPicoSDK uses a hybrid approach combining **SwiftPM plugins** for Swift-native tooling with **bash scripts** for complex build orchestration. This approach balances maintainability with the flexibility needed for embedded cross-compilation workflows.

### The `env.json` File: Configuration as Data

The `env.json` file is the **central configuration** that drives the entire build environment.  It specifies:

- **Toolchain versions**: Swift snapshot, ARM GCC, CMake, Ninja
- **SDK versions**: Pico SDK, picotool, OpenOCD versions
- **Paths**: Where to find tools and dependencies (with variable substitution support like `${PICO_SDK_PATH}`)
- **Base configuration**: Default board, build type, SwiftPM triple, and base library selection
- **Combinations**: Per-board overrides and trait mappings (Variant/Radio) used to generate targets

Example: 
```json
{
    "vars": {
        "SWIFT_VERSION": "main-snapshot-2026-04-01",
        "SDK_VERSION": "2.2.0",
        "TOOLCHAIN_VERSION": "14_2_Rel1",
        "BOARD": "pico2",
        "IMPORTED_LIBS": "pico_stdlib,hardware_gpio",
        "SWIFTPM_TRIPLE": "armv7em-none-none-eabi",
        "BUILD_TYPE": "RelWithDebInfo"
    },
    "combinations": {
        "pico2": {
            "vars": {
                "BOARD": "pico2",
                "IMPORTED_LIBS_MORE": ""
            },
            "traits": ["Variant_RP2350A", "Radio_None"]
        },
        "pico2_w": {
            "vars": {
                "BOARD": "pico2_w",
                "IMPORTED_LIBS_MORE": "pico_cyw43_arch,pico_cyw43_arch_lwip_poll,pico_lwip,pico_lwip_arch,pico_lwip_http"
            },
            "traits": ["Variant_RP2350A", "Radio_CYW43439"]
        }
    }
}
```

This configuration is: 
1. Read by the **PrepareEnvironmentPlugin** to set up the environment (base vars + combinations)
2. Resolved (variables expanded) and exported as bash environment variables
3. Used by **GenerateCPicoSDKPlugin** to generate per-combination headers and `Package.swift`
4. Consumed by **FinalizeBinaryPlugin** during the linking stage

### The `build.sh` Script: Environment Preparation

The root `build.sh` script is specifically for **CPicoSDK maintainers** to regenerate the generated headers and `Package.swift`. Users consuming CPicoSDK as a dependency don't need to run it. `Package.swift` is generated from `Package.swift.template`, so edit the template instead.

The script:
1. Cleans generated build artifacts and copies `Package.swift.template` to `Package.swift`
2. Locates the `swiftly` executable
3. Sets the `PICO_SDK_BUNDLE_PATH` (defaults to `~/.pico-sdk`)
4. Invokes the `PrepareEnvironmentPlugin` with flags to disable most side effects
5. Sources the generated preparation script to export environment variables
6. Calls the `GenerateCPicoSDKPlugin` to generate per-combination headers and targets

This separation allows the header generation to be version-controlled while keeping the environment setup flexible. 

### The Header Compound: Bridging C and Swift

Swift cannot directly consume hundreds of individual C header files efficiently in an embedded context. To solve this, CPicoSDK generates a **compound header file** per combination (e.g. `CPicoSDK_pico2.h`) that:

1. **Aggregates all relevant Pico SDK headers** into a single file based on `IMPORTED_LIBS`
2. **Processes through the C preprocessor** with the correct target architecture flags
3. **Resolves all macros, includes, and definitions** into one cohesive header
4. **Wraps in a Swift module** via a modulemap

**Generation process** (in `Plugins/GenerateCPicoSDKPlugin/GenerateCPicoSDKPlugin.swift` + `Plugins/GenerateCPicoSDKPluginTool/CMakeHarness`):

1. Create a source header that includes all requested Pico SDK headers: 
   ```c
   #define __ARM_ARCH_8M_MAIN__ 1
   #include <pico/stdlib.h>
   #include <hardware/gpio.h>
   // ... all other requested libraries
   ```

2. Use CMake to invoke the C preprocessor with the correct target flags
3. Generate `CPicoSDK_<combination>.h` with all macros expanded and definitions resolved
4. Wrap it in a modulemap: 
   ```modulemap
   module _CPicoSDK_<combination> [system] {
       umbrella header "include/CPicoSDK_<combination>.h"
       export *
   }
   ```

5. Copy to `Sources/_CPicoSDK_<combination>/` where SwiftPM can find it

This approach: 
- ✅ Provides fast compilation (single header vs. hundreds)
- ✅ Ensures correct macro expansion for the target architecture
- ✅ Works around SwiftPM limitations with embedded toolchains
- ❌ Requires regeneration when library selection or SDK version changes

#### Header Fixups

After preprocessing, the generated compound header is passed through `Plugins/GenerateCPicoSDKPlugin/PicoSDKHeaderFixer.swift` before it is written into `Sources/_CPicoSDK_<combination>/include/`.

That fixer currently performs a few targeted transformations so the result imports more cleanly into Swift:

1. **Normalize `_u(...)` numeric macros**
   Pico headers frequently emit numeric macros in the form:
   ```c
   #define GPIO_FUNC_SIO _u(5)
   ```
   These are rewritten to:
   ```c
   #define GPIO_FUNC_SIO 5u
   ```

2. **Preserve importer-friendly hardware entrypoints**
   Fixed-address hardware macros such as:
   ```c
   #define timer0_hw ((timer_hw_t *)TIMER0_BASE)
   #define nvic_hw ((nvic_hw_t *)(PPB_BASE + M33_NVIC_ISER0_OFFSET))
   #define spi0 ((spi_inst_t *)spi0_hw)
   ```
   are rewritten into `static ... * const ...` declarations:
   ```c
   static timer_hw_t * const timer0_hw = (timer_hw_t *)TIMER0_BASE; // ORIGINAL: #define timer0_hw ((timer_hw_t *)TIMER0_BASE)
   static nvic_hw_t * const nvic_hw = (nvic_hw_t *)(PPB_BASE + M33_NVIC_ISER0_OFFSET); // ORIGINAL: #define nvic_hw ((nvic_hw_t *)(PPB_BASE + M33_NVIC_ISER0_OFFSET))
   static spi_inst_t * const spi0 = (spi_inst_t *)spi0_hw; // ORIGINAL: #define spi0 ((spi_inst_t *)spi0_hw)
   ```
   This covers:
   - direct base-address macros like `timer0_hw`
   - base-plus-offset macros like `nvic_hw`
   - casted handle aliases like `spi0` and `uart0`

3. **Rewrite simple hardware aliases with `__typeof__`**
   Some Pico macros are aliases or indexed aliases rather than direct casts:
   ```c
   #define arm_cpu_hw m33_hw
   #define interp0_hw (&interp_hw_array[0])
   #define pio0 pio0_hw
   ```
   These are rewritten as:
   ```c
   static __typeof__(m33_hw) const arm_cpu_hw = m33_hw; // ORIGINAL: #define arm_cpu_hw m33_hw
   static __typeof__((&interp_hw_array[0])) const interp0_hw = (&interp_hw_array[0]); // ORIGINAL: #define interp0_hw (&interp_hw_array[0])
   static __typeof__(pio0_hw) const pio0 = pio0_hw; // ORIGINAL: #define pio0 pio0_hw
   ```
   `__typeof__` is used here so the fixer does not need a separate type-reconstruction pass for alias-only macros.

4. **Prefix the final header with `#pragma GCC system_header`**
   This keeps the generated C import quieter on the Swift side by treating it as system-header input.

The current fixups are intentionally narrow. They target hardware entrypoints and related aliases without attempting to rewrite every Pico macro. Function-like selector helpers such as `PIO_INSTANCE(num)` or `SPI_NUM(spi)` are left as macros unless there is a specific reason to expose them differently.

Separately from these textual fixups, maintainers may also annotate selected imported MMIO and peripheral handle types with API notes or header attributes such as `swift_attr("~Copyable")` when Swift should treat them as address-identified hardware views rather than ordinary copyable values.

### The `shims.c` File: Runtime Compatibility

Located at `Plugins/FinalizeBinaryPluginTool/CMakeHarness/shims.c`, this file provides **POSIX compatibility shims** for functions that the Swift runtime expects but aren't provided by the bare-metal ARM toolchain.

For example:
```c
int posix_memalign(void **memptr, size_t alignment, size_t size) {
    // Implementation using memalign from newlib
}
```

These shims are compiled into the final binary during the finalization stage, ensuring Swift's memory management works correctly on bare metal.

### PicoSDKDownloader:  Dependency Automation

CPicoSDK depends on [PicoSDKDownloader](https://github.com/sympatito/PicoSDKDownloader), a separate package that **replicates the pico-vscode model** for downloading dependencies.

When you run the `PrepareEnvironmentPlugin`, it:
1. Invokes the `pico-bootstrap` command from PicoSDKDownloader
2. Downloads the Pico SDK, ARM toolchain, CMake, Ninja, picotool, and OpenOCD
3. Extracts them to `~/.pico-sdk` (or `PICO_SDK_BUNDLE_PATH`)
4. Verifies checksums and versions

This ensures:
- 🔒 **Reproducible builds**:  Everyone gets the same tool versions
- 📦 **Zero-configuration**: No manual installation required
- 🌐 **Offline-friendly**: Downloaded tools are cached locally

### SwiftPM Plugins: The Plugin Trilogy

CPicoSDK uses three SwiftPM command plugins to orchestrate the build:

#### 1. **PrepareEnvironmentPlugin** (`prepare-rp2xxx-environment`)

**Purpose**: Set up the complete build environment

**What it does**:
- Merges base vars and combination overrides from `env.json` with user overrides
- Resolves variable substitutions (e.g., `${HOME}`, `${PICO_SDK_PATH}`)
- Downloads dependencies via PicoSDKDownloader
- Generates `toolset.json` for the ARM cross-compiler
- Creates `.swift-version` for Swiftly
- Writes VSCode settings and launch configurations
- Generates `buildServerConfig.json` for SourceKit-LSP
- Outputs a bash script with exported environment variables and helper functions

**Key files**:
- `PrepareEnvironmentPlugin.swift`: Main plugin logic
- `Env.swift`: Environment modeling and combination resolution
- `Resolvers.swift`: Environment variable resolution
- `Generators.swift`: Config file generation
- `Extensions.swift`: Utilities (JSON parsing, async process execution)

#### 2. **GenerateCPicoSDKPlugin** (`generate-cpicosdk`)

**Purpose**: Generate per-combination compound headers and `Package.swift`

**What it does**: 
- Reads `IMPORTED_LIBS` plus combination overrides (e.g. `IMPORTED_LIBS_MORE`)
- Creates a source header with the appropriate includes per combination
- Invokes CMake to preprocess the header with target-specific flags
- Wraps the result in a modulemap
- Copies to `Sources/_CPicoSDK_<combination>/`
- Generates `Package.swift` from `Package.swift.template` with combination targets

**Why it exists**:  SwiftPM doesn't support prebuild commands for header generation, so this must be run manually during development.

#### 3. **FinalizeBinaryPlugin** (`finalize-rp2xxx-binary`)

**Purpose**: Link Swift object files with Pico SDK and generate the final binary

**What it does**:
- Takes the compiled Swift `.o` files from SwiftPM
- Links them with Pico SDK libraries using the CMake harness
- Detects when the final link needs extra embedded Swift runtime archives and adds them automatically
- Runs as a native Swift plugin (no standalone shell build script)
- Includes `shims.c` for runtime compatibility
- Generates both ELF (for debugging) and UF2 (for flashing) binaries
- Optionally flashes to a connected device

**Why it's necessary**: SwiftPM can't directly produce firmware binaries - it generates object files that must be linked with the Pico SDK's startup code, linker scripts, and library implementations.

### Experimental Concurrency Support

There is now a first pass at Swift Concurrency support in a separate target:

- `CPicoConcurrency`

This is intentionally not folded into the base `CPicoSDK` product yet.

Reasons:

- the implementation is still experimental
- the current goal is to get a mostly functional baseline on device
- the limitations of Embedded Swift concurrency on RP2350 are still being mapped out
- no concurrency code should be referenced unless the package explicitly opts into it

Current implementation shape:

- the toolchain-provided `libswift_Concurrency.a` is used
- the low-level runtime hook exports remain in [Sources/ConcurrencyShims/ConcurrencyShims.c](Sources/ConcurrencyShims/ConcurrencyShims.c)
- the scheduling backend now lives in [Sources/CPicoConcurrency/RuntimeScheduler.swift](Sources/CPicoConcurrency/RuntimeScheduler.swift)
- that scheduler uses Pico SDK `async_context` rather than a handwritten queue loop
- on Linux, the build can fall back to vendored embedded `_Concurrency` artifacts under [Vendor/EmbeddedSwiftRuntime](/Users/gonzalo/src/CPicoSDK/Vendor/EmbeddedSwiftRuntime) when the toolchain packaging is incomplete

The current state is best described as:

- generic embedded `async`/`await` works
- the implementation is not considered stable yet
- custom executors are still not viable on this embedded runtime
- exploratory pieces like `@CPU0Actor` and `@CPU1Actor` exist as future-facing scaffolding, not as working CPU pinning support

The Linux fallback is intentionally versioned by `SWIFT_VERSION`. The build only uses a vendored runtime directory when the active Swift snapshot has a matching directory name, which avoids silently mixing concurrency runtime files from different toolchains.

The Example is expected to keep representing an important behavioral constraint:

- a tight `while true { ... }` loop still needs some kind of yielding or scheduler pumping so non-awaiting code does not lock the CPU

For the detailed investigation history, current architecture, and known limitations, see:

- [Docs/CONCURRENCY_NOTES.md](/Users/gonzalo/src/CPicoSDK/Docs/CONCURRENCY_NOTES.md)

### Bash + Swift:  A Pragmatic Hybrid

While the plugins are written in Swift for type safety and integration with SwiftPM, many complex operations are delegated to bash scripts:

**Why bash?**
- ✅ Direct access to CMake, GNU toolchain, and POSIX utilities
- ✅ Easier to debug and iterate during development
- ✅ Familiar to embedded developers
- ✅ Handles complex multi-tool pipelines naturally

**Why not all bash?**
- ❌ No access to SwiftPM's package graph and dependency information
- ❌ No type safety or structured error handling
- ❌ Harder to generate JSON and structured config files

**The hybrid approach** lets us:
- Use Swift for orchestration, environment resolution, and file generation
- Use bash for invoking CMake, gcc-arm-none-eabi, picotool, etc.
- Keep `build.sh` files simple and maintainable
- Gradually migrate more logic to Swift over time (see TODOs)

### File Structure

```
CPicoSDK/
├── Package.swift                          # Generated package manifest with traits
├── Package.swift.template                 # Template used to generate Package.swift
├── env.json                               # Central configuration
├── generator_vars.json                    # Available hardware options and libraries
├── toolset.json                           # Generated by PrepareEnvironmentPlugin
├── build.sh                               # Maintainer tool for header + manifest regeneration
├── Sources/
│   ├── _CPicoSDK_pico2/                   # Generated compound header (git-tracked)
│   │   ├── include/CPicoSDK_pico2.h       # The compound header
│   │   └── module.modulemap              # Swift module wrapper
│   ├── _CPicoSDK_pico2_w/                 # Generated compound header (git-tracked)
│   ├── _CPicoSDK_pimoroni_pico_plus2_rp2350/
│   ├── _CPicoSDK_pimoroni_pico_plus2_w_rp2350/
│   └── CPicoSDK/                         # Swift wrapper target
├── Plugins/
│   ├── PrepareEnvironmentPlugin/
│   │   ├── PrepareEnvironmentPlugin.swift
│   │   ├── Env.swift
│   │   ├── Generators.swift
│   │   ├── Resolvers.swift
│   │   ├── Extensions.swift
│   │   └── BuildType.swift
│   ├── GenerateCPicoSDKPlugin/
│   │   ├── GenerateCPicoSDKPlugin.swift  # Header generation logic
│   │   ├── Env.swift
│   │   └── Extensions.swift
│   ├── GenerateCPicoSDKPluginTool/
│   │   └── CMakeHarness/
│   │       └── CMakeLists.txt            # CMake project for preprocessing
│   ├── FinalizeBinaryPlugin/
│   │   ├── FinalizeBinaryPlugin.swift    # Linking and UF2 generation
│   │   ├── Env.swift
│   │   └── Extensions.swift
│   └── FinalizeBinaryPluginTool/
│       └── CMakeHarness/
│           ├── CMakeLists.txt            # CMake project for linking
│           └── shims.c                   # POSIX compatibility layer
└── Example/
    ├── Package.swift                      # Example project consuming CPicoSDK
    ├── build.sh                          # User-facing build script
    └── Sources/
        └── Example/
            └── main.swift
```

### Development Workflow

**For CPicoSDK maintainers:**

1. Modify `env.json`, `generator_vars.json`, or `Package.swift.template`
2. Run `./build.sh` to regenerate `Package.swift` and the compound headers
3. Commit the updated `Package.swift` and `Sources/_CPicoSDK_*` outputs
4. Tag a new version

**For users consuming CPicoSDK:**

1. Add CPicoSDK as a dependency
2. Run `./build.sh` (which calls the plugins)
3. Develop Swift code with full IDE support
4. Flash and debug on hardware

### Future Improvements

See `TODO.md` for detailed tasks, including:
- Moving more bash logic into Swift plugins
- Supporting multiple boards and configurations via traits
- Migrating from compound header to per-library targets
- LLDB integration for debugging
- Better handling of build types and debug symbols

### Contributing

Contributions are welcome! Key areas of interest: 
- 🎯 Adding support for more RP2xxx boards (Pico, Pico W, Pico 2, etc.)
- 🐛 Improving LLDB integration for debugging
- ⚡ Optimizing the header generation process
- 🧪 Adding test coverage

---

## Acknowledgments

This project builds upon the excellent work of: 
- The Raspberry Pi Pico SDK team
- The pico-vscode extension developers
- The Swift Embedded community

---

**Happy embedded Swift hacking!  🚀**
