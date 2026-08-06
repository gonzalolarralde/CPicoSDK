import Foundation
import PackagePlugin

@main
struct CPicoFirmwareFinalizerPlugin: ExternalBuilderPlugin {
    private struct ConsumerConfiguration: Decodable {
        let productName: String?
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case invalidConfiguration(String, underlying: Swift.Error)
        case missingConfiguration(String)
        case missingDependency(String)
        case missingProduct(String, package: String)
        case unsupportedProducts(String)

        var description: String {
            switch self {
            case .invalidConfiguration(let path, let underlying):
                return "The firmware finalizer couldn't read configuration at \(path): \(underlying)"
            case .missingConfiguration(let path):
                return "CPICOSDK_BUILD_CONFIGURATION refers to a missing file at \(path)."
            case .missingDependency(let name):
                return "The firmware finalizer couldn't find package dependency '\(name)'."
            case .missingProduct(let name, let package):
                return "The firmware finalizer couldn't find product '\(name)' in package '\(package)'."
            case .unsupportedProducts(let details):
                return "The firmware finalizer needs a unique static library product, or a productName in cpicosdk-build.json: \(details)"
            }
        }
    }

    func createExternalBuildCommand(
        context: PluginContext
    ) async throws -> ExternalBuildCommand {
        let processEnvironment = ProcessInfo.processInfo.environment
        let packageDirectory = context.package.directoryURL
        let configurationFile = try configurationFile(
            packageDirectory: packageDirectory,
            processEnvironment: processEnvironment
        )
        let configuration = try configurationFile.map(loadConfiguration)
        let product = try selectedProduct(
            in: context.package,
            configuredName: configuration?.productName
        )

        guard let cpicoSDKPackage = context.package.dependencies
            .map(\.package)
            .first(where: isCPicoSDKPackage)
        else {
            throw Error.missingDependency("CPicoSDK")
        }
        guard let nativePackage = transitiveDependency(
            from: cpicoSDKPackage,
            matching: isCPicoNativePackage
        ) else {
            throw Error.missingDependency("CPicoNative (through CPicoSDK)")
        }
        guard let nativeProduct = nativePackage.products.first(where: {
            $0.name == "CPicoNativeSupport"
        }) else {
            throw Error.missingProduct(
                "CPicoNativeSupport",
                package: nativePackage.displayName
            )
        }

        let adapter = try context.tool(named: "CPicoFirmwareFinalizerAdapter")
        let finalizer = try context.tool(named: "FirmwareFinalizerTool")
        let memoryMap = try context.tool(named: "MemoryMapReportTool")
        let cpicoSDKDirectory = cpicoSDKPackage.directoryURL
        let harnessDirectory = cpicoSDKDirectory.appending(
            path: "Plugins/FinalizeBinaryPluginTool/CMakeHarness",
            directoryHint: .isDirectory
        )
        let workingDirectory = context.pluginWorkDirectoryURL.appending(
            path: product.name,
            directoryHint: .isDirectory
        )

        let embeddedResources = product.sourceModules
            .flatMap(\.sourceFiles)
            .map(\.url)
            .filter { $0.pathExtension == "codeasset" }
            .sorted { $0.path < $1.path }

        var arguments = [
            "--product-name", product.name,
            "--package-directory", packageDirectory.path,
            "--cpicosdk-directory", cpicoSDKDirectory.path,
            "--cmake-harness-directory", harnessDirectory.path,
            "--working-directory", workingDirectory.path,
            "--finalizer-tool", finalizer.url.path,
            "--memory-map-tool", memoryMap.url.path,
        ]
        if let configurationFile {
            arguments += ["--configuration", configurationFile.path]
        }
        for resource in embeddedResources {
            arguments += [
                "--embedded-resource", resource.lastPathComponent,
                resource.path,
            ]
        }

        var inputFiles = [finalizer.url, memoryMap.url]
        inputFiles += embeddedResources
        inputFiles += regularFiles(in: harnessDirectory)
        inputFiles.append(cpicoSDKDirectory.appending(path: "env.json"))
        if let configurationFile {
            inputFiles.append(configurationFile)
        }

        let artifactNames = ["elf", "uf2", "bin", "hex"].map {
            "\(product.name).\($0)"
        } + [
            "\(product.name).elf.map",
            "\(product.name).dis",
        ]

        return ExternalBuildCommand(
            displayName: "Finalize \(product.name) firmware artifacts",
            executable: adapter.url,
            arguments: arguments,
            environment: forwardedEnvironment(from: processEnvironment),
            placement: .postProduct(product),
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
            outputFiles: artifactNames
        )
    }

    private func configurationFile(
        packageDirectory: URL,
        processEnvironment: [String: String]
    ) throws -> URL? {
        if let configuredPath = processEnvironment["CPICOSDK_BUILD_CONFIGURATION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty
        {
            let url = (configuredPath as NSString).isAbsolutePath
                ? URL(fileURLWithPath: configuredPath, isDirectory: false)
                : packageDirectory.appendingPathComponent(
                    configuredPath,
                    isDirectory: false
                )
            let standardizedURL = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
                throw Error.missingConfiguration(standardizedURL.path)
            }
            return standardizedURL
        }

        let defaultURL = packageDirectory.appendingPathComponent(
            "cpicosdk-build.json",
            isDirectory: false
        )
        return FileManager.default.fileExists(atPath: defaultURL.path)
            ? defaultURL.standardizedFileURL
            : nil
    }

    private func loadConfiguration(from url: URL) throws -> ConsumerConfiguration {
        do {
            return try JSONDecoder().decode(
                ConsumerConfiguration.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw Error.invalidConfiguration(url.path, underlying: error)
        }
    }

    private func selectedProduct(
        in package: Package,
        configuredName: String?
    ) throws -> LibraryProduct {
        let staticProducts = package.products(ofType: LibraryProduct.self)
            .filter { $0.kind == .static }
        if let configuredName = configuredName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredName.isEmpty
        {
            guard let product = staticProducts.first(where: {
                $0.name == configuredName
            }) else {
                throw Error.unsupportedProducts(
                    "productName '\(configuredName)' is not one of [\(staticProducts.map(\.name).joined(separator: ", "))]"
                )
            }
            return product
        }

        guard staticProducts.count == 1, let product = staticProducts.first else {
            throw Error.unsupportedProducts(
                "found static products [\(staticProducts.map(\.name).joined(separator: ", "))]"
            )
        }
        return product
    }

    private func isCPicoSDKPackage(_ package: Package) -> Bool {
        package.displayName.caseInsensitiveCompare("CPicoSDK") == .orderedSame
            || package.products.contains { $0.name == "CPicoSDK" }
    }

    private func isCPicoNativePackage(_ package: Package) -> Bool {
        package.displayName.caseInsensitiveCompare("CPicoNative") == .orderedSame
            || package.products.contains { $0.name == "CPicoNativeSupport" }
    }

    private func transitiveDependency(
        from package: Package,
        matching predicate: (Package) -> Bool
    ) -> Package? {
        var visited = Set<String>()
        var pending = package.dependencies.map(\.package)
        while !pending.isEmpty {
            let candidate = pending.removeFirst()
            guard visited.insert(candidate.id).inserted else {
                continue
            }
            if predicate(candidate) {
                return candidate
            }
            pending.append(contentsOf: candidate.dependencies.map(\.package))
        }
        return nil
    }

    private func forwardedEnvironment(
        from processEnvironment: [String: String]
    ) -> [String: String] {
        let names: Set<String> = [
            "AUTO_STDIO",
            "BOARD",
            "BUILD_TYPE",
            "CMAKE_PATH",
            "CPICOSDK_BUILD_CONFIGURATION",
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
            "SWIFT_SDK",
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
