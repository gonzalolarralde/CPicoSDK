import Foundation
import PackagePlugin

@main
struct GenerateCPicoSDKPlugin: CommandPlugin {
    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        guard let productName = arguments.first else {
            fatalError("A product name is expected. It should be a static library in the Product section of the package.")
        }
        
        let clean = if arguments.count >= 2, arguments[1] == "--incremental" {
            "dont-clean"
        } else {
            "clean"
        }
        
        guard let picoSDKURL = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" })?.package.directoryURL else {
            fatalError("Couldn't find CPicoSDK.")
        }
        
        // TODO: Support multiple products
        guard let libProduct = context.package.products(ofType: LibraryProduct.self).first(where: { $0.name == productName }) else {
            fatalError("Couldn't find a viable Product, name couldn't be matched")
        }
        
        guard libProduct.kind == .static else {
            fatalError("Only static libraries are supported.")
        }
        
        guard libProduct.sourceModules.count == 1 else {
            fatalError("Only libraries with one target are supported.")
        }

        let process = Process()
        process.executableURL = picoSDKURL.appending(path: "/Plugins/FinalizeBinaryPluginTool/build.sh", directoryHint: .notDirectory)
        
        if let envs = FileManager().envs(from: context.package.directoryURL.appending(path: "env.json").relativePath) {
            process.environment = envs
        } else if let envs = FileManager().envs(from: picoSDKURL.appending(path: "env.json").relativePath) {
            process.environment = envs
        } else {
            fatalError("No env.json file found. Please duplicate from env.json.template and save it on the package root.")
        }

        process.arguments = [
            context.pluginWorkDirectoryURL.relativePath,
            picoSDKURL.relativePath.appending("/Plugins/FinalizeBinaryPluginTool/Test"),
            // TODO: Remove this assumption about the triple used to compile.
            context.package.directoryURL.relativePath
                .appending("/.build/armv7em-none-none-eabi/release/lib\(libProduct.name).a"),
            libProduct.name,
            clean
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

extension FileManager {
    func envs(from file: String) -> [String: String]? {
        if FileManager().fileExists(atPath: file),
           let envsContent = FileManager().contents(atPath: file),
           let envs = try? JSONDecoder().decode([String: String].self, from: envsContent)
        {
            return envs
        } else {
            return nil
        }
    }
}
