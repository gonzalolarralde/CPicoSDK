import Foundation
import PackagePlugin

@main
struct PicoBuildConfigurationPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard target.dependencies.contains(where: {
            if case .product(let product) = $0, let library = product as? LibraryProduct {
                return library.name == "CPicoSDKConfiguration" && library.kind == .static
            }
            return false
        }), let sdk = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" }) else {
            Diagnostics.error("PicoBuildConfiguration requires the CPicoSDKConfiguration static product and a direct CPicoSDK dependency.")
            return []
        }
        let environment = ProcessInfo.processInfo.environment
        let installation: URL
        if let path = environment["CPICOSDK_INSTALLATION_PATH"] {
            installation = URL(fileURLWithPath: path)
        } else {
            let directories = [context.package.directoryURL] + context.package.dependencies.map { $0.package.directoryURL }
            let candidates = directories.map { $0.appending(path: ".cpicosdk-installation.json") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard candidates.count == 1, let candidate = candidates.first else {
                Diagnostics.error("Run prepare-rp2xxx-environment once to create .cpicosdk-installation.json, or set CPICOSDK_INSTALLATION_PATH to select an installation explicitly.")
                return []
            }
            installation = candidate
        }
        // Do not treat the legacy script's derived board/tool paths as user overrides.
        let overrideKeys: Set<String> = [
            "AUTO_STDIO", "BUILD_TYPE", "CPICOSDK_CORE0_STACK_SIZE_BYTES", "CPICOSDK_CORE1_STACK_SIZE_BYTES",
        ]
        let buildEnvironment = environment.filter { overrideKeys.contains($0.key) }
        let defaults = sdk.package.directoryURL.appending(path: "env.json")
        let archive = URL(string: "file:/$(PRODUCTS_DIR)/libCPicoSDKConfiguration.a")!
        let work = context.pluginWorkDirectoryURL.appending(path: "$(BUILD_SUBDIR)")
        let output = work.appending(path: "pico-build-configuration.json")
        let tool = try context.tool(named: "PicoBuildConfigurationTool")
        return [.buildCommand(
            displayName: "Resolve Pico build configuration",
            executable: tool.url,
            arguments: [
                "build", "--defaults", defaults.path, "--installation", installation.path,
                "--archive", archive.path, "--output", output.path,
                "--triple", "$(TRIPLE)", "--configuration", "$(CONFIGURATION)",
            ],
            environment: buildEnvironment,
            inputFiles: [defaults, installation, archive, tool.url],
            outputFiles: [output],
            productFiles: [BuildProduct(output)]
        )]
    }
}
