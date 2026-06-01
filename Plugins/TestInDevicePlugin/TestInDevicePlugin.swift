import Foundation
import PackagePlugin

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct TestInDevicePlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "TestInDeviceTool")
        let memoryMapTool = try context.tool(named: "MemoryMapReportTool")
        let cpicoSDKPath = resolveCPicoSDKPath(context: context)

        let process = Process()
        process.executableURL = tool.url
        process.arguments = [
            "--package-dir", context.package.directoryURL.path,
            "--work-dir", context.pluginWorkDirectoryURL.path,
            "--cpicosdk-path", cpicoSDKPath.path,
            "--memory-map-tool", memoryMapTool.url.path,
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment

        try process.run()
        installCancellationForwarder(for: process)
        process.waitUntilExit()
        clearCancellationForwarder()

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

nonisolated(unsafe) private var pluginChildProcessID: pid_t = -1

private func pluginCancellationSignalHandler(_ signal: Int32) {
    let childProcessID = pluginChildProcessID
    guard childProcessID > 0 else {
        return
    }
    #if os(Linux)
    _ = Glibc.kill(childProcessID, signal)
    #else
    _ = Darwin.kill(childProcessID, signal)
    #endif
}

private func installCancellationForwarder(for process: Process) {
    pluginChildProcessID = process.processIdentifier
    #if os(Linux)
    Glibc.signal(SIGINT, pluginCancellationSignalHandler)
    Glibc.signal(SIGTERM, pluginCancellationSignalHandler)
    #else
    Darwin.signal(SIGINT, pluginCancellationSignalHandler)
    Darwin.signal(SIGTERM, pluginCancellationSignalHandler)
    #endif
}

private func clearCancellationForwarder() {
    pluginChildProcessID = -1
}
