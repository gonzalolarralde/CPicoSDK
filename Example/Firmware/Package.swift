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
            name: "Firmware",
            dependencies: [.product(name: "Example", package: "Example")],
            path: ".",
            plugins: [.plugin(name: "PicoFirmware", package: "CPicoSDK")]
        ),
    ]
)
