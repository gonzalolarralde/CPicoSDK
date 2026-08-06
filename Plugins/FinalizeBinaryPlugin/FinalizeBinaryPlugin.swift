import Foundation
import PackagePlugin

@main
struct FinalizeBinaryPlugin: CommandPlugin {
    enum Error: Swift.Error, CustomStringConvertible {
        case duplicateEmbeddedResourceName(String)
        case finalizerFailed(Int32)
        case invalidArchivePath(String, String)
        case invalidDirectoryPath(String, String)
        case invalidEmbeddedResourceName(String)
        case invalidEmbeddedResourcePath(String, URL)
        case missingOptionValue(String)

        var description: String {
            switch self {
            case .duplicateEmbeddedResourceName(let name):
                return "Multiple embedded resources would be staged as '\(name)'"
            case .finalizerFailed(let status):
                return "FirmwareFinalizerTool failed with exit status \(status)"
            case .invalidArchivePath(let option, let path):
                return "\(option) must name an existing absolute archive path without CMake list separators, got: \(path)"
            case .invalidDirectoryPath(let option, let path):
                return "\(option) must name an existing absolute directory without CMake list separators, got: \(path)"
            case .invalidEmbeddedResourceName(let name):
                return "Embedded resource name must not be empty or contain path/list separators, got: \(name)"
            case .invalidEmbeddedResourcePath(let name, let url):
                return "Embedded resource '\(name)' must use an absolute file URL without CMake list separators, got: \(url)"
            case .missingOptionValue(let option):
                return "Expected a path after \(option)"
            }
        }
    }

    private struct FinalizationRequest: Encodable {
        struct EmbeddedResource: Encodable {
            let name: String
            let path: String
        }

        let schemaVersion = 1
        let productName: String
        let productArchivePath: String
        let nativeSupportArchivePath: String?
        let pioasmPackageDirectoryPath: String?
        let outputDirectoryPath: String
        let workingDirectoryPath: String
        let cmakeHarnessDirectoryPath: String
        let packageDirectoryPath: String
        let cpicoSDKDirectoryPath: String
        let memoryMapToolPath: String
        let swiftBuildType: String
        let platformTriple: String
        let embeddedResources: [EmbeddedResource]
        let incremental: Bool
        let environment: [String: String]
    }

    func performCommand(
        context: PackagePlugin.PluginContext,
        arguments: [String]
    ) async throws {
        guard let productName = arguments.first else {
            fatalError(
                "[CPicoSDK] Expected at least one argument: a static library product name."
            )
        }

        var remainingArguments = Array(arguments.dropFirst())
        let productArchiveOverride = try consumeArchiveOption(
            "--product-archive",
            from: &remainingArguments
        )
        let nativeSupportArchive = try consumeArchiveOption(
            "--native-support-archive",
            from: &remainingArguments
        )
        let pioasmPackageDirectory = try consumeDirectoryOption(
            "--pioasm-dir",
            from: &remainingArguments
        )
        let incremental = remainingArguments.contains("--incremental")

        guard let cpicoSDKURL = context.package.dependencies.first(where: {
            $0.package.displayName == "CPicoSDK"
        })?.package.directoryURL else {
            fatalError("[CPicoSDK] Couldn't find CPicoSDK in the dependencies.")
        }

        let matchingProducts = context.package.products(ofType: LibraryProduct.self)
        guard let libraryProduct = matchingProducts.first(where: { $0.name == productName }) else {
            fatalError(
                "[CPicoSDK] Couldn't match static library product '\(productName)'. Found: [\(matchingProducts.map(\.name).joined(separator: ","))]"
            )
        }
        guard libraryProduct.kind == .static else {
            fatalError("[CPicoSDK] Only static libraries are supported.")
        }
        guard libraryProduct.sourceModules.count == 1 else {
            fatalError("[CPicoSDK] Only libraries with one target are supported.")
        }

        let swiftBuildType = try processEnvironmentValue("SWIFT_BUILD_TYPE")
        let platformTriple = try processEnvironmentValue("SWIFTPM_TRIPLE")
        let outputDirectory = context.package.directoryURL.appending(
            path: ".build/\(platformTriple)/\(swiftBuildType)"
        )
        let productArchive = productArchiveOverride ?? outputDirectory.appending(
            path: "lib\(libraryProduct.name).a"
        )
        let memoryMapTool = try context.tool(named: "MemoryMapReportTool")
        let finalizerTool = try context.tool(named: "FirmwareFinalizerTool")

        let request = FinalizationRequest(
            productName: libraryProduct.name,
            productArchivePath: productArchive.path,
            nativeSupportArchivePath: nativeSupportArchive?.path,
            pioasmPackageDirectoryPath: pioasmPackageDirectory?.path,
            outputDirectoryPath: outputDirectory.path,
            workingDirectoryPath: context.pluginWorkDirectoryURL.path,
            cmakeHarnessDirectoryPath: cpicoSDKURL.appending(
                path: "Plugins/FinalizeBinaryPluginTool/CMakeHarness"
            ).path,
            packageDirectoryPath: context.package.directoryURL.path,
            cpicoSDKDirectoryPath: cpicoSDKURL.path,
            memoryMapToolPath: memoryMapTool.url.path,
            swiftBuildType: swiftBuildType,
            platformTriple: platformTriple,
            embeddedResources: try getEmbeddedResources(from: libraryProduct),
            incremental: incremental,
            environment: capturedEnvironment()
        )

        let requestURL = context.pluginWorkDirectoryURL.appending(
            path: "firmware-finalization-request.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: .atomic)

        let process = Process()
        process.executableURL = finalizerTool.url
        process.arguments = ["--request", requestURL.path]
        let status = try await process.asyncRun()
        guard status == 0 else {
            throw Error.finalizerFailed(status)
        }
    }

    private func capturedEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let relevantNames = Set(
            (environment["RELEVANT_ENV_VARS"] ?? "")
                .split(separator: ",")
                .map(String.init)
        )
        return environment.filter { key, _ in
            relevantNames.contains(key)
                || key == "RELEVANT_ENV_VARS"
                || key == "AUTO_STDIO"
                || key.hasPrefix("CPICOSDK_")
        }
    }

    private func processEnvironmentValue(_ name: String) throws -> String {
        try ProcessInfo.processInfo.environment[name].expected
    }

    private func consumeArchiveOption(
        _ option: String,
        from arguments: inout [String]
    ) throws -> URL? {
        guard let optionIndex = arguments.firstIndex(of: option) else {
            return nil
        }
        let valueIndex = arguments.index(after: optionIndex)
        guard valueIndex < arguments.endIndex else {
            throw Error.missingOptionValue(option)
        }

        let path = arguments[valueIndex]
        arguments.removeSubrange(optionIndex...valueIndex)
        guard path.hasPrefix("/"),
              !path.contains(";"),
              FileManager.default.fileExists(atPath: path)
        else {
            throw Error.invalidArchivePath(option, path)
        }
        return URL(filePath: path, directoryHint: .notDirectory)
    }

    private func consumeDirectoryOption(
        _ option: String,
        from arguments: inout [String]
    ) throws -> URL? {
        guard let optionIndex = arguments.firstIndex(of: option) else {
            return nil
        }
        let valueIndex = arguments.index(after: optionIndex)
        guard valueIndex < arguments.endIndex else {
            throw Error.missingOptionValue(option)
        }

        let path = arguments[valueIndex]
        arguments.removeSubrange(optionIndex...valueIndex)
        var isDirectory = ObjCBool(false)
        guard path.hasPrefix("/"),
              !path.contains(";"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw Error.invalidDirectoryPath(option, path)
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private func getEmbeddedResources(
        from product: LibraryProduct
    ) throws -> [FinalizationRequest.EmbeddedResource] {
        var resourcesByName: [String: URL] = [:]
        for sourceModule in product.sourceModules {
            for sourceFile in sourceModule.sourceFiles
            where sourceFile.url.pathExtension == "codeasset" {
                let name = sourceFile.url.lastPathComponent
                guard !name.isEmpty,
                      !name.contains("/"),
                      !name.contains("\\"),
                      !name.contains(";")
                else {
                    throw Error.invalidEmbeddedResourceName(name)
                }
                guard sourceFile.url.isFileURL,
                      sourceFile.url.path.hasPrefix("/"),
                      !sourceFile.url.path.contains(";")
                else {
                    throw Error.invalidEmbeddedResourcePath(name, sourceFile.url)
                }
                guard resourcesByName[name] == nil else {
                    throw Error.duplicateEmbeddedResourceName(name)
                }
                resourcesByName[name] = sourceFile.url
            }
        }

        return resourcesByName.keys.sorted().map { name in
            FinalizationRequest.EmbeddedResource(
                name: name,
                path: resourcesByName[name]!.path
            )
        }
    }
}
