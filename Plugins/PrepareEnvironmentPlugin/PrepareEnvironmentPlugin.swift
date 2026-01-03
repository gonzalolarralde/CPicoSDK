import Foundation
import PackagePlugin

let relevantEnvVars: Set<String> = [
    "HOME",
    "PACKAGE_PATH",
    "PLUGIN_OUTPUT_PATH",
    "SWIFTPM_PRODUCT",
    "PICO_SDK_BUNDLE_PATH",
    "SWIFT_VERSION",
    "SDK_VERSION",
    "TOOLCHAIN_VERSION",
    "CMAKE_VERSION",
    "NINJA_VERSION",
    "PICOTOOL_VERSION",
    "OPENOCD_VERSION",
    "PICO_SDK_PATH",
    "PICO_TOOLCHAIN_PATH",
    "PICOTOOL_PATH",
    "CMAKE_PATH",
    "NINJA_PATH",
    "SWIFTLY_PATH",
    "TOOLSET_PATH",
    "SDK_PATH",
    "LD_PATH",
    "GDB_PATH",
    "IMPORTED_LIBS",
    "SWIFTPM_TRIPLE",
    "BUILD_TYPE",
    "SWIFT_BUILD_TYPE",
    "BOARD",
]

enum BuildType: String {
    static let defaultBuildType = BuildType.releaseWithDebugInfo // .debug

    case debug = "Debug"
    case release = "Release"
    case releaseWithDebugInfo = "RelWithDebInfo"
    case minimumSizeRelease = "MinSizeRel"

    var swiftBuildType: String {
        switch self {
        case .debug: "debug"
        case .release, .releaseWithDebugInfo, .minimumSizeRelease: "release"
        }
    }

    var cmakeBuildType: String {
        self.rawValue
    }
}

@main
class PrepareEnvironmentPlugin: CommandPlugin {
    var verbose = false
    var output = ""

    required init() {}

    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        guard let picoSDKURL = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" })?.package.directoryURL else {
            fatalError("Couldn't find CPicoSDK.")
        }

        guard let dumpPrepScriptPath = self.resolveDumpPrepScriptPath(from: arguments) else {
            fatalError("No --dump-prep-script argument provided.")
        }

        let generateVSCodeSettings = !arguments.contains("--disable-vscode-settings")
        let generateSourceKitLSPSettings = !arguments.contains("--disable-sourcekit-lsp-settings")
        let generateToolset = !arguments.contains("--disable-toolset")
        let syncSwiftVersion = !arguments.contains("--disable-swift-version")
        let installDependencies = !arguments.contains("--disable-install-dependencies")

        self.verbose = ProcessInfo.processInfo.environment["VERBOSE_ENV_SETUP"] == "1"

        // Start preparing output

        print("[CPicoSDK] Preparing environment for CPicoSDK...")
        self.output += "set -euxo pipefail\n\n"

        // Finding and merging env vars.

        let packageURL = context.package.directoryURL
        let givenEnvVars = ProcessInfo.processInfo.environment

        guard let cPicoSDKPackageEnvs = FileManager().envs(from: picoSDKURL.appending(path: "env.json.tmpl").relativePath) else {
            fatalError("Couldn't find default env values in CPicoSDK package directory. Make sure it's present and it's a valid JSON (\(picoSDKURL))")
        }

        let consolidatedEnvVars = self.generateEnvVars(given: givenEnvVars, packageEnvs: cPicoSDKPackageEnvs, context: context)
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

        let fileManager = FileManager()
        try fileManager.ensureDirectoryExists(at: dumpPrepScriptPath, isDirectory: false)
        fileManager.createFile(atPath: dumpPrepScriptPath, contents: self.output.data(using: .utf8))
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
            "--root", envVars["PICO_SDK_BUNDLE_PATH"]!
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

    private func resolveDumpPrepScriptPath(from arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "--dump-prep-script") {
            let nextIndex = arguments.index(after: index)
            if nextIndex >= arguments.endIndex {
                fatalError("Missing path for --dump-prep-script.")
            }
            return arguments[nextIndex]
        }

        return nil
    }
}
