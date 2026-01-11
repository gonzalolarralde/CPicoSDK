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

- ✅ **Fully supported**:  Pico 2 W (RP2350) with WiFi capabilities
- 🚧 **In progress**: Support for additional boards and configurations is actively being developed
- 🔍 **Debugging**: Currently using `cortex-debug` in VSCode, following the proven pico-vscode approach.  LLDB support is being worked on but requires additional development time.

### Features & Capabilities

- **Full Pico SDK Access**: Interact with hardware peripherals (GPIO, ADC, I2C, SPI, UART, PWM, DMA, etc.) directly from Swift
- **WiFi & Networking**: Built-in support for CYW43 wireless chip with lwIP and HTTP client capabilities
- **Automated Environment Setup**: One-command setup that downloads and configures all dependencies
- **Integrated Debugging**: Set breakpoints, inspect variables, and step through Swift code on real hardware
- **UF2 Generation**: Automatic binary generation ready for drag-and-drop flashing
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

> **Note**: This project currently uses a very specific Swift version (`main-snapshot-2025-11-03`) due to bugs that need resolution in newer versions. This requirement will be relaxed as upstream issues are addressed.

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
        .package(url: "https://github.com/gonzalolarralde/CPicoSDK", .upToNextMinor(from: "2.2.0")),
    ],
    targets: [
        .target(
            name: "MyPicoProject",
            dependencies: ["CPicoSDK"]
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
- **SDK versions**:  Pico SDK, picotool, OpenOCD versions
- **Paths**: Where to find tools and dependencies (with variable substitution support like `${PICO_SDK_PATH}`)
- **Target configuration**: Board type, imported libraries, build type, SwiftPM triple
- **Library selection**: Which Pico SDK libraries to include (pico_stdlib, hardware_*, pico_cyw43_arch, etc.)

Example: 
```json
{
    "SWIFT_VERSION": "main-snapshot-2025-11-03",
    "SDK_VERSION": "2. 2.0",
    "TOOLCHAIN_VERSION": "14_2_Rel1",
    "BOARD": "pico2_w",
    "IMPORTED_LIBS": "pico_stdlib,hardware_gpio,pico_cyw43_arch_lwip_poll",
    "SWIFTPM_TRIPLE": "armv7em-none-none-eabi",
    "BUILD_TYPE": "RelWithDebInfo"
}
```

This configuration is: 
1. Read by the **PrepareEnvironmentPlugin** to set up the environment
2. Resolved (variables expanded) and exported as bash environment variables
3. Used by **GenerateCPicoSDKPlugin** to determine which headers to include
4. Consumed by **FinalizeBinaryPlugin** during the linking stage

### The `build.sh` Script: Environment Preparation

The root `build.sh` script is specifically for **CPicoSDK maintainers** to regenerate the compound header file.  Users consuming CPicoSDK as a dependency don't need to run it. 

The script:
1. Locates the `swiftly` executable
2. Sets the `PICO_SDK_BUNDLE_PATH` (defaults to `~/.pico-sdk`)
3. Invokes the `PrepareEnvironmentPlugin` with flags to disable most side effects
4. Sources the generated preparation script to export environment variables
5. Calls the `GenerateCPicoSDKPlugin` to create the header compound

This separation allows the header generation to be version-controlled while keeping the environment setup flexible. 

### The Header Compound: Bridging C and Swift

Swift cannot directly consume hundreds of individual C header files efficiently in an embedded context. To solve this, CPicoSDK generates a **compound header file** (`CPicoSDK.h`) that:

1. **Aggregates all relevant Pico SDK headers** into a single file based on `IMPORTED_LIBS`
2. **Processes through the C preprocessor** with the correct target architecture flags
3. **Resolves all macros, includes, and definitions** into one cohesive header
4. **Wraps in a Swift module** via a modulemap

**Generation process** (in `Plugins/GenerateCPicoSDKPluginTool/build.sh`):

1. Create a source header (`CPicoSDK.source. h`) that includes all requested Pico SDK headers: 
   ```c
   #define __ARM_ARCH_8M_MAIN__ 1
   #include <pico/stdlib.h>
   #include <hardware/gpio.h>
   // ... all other requested libraries
   ```

2. Use CMake to invoke the C preprocessor with the correct target flags
3. Generate `CPicoSDK.h` with all macros expanded and definitions resolved
4. Wrap it in a modulemap: 
   ```modulemap
   module CPicoSDK [system] {
       umbrella header "include/CPicoSDK.h"
       export *
   }
   ```

5. Copy to `Sources/_CPicoSDK/` where SwiftPM can find it

This approach: 
- ✅ Provides fast compilation (single header vs. hundreds)
- ✅ Ensures correct macro expansion for the target architecture
- ✅ Works around SwiftPM limitations with embedded toolchains
- ❌ Requires regeneration when library selection or SDK version changes

### The `shims.c` File: Runtime Compatibility

Located at `Plugins/FinalizeBinaryPluginTool/Test/shims.c`, this file provides **POSIX compatibility shims** for functions that the Swift runtime expects but aren't provided by the bare-metal ARM toolchain.

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
- Merges environment variables from `env.json` with user overrides
- Resolves variable substitutions (e.g., `${HOME}`, `${PICO_SDK_PATH}`)
- Downloads dependencies via PicoSDKDownloader
- Generates `toolset.json` for the ARM cross-compiler
- Creates `.swift-version` for Swiftly
- Writes VSCode settings and launch configurations
- Generates `buildServerConfig.json` for SourceKit-LSP
- Outputs a bash script with exported environment variables and helper functions

**Key files**:
- `PrepareEnvironmentPlugin.swift`: Main plugin logic
- `Resolvers.swift`: Environment variable resolution
- `Generators.swift`: Config file generation
- `Extensions.swift`: Utilities (JSON parsing, async process execution)

#### 2. **GenerateCPicoSDKPlugin** (`generate-cpicosdk`)

**Purpose**: Generate the compound header file

**What it does**: 
- Reads the `IMPORTED_LIBS` environment variable
- Creates `CPicoSDK.source.h` with the appropriate includes
- Invokes CMake to preprocess the header with target-specific flags
- Wraps the result in a modulemap
- Copies to `Sources/_CPicoSDK/`

**Why it exists**:  SwiftPM doesn't support prebuild commands for header generation, so this must be run manually during development.

#### 3. **FinalizeBinaryPlugin** (`finalize-rp2xxx-binary`)

**Purpose**: Link Swift object files with Pico SDK and generate the final binary

**What it does**:
- Takes the compiled Swift `.o` files from SwiftPM
- Links them with Pico SDK libraries using CMake
- Includes `shims.c` for runtime compatibility
- Generates both ELF (for debugging) and UF2 (for flashing) binaries
- Optionally flashes to a connected device

**Why it's necessary**: SwiftPM can't directly produce firmware binaries - it generates object files that must be linked with the Pico SDK's startup code, linker scripts, and library implementations.

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
├── Package.swift                          # Main package manifest with traits
├── env.json                               # Central configuration
├── generator_vars.json                    # Available hardware options and libraries
├── toolset.json                           # Generated by PrepareEnvironmentPlugin
├── build.sh                               # Maintainer tool for header regeneration
├── Sources/
│   ├── _CPicoSDK/                         # Generated compound header (git-tracked)
│   │   ├── include/CPicoSDK.h            # The compound header
│   │   └── module.modulemap              # Swift module wrapper
│   ├── _CPicoSDKTemplate/                # Template for regeneration
│   └── CPicoSDK/                         # Swift wrapper target
├── Plugins/
│   ├── PrepareEnvironmentPlugin/
│   │   ├── PrepareEnvironmentPlugin.swift
│   │   ├── Generators.swift
│   │   ├── Resolvers.swift
│   │   ├── Extensions.swift
│   │   └── BuildType.swift
│   ├── GenerateCPicoSDKPlugin/
│   │   └── GenerateCPicoSDKPlugin.swift
│   ├── GenerateCPicoSDKPluginTool/
│   │   ├── build.sh                      # Header generation logic
│   │   └── Test/
│   │       └── CMakeLists.txt            # CMake project for preprocessing
│   ├── FinalizeBinaryPlugin/
│   │   └── FinalizeBinaryPlugin.swift
│   └── FinalizeBinaryPluginTool/
│       ├── build.sh                      # Linking and UF2 generation
│       └── Test/
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

1. Modify `env.json` or `IMPORTED_LIBS`
2. Run `./build.sh` to regenerate the compound header
3. Commit the updated `Sources/_CPicoSDK/include/CPicoSDK.h`
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
