// swift-tools-version: 6.5

import PackageDescription

// This versioned manifest exercises SwiftPM's external-package prototype from
// swift-package-manager#10198. Released SwiftPM versions continue to select
// Package.swift and use the established native build pipeline.
let package = Package(
    name: "Example",
    products: [
        .library(name: "Example", type: .static, targets: ["Example"]),
    ],
    dependencies: [
        .package(
            path: "../",
            traits: [
                .init(name: "BootStage2_W25Q080"),
                .init(name: "StdIO_Automatic"),
                .init(name: "CPUMetrics"),

                // MARK: - RP2350
                .init(name: "Platform_RP2350"),

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

                // MARK: - RP2040
                // .init(name: "Platform_RP2040"),

                // - Pico
                // .init(name: "Variant_RP2040"),
                // .init(name: "Radio_None"),

                // - Pico W
                // .init(name: "Variant_RP2040"),
                // .init(name: "Radio_CYW43439"),
            ]
        ),
        .externalSource(
            name: "CPicoNative",
            path: "External/CPicoNativeSupport"
        ),
    ],
    externals: [
        Package(
            name: "CPicoNative",
            products: [
                .library(
                    name: "CPicoNativeSupport",
                    type: .static,
                    targets: ["CPicoNativeSupport"]
                ),
            ],
            targets: [
                .externalLibrary(
                    name: "CPicoNativeSupport",
                    plugins: ["CPicoNativeBuilderPlugin"]
                ),
            ]
        ),
    ],
    targets: [
        .target(
            name: "Example",
            dependencies: [
                .product(name: "CPicoSDK", package: "CPicoSDK"),
                .product(name: "CPicoConcurrency", package: "CPicoSDK"),
                .product(name: "PSRAM", package: "CPicoSDK"),
                .product(name: "CPicoNativeSupport", package: "CPicoNative"),
            ],
            plugins: [
                .plugin(name: "PIOASM", package: "CPicoSDK"),
                .plugin(name: "AssetCompiler", package: "CPicoSDK"),
                "CPicoFirmwareFinalizerPlugin",
            ]
        ),
        .target(name: "CPicoExternalBuildSupport"),
        .executableTarget(
            name: "CPicoNativeBuilder",
            dependencies: ["CPicoExternalBuildSupport"]
        ),
        .executableTarget(
            name: "CPicoFirmwareFinalizerAdapter",
            dependencies: ["CPicoExternalBuildSupport"]
        ),
        .plugin(
            name: "CPicoNativeBuilderPlugin",
            capability: .externalBuilder,
            dependencies: ["CPicoNativeBuilder"]
        ),
        .plugin(
            name: "CPicoFirmwareFinalizerPlugin",
            capability: .externalBuilder,
            dependencies: [
                "CPicoFirmwareFinalizerAdapter",
                .product(name: "FirmwareFinalizerTool", package: "CPicoSDK"),
                .product(name: "MemoryMapReportTool", package: "CPicoSDK"),
            ]
        ),
    ]
)
