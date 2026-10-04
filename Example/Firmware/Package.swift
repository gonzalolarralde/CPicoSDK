// swift-tools-version: 6.5
import PackageDescription

let package = Package(
    name: "ExampleFirmware",
    dependencies: [
        .package(path: ".."),
        .package(path: "../..", traits: []),
    ],
    targets: [
        .target(
            name: "PicoSDK",
            dependencies: [.product(name: "CPicoSDKConfiguration", package: "CPicoSDK")],
            path: ".",
            plugins: [.plugin(name: "PicoSDKBuild", package: "CPicoSDK")]
        ),
        .target(
            name: "Firmware",
            dependencies: [
                .target(name: "PicoSDK"),
                .product(name: "CPicoSDKConfiguration", package: "CPicoSDK"),
                .product(name: "Example", package: "Example"),
            ],
            path: ".",
            plugins: [.plugin(name: "PicoFirmware", package: "CPicoSDK")]
        ),
    ]
)
