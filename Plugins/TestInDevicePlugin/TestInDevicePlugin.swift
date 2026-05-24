import Foundation
import PackagePlugin

@main
struct TestInDevicePlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "TestInDeviceTool")
        let cpicoSDKPath = resolveCPicoSDKPath(context: context)

        let process = Process()
        process.executableURL = tool.url
        process.arguments = [
            "--package-dir", context.package.directoryURL.path,
            "--work-dir", context.pluginWorkDirectoryURL.path,
            "--cpicosdk-path", cpicoSDKPath.path,
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            Diagnostics.error("test-in-device failed with exit code \(process.terminationStatus)")
            throw PluginError.toolFailed(process.terminationStatus)
        }
    }

    private func resolveCPicoSDKPath(context: PluginContext) -> URL {
        if let dependency = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" }) {
            return dependency.package.directoryURL
        }
        let packageDirectory = context.package.directoryURL
        if FileManager.default.fileExists(atPath: packageDirectory.appendingPathComponent("env.json").path) {
            return packageDirectory
        }
        return packageDirectory
    }
}

enum PluginError: Error {
    case toolFailed(Int32)
}
