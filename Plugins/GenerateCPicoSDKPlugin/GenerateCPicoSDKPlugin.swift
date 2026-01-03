import Foundation
import PackagePlugin

@main
struct GenerateCPicoSDKPlugin: CommandPlugin {
    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = context.package.directoryURL.appending(path: "/Plugins/GenerateCPicoSDKPluginTool/build.sh", directoryHint: .notDirectory)
        process.environment = ProcessInfo.processInfo.environment

        process.arguments = [
            context.pluginWorkDirectoryURL.relativePath,
            context.package.directoryURL.relativePath.appending("/Plugins/GenerateCPicoSDKPluginTool/Test"),
            context.package.directoryURL.relativePath
        ]
        
        // TODO: Rewrite build.sh as swift code
        guard try await process.asyncRun() == 0 else { fatalError("Command failed to run!") }
    }
}

extension Process {
    // TODO: Move to shared package
    func asyncRun() async throws -> Int32 {
        try await withUnsafeThrowingContinuation { continuation in
            self.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try self.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
