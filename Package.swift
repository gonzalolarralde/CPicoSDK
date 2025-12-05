// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CPicoSDK",
    products: [
        .library(name: "CPicoSDK", targets: ["CPicoSDK"]),
        .plugin(name: "FinalizeBinaryPlugin", targets: ["FinalizeBinaryPlugin"]),
    ],
    traits: [
        .trait(name: "Platform_RP2040"),
        .trait(name: "Platform_RP2350"),
        .trait(name: "Platform_RP2350_arm_s"),
        .trait(name: "Platform_RP2350_riscv"),
        .trait(name: "Platform_Host"),

        .trait(name: "BootStage2_W25Q080"),
        .trait(name: "BootStage2_GENERIC_03H"),
        .trait(name: "BootStage2_W25X10CL"),
        .trait(name: "BootStage2_IS25LP080"),
        .trait(name: "BootStage2_AT25SF128A"),

        .trait(name: "FlashSize_16MB"),
        .trait(name: "FlashSize_8MB"),
        .trait(name: "FlashSize_4MB"),
        .trait(name: "FlashSize_2MB"),
        .trait(name: "FlashSize_1MB"),
    ],
    targets: [
        .target(
            name: "_CPicoSDK",
        ),
        .target(
            name: "CPicoSDK",
            dependencies: ["_CPicoSDK"]
        ),
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
            name: "FinalizeBinaryPlugin",
            capability: .command(
                intent: .custom(verb: "finalize-pi-binary", description: "Generates CPicoSDK target files"),
                permissions: [
                    .writeToPackageDirectory(reason: "Finalizes build by linking with pico-sdk and generates UF2 and ELF binaries."),
                ]
            )
        ),
    ]
)
