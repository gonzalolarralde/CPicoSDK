import Foundation

extension PrepareEnvironmentPlugin {
    // MARK: - Env Vars
    
    func generateEnvVars(given givenEnvVars: [String: String], packageEnvs: [String: String], packageURL: URL, workingDir: URL) -> [String: String] {
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

        if newEnvVars["PACKAGE_PATH"] == nil {
            newEnvVars["PACKAGE_PATH"] = packageURL.relativePath
        }

        if newEnvVars["PLUGIN_OUTPUT_PATH"] == nil {
            newEnvVars["PLUGIN_OUTPUT_PATH"] = workingDir.relativePath
        }

        for (envVar, value) in givenEnvVars {
            self.log(message: "[CPicoSDK] Using provided env var \(envVar): \(value)")
        }

        let missingEnvVars = relevantEnvVars.filter { !newEnvVars.keys.contains($0) }
        if missingEnvVars.count > 0 {
            fatalError("Cannot continue. Missing env variables: [\(missingEnvVars.joined(separator: ", "))]")
        }

        newEnvVars = self.resolve(envVars: newEnvVars)

        for envVar in relevantEnvVars.filter({ !givenEnvVars.keys.contains($0) }) {
            self.log(message: "[CPicoSDK] Using default env var \(envVar): \(newEnvVars[envVar]!)")
            output += "export \(envVar)=\"\(newEnvVars[envVar]!)\"\n"
        }

        return newEnvVars
    }

    func resolve(envVars: [String: String]) -> [String: String] {
        var resolvedEnvVars = envVars

        var iterations = 10
        let regex = /\$\{(.*?)\}/

        var varsToResolve = resolvedEnvVars.filter { $0.value.contains("$") }
        repeat {
            for (key, value) in varsToResolve {
                resolvedEnvVars[key] = value.replacing(regex) { match in
                    if let replacement = resolvedEnvVars[String(match.1)] {
                        replacement
                    } else {
                        String(match.0)
                    }
                }
            }
            varsToResolve = resolvedEnvVars.filter { $0.value.contains("$") }
            iterations -= 1
        } while iterations > 0 && varsToResolve.count > 0

        if varsToResolve.count > 0 {
            let unresolvedVars = varsToResolve.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            fatalError("Couldn't resolve all env variables. The only var replacement format accepted is ${VAR}. Remaining: [\(unresolvedVars)]")
        }

        return resolvedEnvVars
    }
    
    // MARK: - Bash Functions
    
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

    // MARK: - toolset.json
    
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

    // MARK: - .swift-version
    
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

    // MARK: - .vscode

    func generateVSCodeSettings() {
    }

    // MARK: - .sourcekit-lsp/config.json
    
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
