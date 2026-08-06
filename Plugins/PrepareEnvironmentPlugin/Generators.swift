import Foundation
import PackagePlugin

extension PrepareEnvironmentPlugin {
    // MARK: - Env Vars
    
    func generateEnvVars(
        given givenEnvVars: [String: String],
        configured configuredEnvVars: [String: String],
        packageEnv: Env,
        context: PackagePlugin.PluginContext,
        libraryProductName: String?,
        embeddedSwiftRuntimeVendorPath: String
    ) async -> [String: String] {
        let givenEnvVars = Dictionary(
            uniqueKeysWithValues: givenEnvVars
                .filter { key, value in Env.relevantEnvVars.contains(key) }
        )
        let configuredEnvVars = Dictionary(
            uniqueKeysWithValues: configuredEnvVars
                .filter { key, _ in Env.relevantEnvVars.contains(key) }
        )

        // Starts with user-given
        var newEnvVars: [String: String] = givenEnvVars
        
        // Then merges in global vars from env.json
        newEnvVars.merge(
            packageEnv.vars.filter { key, _ in key != "BOARD" },
            uniquingKeysWith: { old, _ in old }
        )

        let selectedCombinationName = self.resolveSelectedCombination(
            givenEnvVars: givenEnvVars,
            packageEnv: packageEnv,
            context: context
        )

        let selectedCombinationVars = packageEnv.combinations[selectedCombinationName]!.vars
            .filter { !givenEnvVars.keys.contains($0.key) }
        newEnvVars.merge(selectedCombinationVars, uniquingKeysWith: { _, new in new })

        // Consumer configuration overrides package and board defaults, while
        // an explicitly exported process value remains highest precedence.
        newEnvVars.merge(
            configuredEnvVars.filter { !givenEnvVars.keys.contains($0.key) },
            uniquingKeysWith: { _, configuredValue in configuredValue }
        )
        newEnvVars["CPICOSDK_COMBINATION"] = selectedCombinationName

        // Some basic checks
        guard let buildType = BuildType(rawValue: newEnvVars["BUILD_TYPE"] ?? "") else {
            fatalError("[CPicoSDK] Couldn't find a valid BUILD_TYPE. Supported types are: 'Debug', 'Release', 'RelWithDebInfo', 'MinSizeRel', got \(newEnvVars["BUILD_TYPE"] ?? "null")")
        }

        // Some dynamically generated vars are provided
        if newEnvVars["SWIFT_BUILD_TYPE"] == nil {
            newEnvVars["SWIFT_BUILD_TYPE"] = buildType.swiftBuildType
        }

        if newEnvVars["PACKAGE_PATH"] == nil {
            newEnvVars["PACKAGE_PATH"] = context.package.directoryURL.relativePath
        }

        if newEnvVars["PLUGIN_OUTPUT_PATH"] == nil {
            newEnvVars["PLUGIN_OUTPUT_PATH"] = context.pluginWorkDirectoryURL.relativePath
        }
        
        if newEnvVars["SWIFTPM_PRODUCT"] == nil {
            newEnvVars["SWIFTPM_PRODUCT"] = libraryProductName ?? ""
        }
        
        if newEnvVars["RELEVANT_ENV_VARS"] == nil {
            newEnvVars["RELEVANT_ENV_VARS"] = Env.relevantEnvVars.joined(separator: ",")
        }

        if newEnvVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] == nil {
            newEnvVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] = "0"
        }

        if newEnvVars["CPICOSDK_CORE0_STACK_SIZE_BYTES"] == nil {
            newEnvVars["CPICOSDK_CORE0_STACK_SIZE_BYTES"] = "8192"
        }

        if newEnvVars["CPICOSDK_CORE1_STACK_SIZE_BYTES"] == nil {
            newEnvVars["CPICOSDK_CORE1_STACK_SIZE_BYTES"] = "8192"
        }

        if newEnvVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] == "1",
           newEnvVars["SWIFT_EMBEDDED_FALLBACK_PATH"] == nil,
           let swiftVersion = newEnvVars["SWIFT_VERSION"] 
        {
            let fallbackPath = embeddedSwiftRuntimeVendorPath
                .appending("/\(swiftVersion)/usr/lib/swift/embedded")

            if !FileManager.default.fileExists(atPath: fallbackPath) {
                // Concurrency runtime needs to be included in the package. If this swift version is meant to be 
                // used in distribution this needs to be fixed before shipping, otherwise Linux users won't have
                // access to the Concurrency runtime.

                #if os(Linux)
                print("[CPicoSDK] ⚠️ \u{001B}[33mWARNING: No embedded Swift runtime found at \(fallbackPath). Swift doesn't ship the Concurrency runtime binaries for embedded targets on Linux, please extract the Concurrency runtime from another toolchain if you intend use concurrency.\u{001B}[0m")
                #else
                print("[CPicoSDK] ⚠️ \u{001B}[33mWARNING: No embedded Swift runtime found at \(fallbackPath). (This warning is only relevant to CPicoSDK maintainers, ignore otherwise)\u{001B}[0m")
                #endif
            }

            newEnvVars["SWIFT_EMBEDDED_FALLBACK_PATH"] = fallbackPath
        }

        // Show some information about given vars first
        for (envVar, value) in givenEnvVars {
            print("[CPicoSDK] Using provided env var \(envVar): \(value)")
        }

        newEnvVars = self.resolve(envVars: newEnvVars)

        for (envVar, value) in newEnvVars
            .filter({ !givenEnvVars.keys.contains($0.key) })
            .sorted(by: { $0.key < $1.key })
        {
            print("[CPicoSDK] Using default env var \(envVar): \(value)")
            self.appendExport(envVar, value: value)
        }

        var combinationsWithErrors = false
        
        for (name, combination) in packageEnv.combinations {
            print("[CPicoSDK] Specializing env vars for combination: \(name)")
            
            let combinationSpecializedVars = combination.vars
                .filter { !givenEnvVars.keys.contains($0.key) } // Don't override given vars, only globals.
            
            // Make sure overrides are resolved against globals + given.
            let resolvedCombinationSpecializedVars = self.resolve(
                envVars: newEnvVars.merging(
                    combinationSpecializedVars,
                    uniquingKeysWith: { _, new in new }
                )
            )
            
            // Print and dump vars after resolving
            for envVar in combinationSpecializedVars.keys.sorted() {
                print(
                    "[CPicoSDK] \(newEnvVars.keys.contains(envVar) ? "Overriding" : "Using") specialized env var CPICOSDK_\(name)_\(envVar): \(resolvedCombinationSpecializedVars[envVar]!)"
                )
                self.appendExport(
                    "CPICOSDK_\(name)_\(envVar)",
                    value: resolvedCombinationSpecializedVars[envVar]!
                )
            }
            
            // Make sure all relevant env vars are complete for this combination.
            let missingEnvVars = Env.relevantEnvVars.filter { name in
                if name == "SWIFT_EMBEDDED_FALLBACK_PATH",
                   resolvedCombinationSpecializedVars["SWIFT_EMBEDDED_FALLBACK_MODULES"] != "1"
                {
                    return false
                }
                return !resolvedCombinationSpecializedVars.keys.contains(name)
            }
            if missingEnvVars.count > 0 {
                print("[CPicoSDK] ERROR: Missing env variables: [\(missingEnvVars.joined(separator: ", "))] - (Combination: \(name))")
                combinationsWithErrors = true
            }
        }
        
        guard !combinationsWithErrors else { fatalError("[CPicoSDK] Some of the mandatory env variables are missing. Please check logs.")}
        
        return newEnvVars
    }
    
    // MARK: - .vscode

    func generateVSCodeSettings(context: PackagePlugin.PluginContext, envVars: [String: String]) throws {
        let productsConfiguration = envVars["SWIFT_BUILD_TYPE"] == "debug"
            ? "Debug"
            : "Release"
        let targetArchitecture = envVars["SWIFTPM_TRIPLE"]!
            .split(separator: "-")
            .first
            .map(String.init)!
        let firmwareELF = "${workspaceFolder}/.build/out/Products/\(productsConfiguration)-none-\(targetArchitecture)/\(envVars["SWIFTPM_PRODUCT"]!).elf"
        let vscodeTasksFilePath = ".vscode/tasks.json"
        let vscodeTasksSettings = """
        {
            "version": "2.0.0",
            "tasks": [
                {
                    "label": "Compile and Flash Project (cortex-debug) [CPicoSDK]",
                    "type": "process",
                    "command": "${workspaceFolder}/build.sh",
                    "args": ["--cortex-debug", "--incremental"],
                    "options": {
                        "cwd": "${workspaceFolder}",
                    },
                    "group": "build",
                    "presentation": {
                        "reveal": "always",
                        "panel": "dedicated"
                    },
                    "problemMatcher": "$swiftc",
                },
                {
                    "label": "Compile and Flash Project (picotool) [CPicoSDK]",
                    "type": "process",
                    "command": "${workspaceFolder}/build.sh",
                    "args": ["--flash", "--incremental"],
                    "options": {
                        "cwd": "${workspaceFolder}",
                    },
                    "group": "build",
                    "presentation": {
                        "reveal": "always",
                        "panel": "dedicated"
                    },
                    "problemMatcher": "$swiftc",
                },
            ]
        }
        """.data(using: .utf8)

        if try self.overwriteOrCreateIfNeeded(path: vscodeTasksFilePath, matchingContent: vscodeTasksSettings) {
            print("[CPicoSDK] Generated/Updated .vscode/tasks.json. Disable this generation with --disable-vscode-settings.")
        } else {
            print("[CPicoSDK] Not updating .vscode/tasks.json as existing one is up-to-date.")
        }

        let extensionsFilePath = ".vscode/extensions.json"
        let extensionsSettings = """
        {
            "recommendations": [
                "marus25.cortex-debug",
                "ms-vscode.vscode-serial-monitor",
                "raspberry-pi.raspberry-pi-pico",
                "swiftlang.swift-vscode"
            ]
        }
        """.data(using: .utf8)

        if try self.overwriteOrCreateIfNeeded(path: extensionsFilePath, matchingContent: extensionsSettings) {
            print("[CPicoSDK] Generated/Updated .vscode/extensions.json. Disable this generation with --disable-vscode-settings.")
        } else {
            print("[CPicoSDK] Not updating .vscode/extensions.json as existing one is up-to-date.")
        }

        let launchFilePath = ".vscode/launch.json"
        let launchSettings = """
        {
            "version": "0.2.0",
            "configurations": [
                {
                    // Same settings as pico-vscode.
                    "preLaunchTask": "Compile and Flash Project (cortex-debug) [CPicoSDK]",
                    "name": "SwiftPM: \(envVars["SWIFTPM_PRODUCT"]!) - Debug (Cortex-Debug) [CPicoSDK]",
                    "cwd": "\(envVars["OPENOCD_PATH"]!)/scripts",
                    "executable": "\(firmwareELF)",
                    "request": "launch",
                    "type": "cortex-debug",
                    "servertype": "openocd",
                    "serverpath": "\(envVars["OPENOCD_PATH"]!)/openocd.exe",
                    "gdbPath": "\(envVars["GDB_PATH"]!)",
                    "device": "\(envVars["OPENOCD_DEVICE"]!)",
                    "configFiles": [
                        "interface/cmsis-dap.cfg",
                        "\(envVars["OPENOCD_TARGET"]!)"
                    ],
                    "svdFile": "\(envVars["SVD_FILE"]!)",
                    "runToEntryPoint": "main",
                    // Fix for no_flash binaries, where monitor reset halt doesn't do what is expected
                    // also works fine for flash binaries
                    "overrideLaunchCommands": [
                        "monitor reset init",
                        "load \\"\(firmwareELF)\\""
                    ],
                    "openOCDLaunchCommands": [
                        "adapter speed 5000"
                    ],
                    "rttConfig": {
                        "enabled": true,
                        "address": "auto",
                        "decoders": [
                            {
                                "label": "",
                                "port": 0,
                                "type": "console"
                            }
                        ]
                    }
                },
                {
                    "preLaunchTask": "Compile and Flash Project (picotool) [CPicoSDK]",
                    "name": "SwiftPM: \(envVars["SWIFTPM_PRODUCT"]!) - Flash (picotool) [CPicoSDK]",
                    "request": "launch",
                    "type": "lldb",
                    "program": "/usr/bin/true", // Dummy program to satisfy cppdbg requirements
                    "cwd": "${workspaceFolder}",
                    "stopOnEntry": false
                },
            ]
        }
        """.data(using: .utf8)

        if try self.overwriteOrCreateIfNeeded(path: launchFilePath, matchingContent: launchSettings) {
            print("[CPicoSDK] Generated/Updated .vscode/launch.json. Disable this generation with --disable-vscode-settings.")
        } else {
            print("[CPicoSDK] Not updating .vscode/launch.json as existing one is up-to-date.")
        }
    }

    // MARK: - Preparation Script

    func generatePreparationScript(dumpPrepScriptPath: String) throws {
        if try self.overwriteOrCreateIfNeeded(path: dumpPrepScriptPath, matchingContent: self.output.data(using: .utf8)) {
            print("[CPicoSDK] Generated/Updated preparation script at \(dumpPrepScriptPath).")
        } else {
            print("[CPicoSDK] Not updating preparation script as existing one is up-to-date.")
        }
    }

    func overwriteOrCreateIfNeeded(path: String, matchingContent: Data?) throws -> Bool {
        let fileManager = FileManager()
        try fileManager.ensureDirectoryExists(at: path, isDirectory: false)
        if fileManager.fileExists(atPath: path),
            let content = fileManager.contents(atPath: path),
            content == matchingContent
        {
            return false
        } else {
            guard fileManager.createFile(atPath: path, contents: matchingContent) else {
                fatalError("[CPicoSDK] Couldn't write file at path \(path).")
            }
            return true
        }
    }
}
