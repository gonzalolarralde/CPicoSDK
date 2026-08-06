import Foundation
import PackagePlugin

@main
struct CPicoFirmwareFinalizerPlugin: ExternalBuilderPlugin {
    enum Error: Swift.Error, CustomStringConvertible {
        case missingDependency(String)
        case missingConfiguration(String)
        case missingProduct(String, package: String)
        case unsupportedProduct(String)

        var description: String {
            switch self {
            case .missingDependency(let name):
                return "The firmware finalizer couldn't find package dependency '\(name)'."
            case .missingConfiguration(let path):
                return "The firmware finalizer requires external build configuration at \(path)."
            case .missingProduct(let name, let package):
                return "The firmware finalizer couldn't find product '\(name)' in package '\(package)'."
            case .unsupportedProduct(let details):
                return "The firmware finalizer requires one static Example library product: \(details)"
            }
        }
    }

    func createExternalBuildCommand(
        context: PluginContext
    ) async throws -> ExternalBuildCommand {
        let exampleProducts = context.package.products(ofType: LibraryProduct.self)
        guard let exampleProduct = exampleProducts.first(where: { $0.name == "Example" }),
              exampleProduct.kind == .static
        else {
            throw Error.unsupportedProduct(
                "found [\(exampleProducts.map(\.name).joined(separator: ", "))]"
            )
        }

        guard let nativePackage = context.package.dependencies.first(where: {
            $0.package.displayName == "CPicoNative"
        })?.package else {
            throw Error.missingDependency("CPicoNative")
        }
        guard let nativeProduct = nativePackage.products.first(where: {
            $0.name == "CPicoNativeSupport"
        }) else {
            throw Error.missingProduct(
                "CPicoNativeSupport",
                package: nativePackage.displayName
            )
        }

        guard let cpicoSDKPackage = context.package.dependencies.first(where: {
            $0.package.displayName == "CPicoSDK"
        })?.package else {
            throw Error.missingDependency("CPicoSDK")
        }

        let adapter = try context.tool(named: "CPicoFirmwareFinalizerAdapter")
        let finalizer = try context.tool(named: "FirmwareFinalizerTool")
        let memoryMap = try context.tool(named: "MemoryMapReportTool")
        let packageDirectory = context.package.directoryURL
        let cpicoSDKDirectory = cpicoSDKPackage.directoryURL
        let harnessDirectory = cpicoSDKDirectory.appending(
            path: "Plugins/FinalizeBinaryPluginTool/CMakeHarness",
            directoryHint: .isDirectory
        )
        let configurationFile = packageDirectory.appending(
            path: "External/CPicoNativeSupport/build-configuration.json",
            directoryHint: .notDirectory
        )
        guard FileManager.default.fileExists(atPath: configurationFile.path) else {
            throw Error.missingConfiguration(configurationFile.path)
        }

        let embeddedResources = exampleProduct.sourceModules
            .flatMap(\.sourceFiles)
            .map(\.url)
            .filter { $0.pathExtension == "codeasset" }
            .sorted { $0.path < $1.path }

        var arguments = [
            "--product-name", exampleProduct.name,
            "--package-directory", packageDirectory.path,
            "--cpicosdk-directory", cpicoSDKDirectory.path,
            "--cmake-harness-directory", harnessDirectory.path,
            "--working-directory", context.pluginWorkDirectoryURL.path,
            "--finalizer-tool", finalizer.url.path,
            "--memory-map-tool", memoryMap.url.path,
            "--configuration", configurationFile.path,
        ]
        for resource in embeddedResources {
            arguments += [
                "--embedded-resource", resource.lastPathComponent,
                resource.path,
            ]
        }

        var inputFiles = [
            finalizer.url,
            memoryMap.url,
            packageDirectory.appending(
                path: "Package@swift-6.5.swift",
                directoryHint: .notDirectory
            ),
        ]
        inputFiles += embeddedResources
        inputFiles += regularFiles(in: harnessDirectory)
        inputFiles.append(configurationFile)
        inputFiles.append(cpicoSDKDirectory.appending(path: "env.json"))

        return ExternalBuildCommand(
            displayName: "Finalize Example firmware artifacts",
            executable: adapter.url,
            arguments: arguments,
            environment: forwardedEnvironment(),
            placement: .postProduct(exampleProduct),
            inputFiles: deduplicated(inputFiles),
            externalLibraryInputs: [
                .init(
                    package: nativePackage,
                    product: nativeProduct,
                    environmentVariable: "CPICOSDK_NATIVE_SUPPORT_ARCHIVE"
                ),
                .init(
                    package: nativePackage,
                    product: nativeProduct,
                    environmentVariable: "CPICOSDK_PIOASM_PACKAGE_PATH_FILE",
                    outputFileName: "pioasm-package-path.txt"
                ),
            ],
            outputFiles: [
                "Example.elf",
                "Example.uf2",
                "Example.bin",
                "Example.hex",
                "Example.elf.map",
                "Example.dis",
            ]
        )
    }

    private func forwardedEnvironment() -> [String: String] {
        let processEnvironment = ProcessInfo.processInfo.environment
        var names: Set<String> = [
            "AUTO_STDIO",
            "BOARD",
            "BUILD_TYPE",
            "CMAKE_PATH",
            "CPICOSDK_COMBINATION",
            "CPICOSDK_CORE0_STACK_SIZE_BYTES",
            "CPICOSDK_CORE1_STACK_SIZE_BYTES",
            "CPICO_EXTERNAL_STDIO_RTT",
            "CPICO_EXTERNAL_STDIO_UART",
            "CPICO_EXTERNAL_STDIO_USB",
            "IMPORTED_LIBS",
            "IMPORTED_LIBS_MORE",
            "NINJA_PATH",
            "NM_PATH",
            "PICOTOOL_PATH",
            "PICO_SDK_PATH",
            "PICO_TOOLCHAIN_PATH",
            "RELEVANT_ENV_VARS",
            "SDK_VERSION",
            "SWIFTLY_PATH",
            "SWIFT_EXEC",
            "SWIFTPM_TRIPLE",
            "SWIFT_BUILD_TYPE",
            "SWIFT_EMBEDDED_FALLBACK_PATH",
            "SWIFT_TOOLCHAIN_PATH",
            "TOOLCHAIN_VERSION",
        ]

        return Dictionary(uniqueKeysWithValues: names.compactMap { name in
            processEnvironment[name].map { (name, $0) }
        })
    }

    private func regularFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true
            else {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
