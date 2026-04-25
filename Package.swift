// swift-tools-version: 6.2

import PackageDescription

// GENERATOR MARK: HEADER
// THIS FILE IS GENERATED. DO NOT EDIT, OTHERWISE CHANGES WILL BE OVERWRITTEN. CHANGE Package.swift.template INSTEAD.

let package = Package(
    name: "CPicoSDK",
    products: [
        .library(name: "CPicoSDK", targets: ["CPicoSDK"]),
        .library(name: "CPicoConcurrency", targets: ["CPicoConcurrency"]),
        .plugin(name: "PIOASM", targets: ["PIOASMPlugin"]),
        .plugin(name: "PrepareEnvironment", targets: ["PrepareEnvironmentPlugin"]),
        .plugin(name: "FinalizeBinary", targets: ["FinalizeBinaryPlugin"]),
    ],
    traits: [
        .trait(name: "CPUMetrics", description: "Enables collection of CPU usage metrics in the runtime scheduler. This may have a small performance impact, but can be useful for debugging and optimization. Metrics are available through `CPUStats`."),

        // TODO: The generator needs to define traits. This needs to be implemented.
        .trait(name: "Platform_RP2350"),
        .trait(name: "Platform_RP2350_arm_s"),
        .trait(name: "Platform_RP2350_riscv"),
        .trait(name: "Platform_Host"),

        .trait(name: "Variant_RP2350A"),
        .trait(name: "Variant_RP2350B"),

        .trait(name: "Radio_None"),
        .trait(name: "Radio_CYW43439"),

        .trait(name: "BootStage2_W25Q080"),
        .trait(name: "BootStage2_GENERIC_03H"),
        .trait(name: "BootStage2_W25X10CL"),
        .trait(name: "BootStage2_IS25LP080"),
        .trait(name: "BootStage2_AT25SF128A"),

        .trait(name: "StdIO_Automatic", description: "Enables stdio through USB when using picotool and UART when using cortex-debug."),
        .trait(name: "StdIO_UART", description: "Enables stdio operations through UART pins"),
        .trait(name: "StdIO_USB", description: "Enables stdio operations through USB"),
        .trait(name: "StdIO_RTT", description: "Enables stdio operations through the RTT debugging protocol"),

        // GENERATOR MARK: TRAITS
    ],
    dependencies: [
        .package(url: "https://github.com/sympatito/PicoSDKDownloader", from: "0.0.4"),
    ],
    targets: [
        // GENERATOR MARK: TARGETS
        .target(name: "_CPicoSDK_pico2"),
        .target(name: "_CPicoSDK_pico2_w"),
        .target(name: "_CPicoSDK_pimoroni_pico_plus2_rp2350"),
        .target(name: "_CPicoSDK_pimoroni_pico_plus2_w_rp2350"),

        // Mixed targets
        .target(
            name: "CPicoSDK",
            dependencies: [
                .target(name: "ARMClib"),
                // GENERATOR MARK: TARGET DEPENDENCIES
                .target(name: "_CPicoSDK_pico2", condition: .when(traits: ["Variant_RP2350A", "Radio_None"])),
                .target(name: "_CPicoSDK_pico2_w", condition: .when(traits: ["Variant_RP2350A", "Radio_CYW43439"])),
                .target(name: "_CPicoSDK_pimoroni_pico_plus2_rp2350", condition: .when(traits: ["Variant_RP2350B", "Radio_None"])),
                .target(name: "_CPicoSDK_pimoroni_pico_plus2_w_rp2350", condition: .when(traits: ["Variant_RP2350B", "Radio_CYW43439"])),
            ],
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),

        // Manually defined targets
        .target(name: "ARMClib"),

        .target(
            name: "CPicoConcurrency",
            dependencies: [
                .target(name: "ConcurrencyShims"),
                .target(name: "CPicoSDK"),
            ]
        ),
        .target(name: "ConcurrencyShims"),

        .plugin(
            name: "PIOASMPlugin", 
            capability: .buildTool,
            dependencies: ["PIOASM", "pioasm-swift"]
        ),
        .binaryTarget(name: "PIOASM", path: "Sources/PIOASM/PIOASM.artifactbundle"),
        .executableTarget(name: "pioasm-swift", path: "Sources/PIOASM/pioasm-swift"),

        .plugin(
            name: "GenerateCPicoSDKPlugin",
            capability: .command(
                intent: .custom(verb: "generate-cpicosdk", description: "Generates CPicoSDK target files"),
                permissions: [
                    .writeToPackageDirectory(reason: "Needs to write CPicoSDK target files, can't generate using prebuildCommand yet because it's a .h header file."),
                ]
            )
        ),
        .plugin(
            name: "PrepareEnvironmentPlugin",
            capability: .command(
                intent: .custom(verb: "prepare-rp2xxx-environment", description: "Ensure environment for CPicoSDK is in place"),
                permissions: [
                    .writeToPackageDirectory(reason: "Returns bash code that prepares the environment for building with CPicoSDK."),
                    .allowNetworkConnections(scope: .all(), reason: "Downloads Pico SDK, ARM toolchain and other dependencies.")
                ]
            ),
            dependencies: [
                .product(name: "pico-bootstrap", package: "PicoSDKDownloader"),
            ]
        ),
        .plugin(
            name: "FinalizeBinaryPlugin",
            capability: .command(
                intent: .custom(verb: "finalize-rp2xxx-binary", description: "Generates CPicoSDK target files"),
                permissions: [
                    .writeToPackageDirectory(reason: "Finalizes build by linking with pico-sdk and generates UF2 and ELF binaries."),
                ]
            )
        ),
    ]
)
