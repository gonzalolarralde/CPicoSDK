import Foundation
import PackagePlugin

let relevantEnvVars: Set<String> = [
    "HOME",
    "SWIFTPM_TRIPLE",
    "PICO_SDK_PATH",
    "PICO_TOOLCHAIN_PATH",
    "PICOTOOL_PATH",
    "CMAKE_PATH",
    "NINJA_PATH",
    "SWIFTLY_PATH",
    "SDK_PATH",
    "LD_PATH",
    "TOOLSET_PATH",
    "SDK_VERSION",
    "TOOLCHAIN_VERSION",
    "BUILD_TYPE",
    "SWIFT_BUILD_TYPE",
    "BOARD",
    "IMPORTED_LIBS"
]

@main
struct FinalizeBinaryPlugin: CommandPlugin {
    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        guard arguments.count >= 2 else {
            fatalError("Expected at least two arguments: product name and home directory path.\nA product name is expected. It should be a static library in the Product section of the package.")
        }

        let productName = arguments[0]

        let clean = if arguments.count >= 3, arguments[2] == "--incremental" {
            "dont-clean"
        } else {
            "clean"
        }
        
        guard let picoSDKURL = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" })?.package.directoryURL else {
            fatalError("Couldn't find CPicoSDK in the dependencies.")
        }
        
        let matchingProducts = context.package.products(ofType: LibraryProduct.self)
        guard let libProduct = matchingProducts.first(where: { $0.name == productName }) else {
            fatalError("Couldn't find a viable static library Product, name couldn't be matched. Given: \(productName); Found: [\(matchingProducts.map(\.name).joined(separator: ","))]")
        }
        
        guard libProduct.kind == .static else {
            fatalError("Only static libraries are supported.")
        }
        
        // TODO: Figure out how to expand this.
        guard libProduct.sourceModules.count == 1 else {
            fatalError("Only libraries with one target are supported.")
        }

        // TODO: Rewrite all this as swift code.
        let process = Process()
        process.executableURL = picoSDKURL.appending(path: "/Plugins/FinalizeBinaryPluginTool/build.sh", directoryHint: .notDirectory)

        let envVars = Dictionary(
            uniqueKeysWithValues: ProcessInfo.processInfo.environment
                .filter({ relevantEnvVars.contains($0.key) })
        )

        guard Set(envVars.keys) == relevantEnvVars else {
            let missingKeys = relevantEnvVars.subtracting(Set(envVars.keys))
            fatalError("Cannot continue. Missing env variables: [\(missingKeys.joined(separator: ", "))]")
        }

        process.environment = envVars

        let swiftBuildType = envVars["SWIFT_BUILD_TYPE"]!
        let platformTriple = envVars["SWIFTPM_TRIPLE"]!

        process.arguments = [
            context.pluginWorkDirectoryURL.relativePath,
            picoSDKURL.relativePath.appending("/Plugins/FinalizeBinaryPluginTool/Test"),
            context.package.directoryURL.relativePath
                .appending("/.build/\(platformTriple)/\(swiftBuildType)/lib\(libProduct.name).a"),
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


