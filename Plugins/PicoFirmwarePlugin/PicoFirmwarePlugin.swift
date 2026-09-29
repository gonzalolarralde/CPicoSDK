import Foundation
import PackagePlugin

@main
struct PicoFirmwarePlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        var products = target.dependencies.compactMap { dependency -> LibraryProduct? in
            guard case .product(let product) = dependency,
                  let library = product as? LibraryProduct, library.kind == .static else { return nil }
            return library
        }
        if products.isEmpty {
            let moduleIDs = Set(target.dependencies.compactMap { dependency -> String? in
                guard case .target(let module) = dependency else { return nil }
                return module.id
            })
            products = context.package.products(ofType: LibraryProduct.self).filter {
                $0.kind == .static && !$0.sourceModules.isEmpty
                    && $0.sourceModules.allSatisfy { moduleIDs.contains($0.id) }
            }
        }
        guard products.count == 1, let product = products.first else {
            Diagnostics.error("PicoFirmware requires a dependency on exactly one static library product.")
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
        let report = try context.tool(named: "MemoryMapReportTool")
        let productsDirectory = URL(string: "file:/$(PRODUCTS_DIR)")!
        let archive = productsDirectory.appending(path: "lib\(product.name).a")
        let work = context.pluginWorkDirectoryURL.appending(path: "$(BUILD_SUBDIR)")
        let harness = sdk.package.directoryURL.appending(path: "Plugins/FinalizeBinaryPluginTool/CMakeHarness")
        let harnessInputs = try FileManager.default.contentsOfDirectory(
            at: harness, includingPropertiesForKeys: nil
        ).sorted { $0.path < $1.path }
        let resources = product.sourceModules.flatMap { $0.sourceFiles.map(\.url) }
            .filter { $0.pathExtension == "codeasset" }.sorted { $0.path < $1.path }
        let outputs = ["elf", "uf2"].map { work.appending(path: "\(product.name).\($0)") }
        var arguments = [
            "--product", product.name,
            "--archive", archive.path,
            "--output-directory", work.path,
            "--work-directory", work.path,
            "--package-directory", context.package.directoryURL.path,
            "--sdk-directory", sdk.package.directoryURL.path,
            "--memory-map-tool", report.url.path,
        ]
        for resource in resources { arguments += ["--resource", resource.path] }
        var commands: [Command] = [.buildCommand(
            displayName: "Link \(product.name) firmware and generate UF2",
            executable: tool.url,
            arguments: arguments,
            environment: buildEnvironment,
            inputFiles: [archive, tool.url, report.url, sdk.package.directoryURL.appending(path: "env.json")]
                + harnessInputs + resources,
            outputFiles: outputs
        )]
        // The prototype's copy command can publish outputs outside the plugin sandbox.
        for output in outputs {
            let destination = productsDirectory.appending(path: output.lastPathComponent)
            commands.append(.buildCommand(
                displayName: "Publish \(output.lastPathComponent)",
                executable: URL(string: "file:/$(COPY_CMD)")!,
                arguments: [output.path, destination.path],
                inputFiles: [output],
                outputFiles: [destination]
            ))
        }
        return commands
    }
}
