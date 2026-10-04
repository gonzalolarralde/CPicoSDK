import Foundation
import PackagePlugin

@main
struct PicoSDKBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let products = target.dependencies.compactMap { dependency -> LibraryProduct? in
            guard case .product(let product) = dependency else { return nil }
            return product as? LibraryProduct
        }
        guard products.count == 1, let configuration = products.first,
              configuration.name == "CPicoSDKConfiguration", configuration.kind == .static,
              let sdk = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" }) else {
            Diagnostics.error("PicoSDKBuild requires the CPicoSDKConfiguration static product and a direct CPicoSDK dependency.")
            return []
        }
        let environment = ProcessInfo.processInfo.environment
        let keys = Set((environment["RELEVANT_ENV_VARS"] ?? "").split(separator: ",").map(String.init))
            .union(["RELEVANT_ENV_VARS", "PATH", "AUTO_STDIO", "DEVELOPER_DIR"])
        let buildEnvironment = environment.filter { keys.contains($0.key) || $0.key.hasPrefix("CPICOSDK_") }
        let tool = try context.tool(named: "PicoFirmwareBuildTool")
        let productsDirectory = URL(string: "file:/$(PRODUCTS_DIR)")!
        let archive = productsDirectory.appending(path: "lib\(configuration.name).a")
        let work = context.pluginWorkDirectoryURL.appending(path: "$(BUILD_SUBDIR)")
        let harness = sdk.package.directoryURL.appending(path: "Plugins/FinalizeBinaryPluginTool/CMakeHarness")
        let harnessInputs = try FileManager.default.contentsOfDirectory(at: harness, includingPropertiesForKeys: nil)
            .sorted { $0.path < $1.path }
        let build = work.appending(path: "CMakeHarness/build")
        let artifacts = ["libPicoSDK.a", "sdk-build.json"].map { build.appending(path: $0) }
        return [.buildCommand(
            displayName: "Build Pico SDK from CPicoSDKConfiguration",
            executable: tool.url,
            arguments: [
                "--phase", "sdk", "--product", environment["SWIFTPM_PRODUCT"] ?? "Firmware",
                "--archive", archive.path,
                "--output-directory", work.path, "--work-directory", work.path,
                "--sdk-directory", sdk.package.directoryURL.path,
            ],
            environment: buildEnvironment,
            inputFiles: [archive, tool.url, sdk.package.directoryURL.appending(path: "env.json")] + harnessInputs,
            outputFiles: artifacts + [build.appending(path: "build.ninja")],
            productFiles: artifacts.map { BuildProduct($0) }
        )]
    }
}
