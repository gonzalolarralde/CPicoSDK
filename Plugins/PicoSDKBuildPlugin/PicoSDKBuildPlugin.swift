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
        let tool = try context.tool(named: "PicoFirmwareBuildTool")
        let productsDirectory = URL(string: "file:/$(PRODUCTS_DIR)")!
        let archive = productsDirectory.appending(path: "lib\(configuration.name).a")
        let buildConfiguration = productsDirectory.appending(path: "pico-build-configuration.json")
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
                "--phase", "sdk", "--product", "PicoSDK",
                "--build-configuration", buildConfiguration.path,
                "--archive", archive.path,
                "--output-directory", work.path, "--work-directory", work.path,
                "--sdk-directory", sdk.package.directoryURL.path,
            ],
            inputFiles: [archive, buildConfiguration, tool.url] + harnessInputs,
            outputFiles: artifacts + [build.appending(path: "build.ninja")],
            productFiles: artifacts.map { BuildProduct($0) }
        )]
    }
}
