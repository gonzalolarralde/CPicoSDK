import Foundation
import PackagePlugin

@main
struct FinalizeBinaryPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        guard let name = arguments.first,
              let product = context.package.products(ofType: LibraryProduct.self)
                .first(where: { $0.name == name && $0.kind == .static }),
              let sdk = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" })
        else {
            Diagnostics.error("Expected the name of a static library product depending on CPicoSDK.")
            return
        }
        let env = ProcessInfo.processInfo.environment
        guard let triple = env["SWIFTPM_TRIPLE"], let configuration = env["SWIFT_BUILD_TYPE"] else {
            Diagnostics.error("Run prepare-rp2xxx-environment and source its output first.")
            return
        }
        let output = context.package.directoryURL.appending(path: ".build/\(triple)/\(configuration)")
        let tool = try context.tool(named: "PicoFirmwareBuildTool")
        let report = try context.tool(named: "MemoryMapReportTool")
        let process = Process()
        process.executableURL = tool.url
        process.arguments = [
            "--product", name,
            "--archive", output.appending(path: "lib\(name).a").path,
            "--output-directory", output.path,
            "--work-directory", context.pluginWorkDirectoryURL.path,
            "--package-directory", context.package.directoryURL.path,
            "--sdk-directory", sdk.package.directoryURL.path,
            "--memory-map-tool", report.url.path,
        ]
        for module in product.sourceModules {
            for file in module.sourceFiles where file.url.pathExtension == "codeasset" {
                process.arguments! += ["--resource", file.url.path]
            }
        }
        if !arguments.contains("--incremental") { process.arguments!.append("--clean") }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CPicoSDK.FirmwareBuild", code: Int(process.terminationStatus))
        }
    }
}
