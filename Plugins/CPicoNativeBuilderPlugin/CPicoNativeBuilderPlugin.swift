import Foundation
import PackagePlugin

@main
struct CPicoNativeBuilderPlugin: ExternalBuilderPlugin {
    func createExternalBuildCommand(
        context: PluginContext
    ) async throws -> ExternalBuildCommand {
        let builder = try context.tool(named: "CPicoNativeBuilder")
        let inheritedKeys = [
            "BOARD", "BUILD_TYPE", "CMAKE_PATH", "CPICOSDK_CORE1_STACK_SIZE_BYTES",
            "CPICOSDK_COMBINATION", "CPICOSDK_CORE0_STACK_SIZE_BYTES",
            "CPICOSDK_BUILD_CONFIGURATION",
            "CPICOSDK_ROOT",
            "CPICO_EXTERNAL_STDIO_RTT", "CPICO_EXTERNAL_STDIO_UART",
            "CPICO_EXTERNAL_STDIO_USB", "IMPORTED_LIBS", "IMPORTED_LIBS_MORE",
            "NINJA_PATH",
            "PICOTOOL_PATH", "PICO_SDK_PATH", "PICO_TOOLCHAIN_PATH", "SDK_VERSION",
        ]
        let processEnvironment = ProcessInfo.processInfo.environment
        var environment = Dictionary(uniqueKeysWithValues: inheritedKeys.compactMap { key in
            processEnvironment[key].map { (key, $0) }
        })
        let externalSource = context.package.directoryURL
        let cpicoSDKDirectory = externalSource
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var inputFiles = regularFiles(in: externalSource)
        inputFiles.append(cpicoSDKDirectory.appending(path: "env.json"))
        inputFiles += regularFiles(in: cpicoSDKDirectory.appending(
            path: "Support/FirmwareFinalizer/CMakeHarness",
            directoryHint: .isDirectory
        ))
        if let configurationPath = environment["CPICOSDK_BUILD_CONFIGURATION"],
           !configurationPath.isEmpty
        {
            let configurationURL = absoluteURL(for: configurationPath)
            environment["CPICOSDK_BUILD_CONFIGURATION"] = configurationURL.path
            inputFiles.append(configurationURL)
        }

        return ExternalBuildCommand(
            displayName: "Build CPico native support archive",
            executable: builder.url,
            arguments: [
                context.pluginWorkDirectoryURL.path,
                context.package.directoryURL.path,
            ],
            environment: environment,
            inputFiles: inputFiles,
            outputFiles: ["pioasm-package-path.txt"]
        )
    }

    private func absoluteURL(for path: String) -> URL {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent(path).standardizedFileURL
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
}
