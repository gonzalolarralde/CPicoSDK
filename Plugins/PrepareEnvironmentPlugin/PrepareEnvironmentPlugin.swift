import Foundation
import PackagePlugin

@main
class PrepareEnvironmentPlugin: CommandPlugin {
    var verbose = false
    var output = ""

    required init() {}

    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        let cPicoSDKEnvVarsPath: String
        if let packageEnvVarsPath = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" })?.package.directoryURL {
            cPicoSDKEnvVarsPath = packageEnvVarsPath.appending(path: "env.json").relativePath
        } else if let argumentEnvVarsPath = self.findArgumentWithValue(from: arguments, argument: "--cpicosdk-envs-path") {
            cPicoSDKEnvVarsPath = argumentEnvVarsPath
        } else {
            fatalError("[CPicoSDK] Couldn't find CPicoSDK in the dependencies.")
        }

        guard let dumpPrepScriptPath = self.findArgumentWithValue(from: arguments, argument: "--dump-prep-script") else {
            fatalError("[CPicoSDK] No --dump-prep-script argument provided.")
        }

        let generateVSCodeSettings = !arguments.contains("--disable-vscode-settings")
        let generateSourceKitLSPSettings = !arguments.contains("--disable-sourcekit-lsp-settings")
        let generateToolset = !arguments.contains("--disable-toolset")
        let syncSwiftVersion = !arguments.contains("--disable-swift-version")
        let installDependencies = !arguments.contains("--disable-install-dependencies")
        let forceProductName = !arguments.contains("--dont-force-product-name")

        self.verbose = ProcessInfo.processInfo.environment["VERBOSE_ENV_SETUP"] == "1"

        // Start preparing output
        print("[CPicoSDK] Preparing environment for CPicoSDK...")
        self.output += "set -euo pipefail\n\n"

        // Find the product to build if needed.
        let libraryProduct = self.resolveProductToBuild(context: context)

        if libraryProduct == nil, forceProductName {
            fatalError("[CPicoSDK] At least one static library product that depends on CPicoSDK is needed.")
        } else {
            print("[CPicoSDK] Resolved product to build: \(libraryProduct?.name ?? "none")")
        }

        // Finding and merging env vars.
        let packageURL = context.package.directoryURL
        let givenEnvVars = ProcessInfo.processInfo.environment

        guard let cPicoSDKPackageEnv = try? Env(from: cPicoSDKEnvVarsPath) else {
            fatalError("[CPicoSDK] Couldn't find CPicoSDK default env values. Make sure this package depends on CPicoSDK or provide the path using --cpicosdk-envs-path. [path=\(cPicoSDKEnvVarsPath)]")
        }

        let consolidatedEnvVars = self.generateEnvVars(
            given: givenEnvVars, 
            packageEnv: cPicoSDKPackageEnv,
            context: context,
            libraryProductName: libraryProduct?.name
        )

        self.generateBashFunctions()

        // Generate helper files if needed
        if installDependencies {
            try await self.installDependencies(context: context, envVars: consolidatedEnvVars)
        }
        
        if generateToolset {
            try self.generateToolset(envVars: consolidatedEnvVars)
        }

        if syncSwiftVersion {
            try self.syncSwiftVersion(packageURL: packageURL.relativePath, envVars: consolidatedEnvVars)
        }

        if generateSourceKitLSPSettings {
            try self.generateSourceKitLSPSettings(packageURL: packageURL.relativePath, envVars: consolidatedEnvVars)
        }

        if generateVSCodeSettings {
            try self.generateVSCodeSettings(context: context, envVars: consolidatedEnvVars)
        }

        // Write output once generated
        try self.generatePreparationScript(dumpPrepScriptPath: dumpPrepScriptPath)
    }
    
    func installDependencies(context: PackagePlugin.PluginContext, envVars: [String: String]) async throws {
        let tool = try context.tool(named: "pico-bootstrap")
        let process = Process()
        process.executableURL = tool.url
        
        process.arguments = [
            "install",
            "--sdk", envVars["SDK_VERSION"]!,
            "--toolchain", envVars["TOOLCHAIN_VERSION"]!,
            "--cmake", envVars["CMAKE_VERSION"]!,
            "--ninja", envVars["NINJA_VERSION"]!,
            "--picotool", envVars["PICOTOOL_VERSION"]!,
            "--openocd", envVars["OPENOCD_VERSION"]!,
            "--root", envVars["PICO_SDK_BUNDLE_PATH"]!,
            "--include-sdk-tools", "false"
        ]

        do {
            let status = try await process.asyncRun()
            if status != 0 {
                fatalError("[CPicoSDK] Dependency installation failed: exit code \(status)")
            }
        } catch {
            fatalError("[CPicoSDK] Dependency installation failed: \(error)")
        }
    }

    private func findArgumentWithValue(from arguments: [String], argument: String) -> String? {
        if let index = arguments.firstIndex(of: argument) {
            let nextIndex = arguments.index(after: index)
            if nextIndex >= arguments.endIndex {
                return nil
            }
            return arguments[nextIndex]
        }

        return nil
    }
}
