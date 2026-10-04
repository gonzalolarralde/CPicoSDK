import Foundation
import PackagePlugin

@main
struct PicoFirmwarePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let products = target.dependencies.compactMap { dependency -> LibraryProduct? in
            guard case .product(let product) = dependency,
                  let library = product as? LibraryProduct, library.kind == .static else { return nil }
            return library
        }
        let applications = products.filter { $0.name != "CPicoSDKConfiguration" }
        guard applications.count == 1, let product = applications.first,
              products.contains(where: { $0.name == "CPicoSDKConfiguration" }) else {
            Diagnostics.error("PicoFirmware requires an application static product and CPicoSDKConfiguration.")
            return []
        }
        guard let sdk = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" }) else {
            Diagnostics.error("PicoFirmware requires a direct dependency on CPicoSDK.")
            return []
        }
        let environment = ProcessInfo.processInfo.environment
        // SwiftPM also invokes build plugins while building preparation tools.
        // Validate the prepared environment when the firmware command executes.
        let relevant = environment["RELEVANT_ENV_VARS"] ?? ""
        let keys = Set(relevant.split(separator: ",").map(String.init))
            .union(["RELEVANT_ENV_VARS", "PATH", "AUTO_STDIO", "DEVELOPER_DIR"])
        let buildEnvironment = environment.filter { keys.contains($0.key) || $0.key.hasPrefix("CPICOSDK_") }
        let tool = try context.tool(named: "PicoFirmwareBuildTool")
        let productsDirectory = URL(string: "file:/$(PRODUCTS_DIR)")!
        let archive = productsDirectory.appending(path: "lib\(product.name).a")
        let configuration = productsDirectory.appending(path: "libCPicoSDKConfiguration.a")
        let work = context.pluginWorkDirectoryURL.appending(path: "$(BUILD_SUBDIR)")
        let harness = sdk.package.directoryURL.appending(path: "Plugins/FinalizeBinaryPluginTool/CMakeHarness")
        let harnessInputs = try FileManager.default.contentsOfDirectory(
            at: harness, includingPropertiesForKeys: nil
        ).sorted { $0.path < $1.path }
        let resources = product.sourceModules.flatMap { $0.sourceFiles.map(\.url) }
            .filter { $0.pathExtension == "codeasset" }.sorted { $0.path < $1.path }
        let outputs = ["elf", "uf2", "bin", "elf.map"].map { work.appending(path: "\(product.name).\($0)") }
        let sdkOutputs = ["libPicoSDK.a", "sdk-build.json"].map { productsDirectory.appending(path: $0) }
        var arguments = [
            "--product", product.name,
            "--archive", archive.path,
            "--configuration-archive", configuration.path,
            "--sdk-artifacts-directory", productsDirectory.path,
            "--output-directory", work.path,
            "--work-directory", work.path,
            "--sdk-directory", sdk.package.directoryURL.path,
        ]
        for resource in resources { arguments += ["--resource", resource.path] }
        let configurationInputs = [archive, configuration, tool.url, sdk.package.directoryURL.appending(path: "env.json")]
            + harnessInputs
        return [.buildCommand(
            displayName: "Link \(product.name) firmware and generate UF2",
            executable: tool.url,
            arguments: arguments + ["--phase", "link"],
            environment: buildEnvironment,
            inputFiles: configurationInputs + sdkOutputs + resources,
            outputFiles: outputs,
            productFiles: outputs.map { BuildProduct($0) }
        )]
    }
}
