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
    "SWIFT_VERSION",
    "TOOLCHAIN_VERSION",
    "BUILD_TYPE",
    "SWIFT_BUILD_TYPE",
    "BOARD",
    "IMPORTED_LIBS"
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

    func log(message: String) {
        if verbose {
            self.output += "cat << EOF\n\(message)\nEOF" + "\n"
        }
    }

    func performCommand(context: PackagePlugin.PluginContext, arguments: [String]) async throws {
        guard let picoSDKURL = context.package.dependencies.first(where: { $0.package.displayName == "CPicoSDK" })?.package.directoryURL else {
            fatalError("Couldn't find CPicoSDK.")
        }

        let generateVSCodeSettings = !arguments.contains("--disable-vscode-settings")
        let generateSourceKitLSPSettings = !arguments.contains("--disable-sourcekit-lsp-settings")
        let generateToolset = !arguments.contains("--disable-toolset")
        let syncSwiftVersion = !arguments.contains("--disable-swift-version")

        self.verbose = ProcessInfo.processInfo.environment["VERBOSE_ENV_SETUP"] == "1"

        // Start preparing output

        self.log(message: "Preparing environment for CPicoSDK...")

        // Finding and merging env vars.

        let packageURL = context.package.directoryURL
        let givenEnvVars = ProcessInfo.processInfo.environment

        guard let cPicoSDKPackageEnvs = FileManager().envs(from: picoSDKURL.appending(path: "env.json.tmpl").relativePath) else {
            fatalError("Couldn't find default env values in CPicoSDK package directory.")
        }

        let consolidatedEnvVars = self.generateEnvVars(given: givenEnvVars, packageEnvs: cPicoSDKPackageEnvs, packageURL: packageURL)
        self.generateBashFunctions()

        // Generate helper files if needed

        if generateToolset {
            self.generateToolset(envVars: consolidatedEnvVars)
        }

        if syncSwiftVersion {
            self.syncSwiftVersion(packageURL: packageURL.relativePath, envVars: consolidatedEnvVars)
        }

        if generateSourceKitLSPSettings {
            self.generateSourceKitLSPSettings(packageURL: packageURL.relativePath, envVars: consolidatedEnvVars)
        }

        if generateVSCodeSettings {
            self.generateVSCodeSettings()
        }

        // Print output once generated

        print(self.output)
    }

    func generateEnvVars(given givenEnvVars: [String: String], packageEnvs: [String: String], packageURL: URL) -> [String: String] {
        let givenEnvVars = Dictionary(
            uniqueKeysWithValues: givenEnvVars
                .filter { key, value in relevantEnvVars.contains(key) }
        )

        var newEnvVars: [String: String] = givenEnvVars
        newEnvVars.merge(packageEnvs, uniquingKeysWith: { old, _ in old })

        guard let buildType = BuildType(rawValue: newEnvVars["BUILD_TYPE"] ?? "") else {
            fatalError("Couldn't find a valid BUILD_TYPE. Supported types are: 'Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel', got \(newEnvVars["BUILD_TYPE"] ?? "null")")
        }

        if newEnvVars["SWIFT_BUILD_TYPE"] == nil {
            newEnvVars["SWIFT_BUILD_TYPE"] = buildType.swiftBuildType
        }

        if newEnvVars["TOOLSET_PATH"] == nil {
            newEnvVars["TOOLSET_PATH"] = packageURL.relativePath.appending("/toolset.json")
        }

        for (envVar, value) in givenEnvVars {
            self.log(message: "[CPicoSDK] Using provided env var \(envVar): \(value)")
        }

        for (envVar, value) in newEnvVars.filter({ !givenEnvVars.keys.contains($0.key) }) {
            self.log(message: "[CPicoSDK] Using default env var \(envVar): \(value)")
            output += "export \(envVar)=\"\(value)\"\n"
        }

        let missingEnvVars = relevantEnvVars.filter { !newEnvVars.keys.contains($0) }
        if missingEnvVars.count > 0 {
            fatalError("Cannot continue. Missing env variables: [\(missingEnvVars.joined(separator: ", "))]")
        }

        var iterations = 10
        let regex = /\$\{(.*?)\}/

        var varsToResolve = newEnvVars.filter { $0.value.contains("$") }
        repeat {
            for (key, value) in varsToResolve {

                // replacing matches doesnt exist
                // ... so we do it manually here
                newEnvVars[key] = value.replacing(regex) { match in
                    if let replacement = newEnvVars[String(match.1)] {
                        replacement
                    } else {
                        String(match.0)
                    }
                }
            }
            varsToResolve = newEnvVars.filter { $0.value.contains("$") }
            iterations -= 1
        } while iterations > 0 && varsToResolve.count > 0

        if varsToResolve.count > 0 {
            let unresolvedVars = varsToResolve.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            fatalError("Couldn't resolve all env variables. The only var replacement format accepted is ${VAR}. Remaining: [\(unresolvedVars)]")
        }

        return newEnvVars
    }

    func generateBashFunctions() {
        self.output += """
        function finalize_rp2xxx_binary {
            "$SWIFTLY_PATH" run swift package finalize-rp2xxx-binary "$1" \\
                --incremental \\
                --allow-writing-to-package-directory
        }

        function flash_if_needed {
            if [[ "${2:-}" == "--flash" ]]; then
                while true; do
                    if "$PICOTOOL_PATH" info >/dev/null 2>&1; then
                        echo "Device found!"
                        break
                    fi

                    echo "Waiting for device in BOOTSEL mode to become available. Connect the device while pushing the BOOT button... (trying again in 2 seconds)"
                    sleep 2
                done

                "$PICOTOOL_PATH" load ".build/$SWIFTPM_TRIPLE/$SWIFT_BUILD_TYPE/$1.uf2"
                "$PICOTOOL_PATH" reboot
            fi
        }
        """ + "\n"
    }

    func generateToolset(envVars: [String: String]) {
        let toolsetPath = envVars["TOOLSET_PATH"]!

        let toolsetJSON = """
        {
            "schemaVersion": "1.0",
            "swiftCompiler": {
                "extraCLIOptions": [
                    "-Xfrontend", "-disable-stack-protector",
                    "-enable-experimental-feature", "Embedded",
                    "-sdk", "\(envVars["SDK_PATH"]!)", "-wmo"
                ]
            },
            "cCompiler": {
                "extraCLIOptions": [
                    "--sysroot", "\(envVars["SDK_PATH"]!)"
                ]
            },
            "linker": {
                "path": "\(envVars["LD_PATH"]!)",
                "extraCLIOptions": [
                    "-static", "-L\(envVars["SDK_PATH"]!)/lib"
                ]
            }
        }
        """.data(using: .utf8)

        let fileManager = FileManager()
        try! fileManager.ensureDirectoryExists(at: toolsetPath, isDirectory: false)
        if fileManager.fileExists(atPath: toolsetPath), 
            let content = fileManager.contents(atPath: toolsetPath), 
            toolsetJSON == content 
        {
            self.log(message: "[CPicoSDK] Not generating new toolset.json as existing one is up-to-date.")
        } else {
            fileManager.createFile(atPath: toolsetPath, contents: toolsetJSON)
        }
    }

    func syncSwiftVersion(packageURL: String, envVars: [String: String]) {
        let swiftVersionFilePath = packageURL.appending("/.swift-version")
        let fileManager = FileManager()
        let swiftVersion = envVars["SWIFT_VERSION"]!
        try! fileManager.ensureDirectoryExists(at: swiftVersionFilePath, isDirectory: false)
        if fileManager.fileExists(atPath: swiftVersionFilePath), 
            let existingContent = fileManager.contents(atPath: swiftVersionFilePath),
            let existingVersion: String = String(data: existingContent, encoding: .utf8), 
            existingVersion.trimmingCharacters(in: .whitespacesAndNewlines) == swiftVersion 
        {
            self.log(message: "[CPicoSDK] Not updating .swift-version as existing one is up-to-date.")
        } else {
            fileManager.createFile(atPath: swiftVersionFilePath, contents: swiftVersion.data(using: .utf8))
        }
    }

    func generateVSCodeSettings() {
    }

    func generateSourceKitLSPSettings(packageURL: String, envVars: [String: String]) {
        let sourceKitLSPFilePath = packageURL.appending("/.sourcekit-lsp/config.json")

        let sourceKitLSPSettings = """
        {
            "swiftPM": {
                "configuration": "\(envVars["SWIFT_BUILD_TYPE"]!)",
                "triple": "\(envVars["SWIFTPM_TRIPLE"]!)",
                "toolsets": ["\(envVars["TOOLSET_PATH"]!)"],
                "swiftCompilerFlags": [
                    "-enable-experimental-feature", "Embedded"
                ]
            }
        }
        """.data(using: .utf8)

        let fileManager = FileManager()
        try! fileManager.ensureDirectoryExists(at: sourceKitLSPFilePath, isDirectory: false)
        if fileManager.fileExists(atPath: sourceKitLSPFilePath), 
            let content = fileManager.contents(atPath: sourceKitLSPFilePath),
            content == sourceKitLSPSettings 
        {
            self.log(message: "[CPicoSDK] Not updating .sourcekit-lsp/config.json as existing one is up-to-date.")
        } else {
            fileManager.createFile(atPath: sourceKitLSPFilePath, contents: sourceKitLSPSettings)
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

    func ensureDirectoryExists(at path: String, isDirectory: Bool) throws {
        let url = URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        try FileManager.default.createDirectory(
            at: isDirectory ? url : url.deletingLastPathComponent(), 
            withIntermediateDirectories: true
        )
    }
}
