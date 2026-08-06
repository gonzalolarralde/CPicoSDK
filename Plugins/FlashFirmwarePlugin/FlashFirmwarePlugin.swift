import Foundation
import PackagePlugin

@main
struct FlashFirmwarePlugin: CommandPlugin {
    enum PluginError: Swift.Error, CustomStringConvertible {
        case missingEnvironment(String)
        case missingOptionValue(String)
        case unsupportedProducts(String)
        case toolFailed(Int32)
        case unknownOption(String)

        var description: String {
            switch self {
            case .missingEnvironment(let name):
                return "Missing environment value \(name). Run prepare-rp2xxx-environment and source its output first."
            case .missingOptionValue(let option):
                return "Expected a value after \(option)."
            case .unsupportedProducts(let details):
                return "Expected one static firmware product: \(details)"
            case .toolFailed(let status):
                return "The firmware flash tool exited with status \(status)."
            case .unknownOption(let option):
                return "Unknown option: \(option)"
            }
        }
    }

    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        var productName: String?
        var configuration = "release"
        var waitSeconds = environment["CPICOSDK_FLASH_WAIT_SECONDS"] ?? "60"
        var serial = environment["CPICOSDK_PICOTOOL_SERIAL"]
        var scratchPath = context.package.directoryURL.appending(
            path: ".build",
            directoryHint: .isDirectory
        ).path
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--configuration", "--firmware-scratch-path",
                 "--wait-seconds", "--serial":
                guard index + 1 < arguments.count else {
                    throw PluginError.missingOptionValue(argument)
                }
                let value = arguments[index + 1]
                if argument == "--configuration" {
                    configuration = value
                } else if argument == "--wait-seconds" {
                    waitSeconds = value
                } else if argument == "--serial" {
                    serial = value
                } else {
                    scratchPath = value
                }
                index += 2
            case let option where option.hasPrefix("-"):
                throw PluginError.unknownOption(argument)
            default:
                guard productName == nil else {
                    throw PluginError.unknownOption(argument)
                }
                productName = argument
                index += 1
            }
        }

        let staticProducts = context.package.products(ofType: LibraryProduct.self)
            .filter { $0.kind == .static }
        if productName == nil {
            guard staticProducts.count == 1 else {
                throw PluginError.unsupportedProducts(
                    "found [\(staticProducts.map(\.name).joined(separator: ", "))]"
                )
            }
            productName = staticProducts[0].name
        } else if !staticProducts.contains(where: { $0.name == productName }) {
            throw PluginError.unsupportedProducts(
                "'\(productName ?? "")' is not one of [\(staticProducts.map(\.name).joined(separator: ", "))]"
            )
        }

        guard let swiftSDKsPath = environment["CPICOSDK_SWIFT_SDKS_PATH"],
              !swiftSDKsPath.isEmpty
        else {
            throw PluginError.missingEnvironment("CPICOSDK_SWIFT_SDKS_PATH")
        }
        let tool = try context.tool(named: "CPicoFlashTool")
        let process = Process()
        process.executableURL = tool.url
        var toolArguments = [
            "--package-directory", context.package.directoryURL.path,
            "--scratch-path", scratchPath,
            "--swift-sdks-path", swiftSDKsPath,
            "--product", productName!,
            "--configuration", configuration,
            "--wait-seconds", waitSeconds,
        ]
        if let serial, !serial.isEmpty {
            toolArguments += ["--serial", serial]
        }
        process.arguments = toolArguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginError.toolFailed(process.terminationStatus)
        }
    }
}
