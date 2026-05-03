// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Example",
    products: [
        .library(name: "Example", type: .static, targets: ["Example"]),
    ],
    dependencies: [
        .package(
            path: "..",
            traits: [
                .init(name: "Platform_RP2350"),
                .init(name: "BootStage2_W25Q080"),
                .init(name: "StdIO_Automatic"),

                // - Pico 2
                .init(name: "Variant_RP2350A"),
                .init(name: "Radio_None"),

                // - Pico 2 W
                // .init(name: "Variant_RP2350A"),
                // .init(name: "Radio_CYW43439"),

                // - Pimoroni Pico Plus 2
                // .init(name: "Variant_RP2350B"),
                // .init(name: "Radio_None"),

                // - Pimoroni Pico Plus 2 W
                // .init(name: "Variant_RP2350B"),
                // .init(name: "Radio_CYW43439"),
            ]
        ),
    ],
    targets: [
        .target(
            name: "Example",
            dependencies: [
                .product(name: "CPicoSDK", package: "CPicoSDK"),
                .product(name: "CPicoConcurrency", package: "CPicoSDK"),
                .product(name: "PSRAM", package: "CPicoSDK"), // Optional, only needed if using PSRAM.
            ],
            plugins: [
                .plugin(name: "PIOASM", package: "CPicoSDK"),
                .plugin(name: "AssetCompiler", package: "CPicoSDK"),
            ]
        ),
    ]
)
