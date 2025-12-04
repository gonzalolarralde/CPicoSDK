// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Example",
    products: [
        .library(name: "Example", type: .static, targets: ["Example"]),
    ],
    dependencies: [
        .package(
            // Helpful for local development while making changes to the SDK layer.
            path: "../",

            // url: "https://github.com/gonzalolarralde/CPicoSDK",
            // branch: "main",

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
