import Foundation
import PackagePlugin

@main
struct MemoryMapReportPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "MemoryMapReportTool")
        let cpicoSDKPath = resolveCPicoSDKPath(context: context)

        let process = Process()
        process.executableURL = tool.url
        process.arguments = [
            "--package-dir", context.package.directoryURL.path,
            "--cpicosdk-path", cpicoSDKPath.path,
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            Diagnostics.error("memory-map-report failed with exit code \(process.terminationStatus)")
            throw PluginError.toolFailed(process.terminationStatus)
        }
    }

    private func resolveCPicoSDKPath(context: PluginContext) -> URL {
        if let dependency = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" }) {
            return dependency.package.directoryURL
        }
        return context.package.directoryURL
    }
}

enum PluginError: Error {
    case toolFailed(Int32)
}
