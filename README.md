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

   **Linux and macOS:** Install Swiftly from
   [swift.org](https://www.swift.org/install/).

3. **Build SwiftPM PR #10198**, then point `SWIFTPM_BIN_DIR` at the directory
   containing its sibling `swift-package` and `swift-build` executables.

4. **Run the build script** for the first time:
   ```bash
   SWIFTPM_BIN_DIR=/absolute/path/to/pr-build/Products/Debug ./build.sh
   ```
   > ⏱️ **Note**: The first run will take a couple of minutes as it downloads all dependencies (Pico SDK, toolchains, and Swift packages).

5. **Open in VSCode** (optional but recommended):
   Install the recommended extensions when prompted. This enables full IDE integration with debugging and flashing capabilities.

This branch is an experiment based on SwiftPM's external-package preview. Its
tools-version 6.5 manifests require the development SwiftPM from
[swift-package-manager#10198](https://github.com/swiftlang/swift-package-manager/pull/10198);
there is intentionally no released-SwiftPM compatibility path. Native support
and firmware finalization are CPicoSDK-owned build tasks, and `Example/build.sh`
is the sole launcher. See
[`Example/README.md`](Example/README.md#swiftpm-external-builder-build) for the
setup and build flow.

#### Programming the Device

Once your project is built, you have two options for programming your RP2xxx device:

- **Using cortex-debug** (with debug probe): Connect an SWD debug probe (like a Raspberry Pi Debug Probe or Picoprobe) to your device. This enables full debugging with breakpoints, variable inspection, and step-through execution.

- **Using picotool** (USB flashing): Hold down the **BOOTSEL** button while connecting your device via USB (or press it while pressing the reset button). The device will appear as a USB mass storage device, and picotool can directly write the firmware without needing a debug probe.

#### PIO Example

The Example project includes a small PIO demo based on `hello_pio` from pico-examples. It ships a `hello.pio` file and uses the `PIOASM` SwiftPM plugin to assemble it and expose a Swift helper (`hello.program_init`). In `Example.swift`, the PIO program is loaded and a state machine drives GPIO 20 by pushing values into the TX FIFO.

Swift-specific blocks can be embedded directly in a `.pio` file using a `% swift { ... }` section. In `hello.pio`, that block defines a Swift extension on the generated `hello` namespace with `program_init(...)`, which wires up pin mapping, GPIO init, pin direction, state machine config, and enable. This lets you keep PIO program + Swift setup side by side in a single source file.

The `% swift { ... }` section is placed after the `.program` body in `hello.pio`, so the assembly remains up top and the Swift helper lives at the bottom of the same file.

The example also keeps a small Unicode-aware string check on purpose. That exercises the embedded Swift Unicode runtime path so CPicoSDK can demonstrate automatically linking `libswiftUnicodeDataTables.a` only when the final link actually needs it.

#### Embedded Assets

Text and binary resources can be embedded into the firmware by adding `.codeasset` files to your Swift target and enabling the `AssetCompiler` plugin:

```swift
.target(
    name: "Example",
    dependencies: [
        .product(name: "CPicoSDK", package: "CPicoSDK"),
    ],
    plugins: [
        .plugin(name: "AssetCompiler", package: "CPicoSDK"),
    ]
)
```

For a file named `sample.codeasset`, the plugin generates an `Asset.sample` accessor:

```swift
print("Asset name: \(Asset.sample.name) bytes: \(Asset.sample.data.count)")
print("Asset content: \(String(decoding: Asset.sample.data, as: UTF8.self))")
```

`Asset.data` is an `UnsafeRawBufferPointer` that points at the linked resource bytes. The finalizer embeds the resource with `objcopy` into a read-only flash section, so accessing the bytes does not require a generated Swift byte array or an SRAM copy of the file content.

#### PSRAM (Optional)

The Example shows PSRAM as an optional configuration and allocator target.

In `configure(with:)`, enable PSRAM by adding:

```swift
configurator.configure(PSRAMConfiguration())
```

Then allocate explicitly in PSRAM:

```swift
if let ptr = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 4, in: .psram) {
    ptr.deallocate()
}
```

Or use fallback allocation:

```swift
if let ptr = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 4, in: .psramIfAvailable) {
    ptr.deallocate()
}
```

How it behaves:

- If `PSRAMConfiguration` is present and initialization succeeds, a PSRAM allocator is registered.
- `.psram` allocations require a PSRAM allocator and fail if unavailable.
- `.psramIfAvailable` prefers PSRAM and falls back to SRAM when PSRAM is not registered.
- The Example keeps this opt-in commented by default because not all boards include external PSRAM.

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

#### Multicore Concurrency

On RP2350 targets, core1 is optional for Swift concurrency. `EmbeddedAsyncApp`
starts core1 for the Swift concurrency scheduler after `configure(with:)` has
run and before `setup()` is awaited, unless you disable it:

```swift
static func configure(with configurator: inout Configurator) {
    configurator.core1Enabled = false
}
```

When core1 is disabled, Swift concurrency still works on core0. That gives apps
an escape hatch for systems where core1 is better reserved for a tight
time-sensitive flow, such as a dedicated control loop, protocol bridge, sampling
routine, or other code that should not share a scheduler run loop. In that mode,
you can launch and manage core1 yourself using the Pico SDK multicore APIs while
allowing Swift async tasks, timers, continuations, and scheduler pumping to
coexist on core0.

The scheduler does not launch core1 from task enqueue paths. Until
`startMulticore()` is called, Swift concurrency work stays on core0. If you are
not using `EmbeddedAsyncApp`, multicore startup is explicit. After your app has
initialized CPicoSDK and sealed any configuration, call:

```swift
ConcurrencyRuntime.startMulticore()
```

Only call `ConcurrencyRuntime.startMulticore()` when core1 belongs to the Swift
concurrency scheduler. If you plan to use core1 for your own dedicated runtime,
do not call it.

#### Scheduler Stack Sizes

CPicoSDK sizes the scheduler stacks during finalization. The prepared
environment exports these variables to the finalizer:

```bash
export CPICOSDK_CORE0_STACK_SIZE_BYTES=8192
export CPICOSDK_CORE1_STACK_SIZE_BYTES=8192
```

Set them before `prepare-rp2xxx-environment` runs, or uncomment/change them in
your project's `build.sh`. Values are byte counts. Core0 must be greater than
zero. Core1 may be set to zero. The same values are passed into both the SwiftPM
C/Swift build and the final CMake/link step, so stack sizing affects compiled
code and linker symbols consistently.

```bash
export CPICOSDK_CORE1_STACK_SIZE_BYTES=0
```

When core1 stack size is zero, CPicoSDK compiles out the scheduler core1 stack
allocation and core1 launch path. Calling `ConcurrencyRuntime.startMulticore()`
then leaves the scheduler on core0; it does not start core1 and does not print a
warning.

The finalizer also makes the exported linker stack symbols match the actual
scheduler stacks. Placement is selected from the requested sizes:

- If core0 is 4 KiB or smaller, core0 is placed in `SCRATCH_Y`.
- If core0 is larger than 4 KiB and no larger than 8 KiB, core0 uses the
  contiguous `SCRATCH_X` + `SCRATCH_Y` range. In this mode core1 is placed in
  main RAM so core0 can keep the scratch banks as one bus-independent stack.
- If core0 is larger than 8 KiB, core0 still ends at the top of `SCRATCH_Y` and
  extends downward through both scratch banks into the top of main RAM. If
  core1 is also enabled, core1 is placed below core0 in main RAM and the heap is
  capped below both stacks.
- When core0 is 4 KiB or smaller and core1 is enabled, core1 starts at the top
  of `SCRATCH_X`. If core1 is larger than 4 KiB, its lower bound extends into
  the top of main RAM and the heap is capped below it.

The exported symbols describe the selected real stack ranges:

```text
__StackBottom / __StackTop       core0 guarded stack
__StackOneBottom / __StackOneTop core1 scheduler stack
```

These symbols intentionally do not describe Pico SDK dummy stack reservations.
Generic runtime code may use them as the canonical stack bounds for stack-limit
checks and diagnostics.

CPU metrics follow the same active-core model. `CPUStats.usageEvents()` emits
reports for scheduler-managed cores. With core1 disabled or not yet started, the
combined stream only produces core0 reports. Per-core subscriptions such as
`CPUStats.usageEvents(for: .core1)` will not produce useful samples until core1
has been started for the scheduler.

CPU metrics are also compile-time gated by the `CPUMetrics` trait. Without that
trait, the metrics APIs return `nil`, even if concurrency itself is enabled.

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
- ⚠️ **Limited support**: Pico (RP2040), Pico W (RP2040 + CYW43439) - Concurrency is not available for this platform.
- 🚧 **In progress**: More RP2xxx boards and configuration combinations are actively being developed
- 🔍 **Debugging**: Currently using `cortex-debug` in VSCode, following the proven pico-vscode approach.  LLDB support is being worked on but requires additional development time.

### Board/Trait Matrix (Temporary)

This matrix is temporary while we work on a more generic approach that ties traits to non-specific board configurations.

| Board | Combination | Platform Trait | Variant Trait | Radio Trait |
| --- | --- | --- | --- | --- |
| Pico | `pico` | `Platform_RP2040` | `Variant_RP2040` | `Radio_None` |
| Pico W | `pico_w` | `Platform_RP2040` | `Variant_RP2040` | `Radio_CYW43439` |
| Pico 2 | `pico2` | `Platform_RP2350` | `Variant_RP2350A` | `Radio_None` |
| Pico 2 W | `pico2_w` | `Platform_RP2350` | `Variant_RP2350A` | `Radio_CYW43439` |
| Pimoroni Pico Plus 2 | `pimoroni_pico_plus2_rp2350` | `Platform_RP2350` | `Variant_RP2350B` | `Radio_None` |
| Pimoroni Pico Plus 2 W | `pimoroni_pico_plus2_w_rp2350` | `Platform_RP2350` | `Variant_RP2350B` | `Radio_CYW43439` |

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
            url: "https://github.com/gonzalolarralde/CPicoSDK", exact: "2.2.7",
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

3. **Build, and optionally flash** (see the Example directory for the complete
   launcher):

```bash
SWIFTPM_BIN_DIR=/absolute/path/to/pr-build/Products/Debug ./build.sh --flash
```

The launcher keeps the user-controlled settings near the top, makes one small
preparation-plugin call, requests the SwiftPM product build, and optionally
invokes the flash plugin. Native compilation and firmware finalization are
declared SwiftPM tasks rather than shell-script build stages.

### VSCode Integration

When you run the environment preparation step, CPicoSDK automatically generates:

- **`.vscode/tasks.json`**: build and flash tasks
- **`.vscode/launch.json`**: Debug configurations for cortex-debug
- **`.vscode/extensions.json`**: recommended embedded-development extensions

The destination toolset is contained inside the dependency-owned staged Swift
SDK. Preparation does not generate a root `toolset.json`, rewrite
`.swift-version`, or create a legacy SourceKit configuration.

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

The user-facing build is plugin-owned. `Example/build.sh` is only a short
bootstrap wrapper around destination preparation, one SwiftPM build request,
and optional flashing. CPicoSDK's external builders declare the native archive
and automatic post-product firmware finalizer inside SwiftPM's build graph.
The separate root `build.sh` remains a maintainer utility for regenerating the
checked-in compound headers and manifest.

### Configurator Execution Model

The configuration system is built around `Configuration` values collected by `Configurator`.

Current flow:

1. App code adds configuration values via `configurator.configure(...)`.
2. Values are stored as `AnyConfiguration` and type-erased through `UnsafeWeaklyTypedContainer`.
3. During `sealConfiguration()`, CPicoSDK executes configuration closures and allows those executions to append additional configurations.
4. Sealing uses a pending-ID loop: newly discovered configuration IDs are processed in later passes.
5. Once sealing completes, the result is frozen into static storage (`Configurator.configurations`) for runtime queries.

Important current behavior:

- Multiple instances under a configuration ID are all executed when that ID is processed.
- If execution appends a brand-new ID, it is picked up in a later pass of the same sealing operation.
- If execution appends additional instances under an ID that was already processed, those new instances are not re-processed in the current pass model.

Error model:

- Each configuration execution wraps typed errors into `ConfigurationError`.
- Sealing accumulates execution failures and returns them as `[ConfigurationError]`.
- Callers can then pass the returned errors to `handleConfigurationErrors`, and execution continues according to that handling path.

This design intentionally favors deterministic staged setup over open-ended re-execution loops.

### Allocator Model (Maintainers)

CPicoSDK allocator routing is currently configuration-driven and address-space based.

Core pieces:

- `Allocator` is itself a `Configuration` that registers function pointers/closures for `malloc`, `calloc`, `realloc`, `free`, and stats.
- `AllocatorManager` owns a mutex-protected linked-list registry of allocators.
- Address-space dispatch uses `Allocator.addressSpaceMask` to resolve which allocator owns a pointer.
- SRAM allocator is always present as the built-in default.
- The PSRAM backend uses [TLSF](https://github.com/espressif/tlsf) as its heap engine (`tlsf_create_with_pool`, `tlsf_malloc`, `tlsf_realloc`, `tlsf_free`) for low-overhead dynamic allocation in external RAM.
- `PSRAMAllocator` implementation and QMI setup flow are a Swift reimplementation of [SparkFun's Pico](https://github.com/sparkfun/sparkfun-pico) memory allocation library.

Registration flow:

1. Feature configs (for example `PSRAMConfiguration`) create/register an `Allocator` during execution.
2. `AllocatorManager.register` rejects overlapping masked address spaces.
3. Allocators are used by wrapped allocation entrypoints (`__wrap_malloc`, `__wrap_calloc`, `__wrap_realloc`, `__wrap_free`).

Dispatch behavior:

- New allocations default to SRAM for plain malloc/calloc.
- `realloc/free` choose allocator by pointer address.
- High-level typed APIs (for example explicit `.psram` and `.psramIfAvailable` allocation modes) choose allocator policy before calling into the low-level wrappers.

Recent allocator integration updates:

- `free` now consistently resolves the owning allocator from the pointer address space before dispatching, so pointers allocated from PSRAM-backed allocators are released by the correct backend automatically.
- `calloc` participates in the same allocator model, so zero-initialized allocations can be served by non-SRAM allocators when selected by higher-level allocation policy.
- Together, this keeps allocation/deallocation symmetric across mixed memory spaces and avoids requiring callers to manually track allocator provenance.

Unsafe mutable pointer ergonomics:

- Because allocator selection is routed through CPicoSDK allocation wrappers, `UnsafeMutableRawPointer` and typed `UnsafeMutablePointer` families can use allocation APIs with memory-space intents (`.psram`, `.psramIfAvailable`) without changing deallocation call sites.
- This gives consumers a seamless experience: choose memory space at allocation time, then use normal pointer deallocation paths while backend routing remains correct.

Concurrency and safety notes:

- Allocation wrappers use explicit locking/exception-level-aware reentrancy rules to mirror Pico SDK expectations.
- PSRAM allocator initialization remains guarded by a mutex-backed singleton path.

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
4. Consumed by the external native builder and automatic post-product firmware
   finalizer

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

Located at `Support/FirmwareFinalizer/CMakeHarness/shims.c`, this file provides
**POSIX compatibility shims** for functions that the Swift runtime expects but
aren't provided by the bare-metal ARM toolchain.

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

### SwiftPM Plugins

CPicoSDK uses SwiftPM plugins to orchestrate the build and inspect generated
artifacts:

#### 1. **PrepareEnvironmentPlugin** (`prepare-rp2xxx-environment`)

**Purpose**: Set up the complete build environment

**What it does**:
- Merges base vars and combination overrides from `env.json` with user overrides
- Resolves variable substitutions (e.g., `${HOME}`, `${PICO_SDK_PATH}`)
- Downloads dependencies via PicoSDKDownloader
- Stages and validates a relocatable Swift SDK containing the Pico payload and
  matching Embedded Swift runtime; that SDK contains its ARM toolset
- Selects the compiler snapshot pinned by
  `SwiftSDK/ExternalPreviewSDK/swift-toolchain.txt`
- Writes VSCode task, extension, and launch configurations
- Outputs a small shell-readable environment file for the launcher

It does not create a root `toolset.json`, mutate `.swift-version`, or generate
legacy SourceKit settings.

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

#### 3. **CPicoFirmwareBuilder**

**Purpose**: Declare native support and post-product firmware assembly in
SwiftPM's external build graph

**What it does**:
- Builds CPicoSDK's native support archive before the Swift product
- Takes the completed Swift static product supplied by SwiftPM
- Links them with Pico SDK libraries using the CMake harness
- Detects when the final link needs extra embedded Swift runtime archives and adds them automatically
- Embeds `.codeasset` resources by passing generated name/path lists into the CMake harness
- Runs firmware assembly as an automatic `.postProduct` external task
- Includes `shims.c` for runtime compatibility
- Generates both ELF (for debugging) and UF2 (for flashing) binaries
- Prints final artifact file sizes, including the raw `.bin` flash payload, UF2
  transfer file size, and host ELF debug file size
- Prints the CPicoSDK memory map report for the finalized ELF, including
  flash/static-RAM/heap/stack usage and ownership by source
- Leaves device programming to the separate explicit `FlashFirmware` command
  plugin

**Why it's necessary**: The Swift static library must still be combined with
Pico startup code, linker scripts, native libraries, runtime archives, and
format conversion. The external-task API lets SwiftPM own that dependency edge
instead of a shell script calling a finalizer after the build.

#### 4. **FlashFirmware** (`flash-rp2xxx-binary`)

**Purpose**: Program an already-finalized UF2 only when the user explicitly
requests it

`Example/build.sh --flash` invokes this command plugin after a successful build.
A normal build never programs hardware. The plugin waits at most 60 seconds by
default for a compatible device; set `CPICOSDK_FLASH_WAIT_SECONDS` to change
that bounded wait. Set `CPICOSDK_PICOTOOL_SERIAL` to select one device by its
picotool serial when multiple devices may be attached.

#### 5. **AssetCompiler** (`AssetCompiler`)

**Purpose**: Generate Swift accessors for target-local `.codeasset` files

**What it does**:
- Scans the consuming target's source files for `.codeasset` resources
- Generates an `Asset.<name>` accessor for each file
- Declares the objcopy-provided `_binary_<resource>_start` and `_binary_<resource>_end` symbols
- Builds each accessor as an `UnsafeRawBufferPointer` over those linker symbols
- Emits a small sidecar Swift file with source metadata for the plugin output

The finalizer gathers the same resources and passes their names and absolute paths into the CMake harness. `embed_resources.cmake` stages each file under its resource name before running `objcopy`; this keeps the generated linker symbols predictable and aligned with the names generated by `AssetCompilerTool`.

Embedded resource objects are created with:

```cmake
${CMAKE_OBJCOPY} -I binary -O elf32-littlearm -B arm \
    --rename-section .data=.rodata.cpicosdk_assets,alloc,load,readonly,data,contents \
    <resource-name> <resource-object>
```

The section rename is important. Plain `objcopy -I binary` emits a writable `.data` section, which the Pico linker treats as initialized SRAM. Renaming it to a read-only section keeps the resource bytes in flash while still exposing normal linker symbols to Swift.

#### 6. **MemoryMapReportPlugin** (`memory-map-report`)

**Purpose**: Report flash/RAM usage for an existing finalized ELF without
building or flashing.

Run it from a prepared consumer package after `./build.sh` or after the
finalizer has produced an ELF:

```sh
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox memory-map-report
```

The plugin looks for `.env_prep` first, then uses `SWIFTPM_PRODUCT`,
`SWIFTPM_TRIPLE`, `SWIFT_BUILD_TYPE`, `BOARD`, and the prepared ARM toolchain to
find the existing ELF, linker map, `arm-none-eabi-size`, and
`arm-none-eabi-nm`. It does not invoke SwiftPM build or CMake. If no ELF exists,
it prints a build-first message.

You can override artifact paths when inspecting another output:

```sh
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox memory-map-report \
  .build/out/Products/Release-none-armv7em/Example.elf

"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox memory-map-report \
  --elf .build/out/Products/Release-none-armv7em/Example.elf \
  --map .build/out/Products/Release-none-armv7em/Example.elf.map
```

When only an ELF path is provided, the tool first checks the ELF directory for a
matching sibling map file, such as `Example.elf.map` or `Example.map`. A second
positional path or `--map` can be used to select a different linker map.

The report starts with a small summary in KiB, then shows ownership grouped by
user program, CPicoSDK, CPicoConcurrency, Pico SDK, Swift runtime, and C/C++
runtime. Ownership comes from linker-map object paths, so it is most useful
when the finalizer map is present. Without a map, the command still reports ELF
sections, stack symbols, and heap headroom, but source ownership is unavailable.

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
- multicore concurrency depends on a Swift build/runtime that supports the
  embedded threading hooks used by `ConcurrencyShims`
- the low-level runtime hook exports remain in [Sources/ConcurrencyShims/ConcurrencyShims.c](Sources/ConcurrencyShims/ConcurrencyShims.c)
- the scheduling backend now lives in [Sources/CPicoConcurrency/RuntimeScheduler.swift](Sources/CPicoConcurrency/RuntimeScheduler.swift)
- that scheduler uses Pico SDK `async_context` rather than a handwritten queue loop
- on Linux, the build can fall back to vendored embedded `_Concurrency` artifacts under [Vendor/EmbeddedSwiftRuntime](/Users/gonzalo/src/CPicoSDK/Vendor/EmbeddedSwiftRuntime) when the toolchain packaging is incomplete

Maintainer note: the concurrency path is not using an arbitrary stock embedded
Swift runtime in isolation. Multicore scheduler support relies on a modified
Swift build with embedded threading support, plus the matching shim symbols in
`Sources/ConcurrencyShims`. If `SWIFT_VERSION` is changed in `env.json`, and
concurrency support is expected to keep working, the replacement Swift snapshot
must include the same threading/runtime support or an equivalent update to the
shims and vendored fallback artifacts. A plain snapshot that can compile
Embedded Swift code is not enough to prove multicore concurrency is supported.

The current state is best described as:

- generic embedded `async`/`await` works
- the implementation is not considered stable yet
- custom executors are still not viable on this embedded runtime
- exploratory pieces like `@CPU0Actor` and `@CPU1Actor` exist as future-facing scaffolding, not as working CPU pinning support

The Linux fallback is intentionally versioned by `SWIFT_VERSION`. The build only uses a vendored runtime directory when the active Swift snapshot has a matching directory name, which avoids silently mixing concurrency runtime files from different toolchains.

Concurrency support for RP2040 is not available yet.

The Example is expected to keep representing an important behavioral constraint:

- a tight `while true { ... }` loop still needs some kind of yielding or scheduler pumping so non-awaiting code does not lock the CPU

For the detailed investigation history, current architecture, and known limitations, see:

- [Docs/CONCURRENCY_NOTES.md](/Users/gonzalo/src/CPicoSDK/Docs/CONCURRENCY_NOTES.md)

### Plugin-Owned Build Orchestration

`Example/build.sh` is intentionally limited to user configuration, a small
prepare call, the build request, a note that finalization is automatic, and an
optional flash call. The implementation behind those phases lives in Swift
tools and SwiftPM plugins:

- `PrepareEnvironmentPlugin` provisions and selects the destination SDK before
  package planning.
- `CPicoNativeBuilderPlugin` declares the native CMake/Ninja archive task.
- `CPicoFirmwareFinalizerPlugin` declares firmware assembly after the static
  Swift product is available.
- `FlashFirmwarePlugin` performs the explicit device operation.

The Swift tools may invoke CMake, Ninja, GNU ARM tools, or picotool as owned
child processes. That is different from treating a shell launcher as the build
system: SwiftPM sees the declared inputs, outputs, and producer/consumer edges,
and the application launcher does not duplicate dependency-owned logic.

### File Structure

```
CPicoSDK/
├── Package.swift                          # Canonical tools-version 6.5 manifest
├── Package.swift.template                 # Template used to generate Package.swift
├── env.json                               # Central configuration
├── generator_vars.json                    # Available hardware options and libraries
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
│   ├── CPicoNativeBuilderPlugin/          # External native archive task
│   ├── CPicoFirmwareFinalizerPlugin/      # Automatic post-product task
│   └── FlashFirmwarePlugin/               # Explicit programming command
├── External/
│   └── CPicoNativeSupport/                # Declared external native product
├── Support/
│   └── FirmwareFinalizer/CMakeHarness/
│       ├── CMakeLists.txt                 # CMake project for firmware linking
│       └── shims.c                        # POSIX compatibility layer
├── SwiftSDK/
│   └── ExternalPreviewSDK/                # Relocatable SDK templates + compiler pin
└── Example/
    ├── Package.swift                      # Example project consuming CPicoSDK
    ├── cpicosdk-build.json                # Consumer-owned build policy
    ├── build.sh                           # Sole user-facing build launcher
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

1. Build the patched `swift-package` and `swift-build` products from SwiftPM PR
   #10198.
2. Add CPicoSDK as a dependency and attach `CPicoFirmwareBuilder` to the static
   firmware target.
3. Point `SWIFTPM_BIN_DIR` at the directory containing those sibling products
   and run the application's small `build.sh` launcher.
4. Develop Swift code with full IDE support.
5. Pass `--flash` only when explicitly programming hardware.

### Device Test Harness

CPicoSDK includes a physical-device test harness for maintainer and contributor
validation. Tests live under `Tests/Device/**/*.swift` and are run from the
repository root with:

```bash
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox test-in-device --allow-writing-to-package-directory --allow-network-connections all
```

Device execution defaults to local OpenOCD, preserving the original device-test
command behavior. HardwareRunner configuration is not parsed or validated for
local, `--list`, or `--build-only` runs.

Pass `--remote` to dispatch a physical run to HardwareRunner, and configure it
with:

```bash
export HARDWARE_RUNNER_URL="http://hardware-runner.example:8080"
export HARDWARE_RUNNER_TOKEN="hr_..."
export HARDWARE_RUNNER_PROFILE_ID="00000000-0000-0000-0000-000000000000"
# Optional when the token/profile can access only one matching pool:
export HARDWARE_RUNNER_POOL_ID="00000000-0000-0000-0000-000000000000"
export HARDWARE_RUNNER_CAPABILITIES="rp2350,cmsis-dap,rtt"
# Optional; defaults to "rtt":
export HARDWARE_RUNNER_CAPTURE_CHANNEL="rtt"
```

The equivalent command-line options are `--hardware-runner-url`,
`--hardware-runner-token`, `--hardware-runner-profile-id`,
`--hardware-runner-pool-id`, `--hardware-runner-capabilities`, and
`--hardware-runner-capture-channel`. Command-line values override environment
values. Prefer the environment for the bearer token so it does not appear in
process listings. These values are required or validated only for a physical
`--remote` execution.

For example, run one test remotely with:

```bash
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox test-in-device --remote --filter HelloRTT \
  --allow-writing-to-package-directory --allow-network-connections all
```

`CPICOSDK_DEVICE_TEST_EXECUTION=local|remote` provides the environment
equivalent; `--execution local|remote` and the `--local` compatibility alias are
also accepted. Explicit command-line selection overrides the environment.
`--list` and `--build-only` never require HardwareRunner credentials, even when
remote execution is selected in the environment.

The outer `--disable-sandbox` is required for direct probe access in local mode.
The network permission is required for HardwareRunner and may also be needed to
download build dependencies.

Device tests are self-contained Swift files with a leading `//%` metadata block
followed by top-level no-argument test functions:

```swift
//% -- test yaml
//% name: HelloRTT
//% timeout: 5s
//% buildType: RelWithDebInfo
//% traits:
//%   add: [StdIO_RTT]
//% expect:
//%   stdout:
//%     equals: "hello\n"
//%   durationMs:
//%     min: 0
//%     max: 5000
//% -----------

import CPicoSDK

func helloRTT() throws {
    print("hello")
    try deviceExpect(1 + 1 == 2)
}
```

`buildType` is optional and defaults to `Debug`. Supported values are `Debug`,
`Release`, `RelWithDebInfo`, and `MinSizeRel`; benchmark-style tests should
usually use `Release`.

Useful commands:

```bash
# List discovered device tests
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox test-in-device --list --allow-writing-to-package-directory --allow-network-connections all

# Generate and build all device-test firmware without flashing/running it
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox test-in-device --build-only --allow-writing-to-package-directory --allow-network-connections all

# Run one test by name
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox test-in-device --filter HelloRTT --allow-writing-to-package-directory --allow-network-connections all

# Generate and build one device-test firmware without flashing/running it
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox test-in-device --filter HelloRTT --build-only --allow-writing-to-package-directory --allow-network-connections all

# Override test metadata and build all device-test firmware as Release
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox test-in-device --build-type Release --build-only --allow-writing-to-package-directory --allow-network-connections all

# Print a memory map report for each finalized device-test ELF
"$SWIFTPM_BIN_DIR/swift-package" --disable-sandbox test-in-device --filter HelloRTT --build-only --memory-map-report --allow-writing-to-package-directory --allow-network-connections all
```

Use `--build-only` when you want to verify that device tests still generate,
compile, and link without programming hardware. Add `--memory-map-report` to
print the memory report for each finalized test ELF. Full device runs require a
connected target and will program and reset it.

The harness reuses a generated SwiftPM package per target in the plugin work
directory and builds it against the local CPicoSDK checkout. In remote mode it
first stages all selected firmware, uploads each unique ELF, and submits one
`fair` HardwareRunner job with one work item per selected test. `--passes N`
sets that work item's `runs` value to `N`; HardwareRunner returns a separately
attributed capture for each 1-based run index, and the harness parses every run
with the same per-pass labels, failures, and score statistics as local mode.
For each successful run it also prints a machine-readable HardwareRunner
attribution line containing the job, work-item, caller-item, run-index, and
attempt identifiers.
Repeated runs reuse the test's immutable object and bundle.
Independent items may fan out across compatible devices; one connected device
runs them sequentially through its mutex. Job submission uses one idempotency
key and retries transient transport, HTTP 408/429, an equivalent in-progress
idempotency claim, and server failures three times after the initial attempt.
Once submitted, temporary polling failures do not abandon the queued hardware
work. The client rejects batches above HardwareRunner's 10,000-logical-run
per-job limit before uploading any artifacts.

Remote output identifies the durable HardwareRunner job as soon as dispatch
succeeds. While the job is queued, the harness reports HardwareRunner's
best-effort device-start estimate without calculating an independent local ETA;
repeated estimates are coalesced into useful time buckets to keep CI logs
readable. It reports again when HardwareRunner starts the job. Older servers
that do not provide queue estimates remain supported and are reported as such.

HardwareRunner reports infrastructure outcomes only. The harness downloads the
authoritative raw RTT stream and feeds it through the same
`DeviceResultParser` and controller-side expectations used by local OpenOCD
execution. Result lines report build, queue (when remote), program, host
run/capture time, device-reported time, UF2 firmware size, and per-function
pass/fail status.

One source file can define multiple build variants with an optional `alts:`
metadata block. Each entry expands into a separate generated device test named
`<name>-<altName>`. Alternatives can add/remove package traits and provide
Swift compile definitions for `#if`-guarded test behavior:

```swift
//% alts:
//%   - name: baseline
//%     swiftDefines: [BENCH_BASELINE]
//%   - name: cpuMetrics
//%     traits:
//%       add: [CPUMetrics]
//%     swiftDefines: [BENCH_CPU_METRICS]
```

If a test file contains any `async` top-level test function, the harness
automatically uses the async runner and links `CPicoConcurrency`; sync functions
in the same file still run normally. Swift Testing syntax (`import Testing`,
`@Test`, `#expect`) is intentionally not supported by this embedded harness yet;
use `deviceExpect(...)` for device-side assertions.

### Future Improvements

See `TODO.md` for detailed tasks, including:
- Moving more bash logic into Swift plugins
- Supporting multiple boards and configurations via traits
- Migrating from compound header to per-library targets
- LLDB integration for debugging
- Better handling of build types and debug symbols

### Contributing

Contributions are welcome! Key areas of interest: 
- ~🎯 Adding support for more RP2xxx boards (Pico, Pico W, Pico 2, etc.)~ Done! Thanks @BastianKusserow
- 🐛 Improving LLDB integration for debugging
- ⚡ Optimizing the header generation process
- 🧪 Adding test coverage

---

## Acknowledgments

This project builds upon the excellent work of: 
- The Raspberry Pi Pico SDK team
- The pico-vscode extension developers
- The Swift Embedded community
- **TLSF** — Two-Level Segregated Fit allocator, BSD License, written by Matthew Conte (matt@baisoku.org). Used as the heap engine for PSRAM-backed dynamic memory allocation.
- **sparkfun-pico** — MIT License, Copyright (c) 2024 SparkFun Electronics. The `PSRAMAllocator` QMI setup and PSRAM initialization flow are heavily inspired by this library.

---

**Happy embedded Swift hacking!  🚀**
