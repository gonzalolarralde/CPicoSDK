// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Example",
    products: [
        .library(name: "Example", type: .static, targets: ["Example"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/gonzalolarralde/CPicoSDK",
            .upToNextMinor(from: "2.2.0"),
            traits: [
                .init(name: "Platform_RP2350"),
                .init(name: "BootStage2_W25Q080"),
            ]
        ),
    ],
    targets: [
        .target(
            name: "Example",
            dependencies: ["CPicoSDK"]
        ),
    ]
)
